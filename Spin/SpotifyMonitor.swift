import AppKit
import ImageIO

struct PlaybackState: Equatable {
    enum Status { case playing, paused, stopped }

    var status: Status = .stopped
    var trackID = ""
    var name = ""
    var artist = ""
    var album = ""
    /// Seconds into the track at `sampledAt`.
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var sampledAt = Date()

    func position(at date: Date) -> TimeInterval {
        status == .playing ? position + date.timeIntervalSince(sampledAt) : position
    }

    func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(position(at: date) / duration, 0), 1)
    }

    /// True when the two states would look the same on screen (ignoring small position drift).
    func isEquivalent(to other: PlaybackState) -> Bool {
        let now = Date()
        return status == other.status && trackID == other.trackID && name == other.name
            && abs(duration - other.duration) < 0.5
            && abs(position(at: now) - other.position(at: now)) < 1.5
    }
}

/// Tracks Spotify's playback via its distributed notification, with AppleScript for
/// the initial state, artwork URLs and occasional position resyncs.
final class SpotifyMonitor: NSObject, ObservableObject {
    static let shared = SpotifyMonitor()
    static let bundleID = "com.spotify.client"

    @Published private(set) var state = PlaybackState()
    @Published private(set) var artwork: CGImage?
    /// Artwork URL of the current track, once AppleScript has reported it.
    @Published private(set) var artworkURL: String?
    /// Called with a track that played (nearly) to the end, plus its artwork URL.
    var onTrackCompleted: ((PlaybackState, String) -> Void)?
    private var artworkURLsByTrack: [String: String] = [:]

    private let scriptQueue = DispatchQueue(label: "spin.applescript", qos: .utility)
    private var compiledScripts: [String: NSAppleScript] = [:] // only touched on scriptQueue
    private var artworkTrackID: String?
    private var resyncTimer: Timer?

    private static let stateScript = """
    if application "Spotify" is running then
        tell application "Spotify"
            set s to (player state as string)
            set p to player position
            try
                set t to current track
                return {s, p, (duration of t), (id of t), (artwork url of t), (name of t), (artist of t), (album of t)}
            on error
                return {s, p, 0, "", "", "", "", ""}
            end try
        end tell
    end if
    return {"stopped", 0, 0, "", "", "", "", ""}
    """

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playbackStateChanged(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appTerminated(_:)),
                              name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake(_:)),
                              name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
    }

    private var spotifyIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    // MARK: Notifications

    @objc private func playbackStateChanged(_ note: Notification) {
        let info = note.userInfo ?? [:]
        var new = PlaybackState()
        switch (info["Player State"] as? String)?.lowercased() {
        case "playing": new.status = .playing
        case "paused": new.status = .paused
        default: new.status = .stopped
        }
        new.trackID = info["Track ID"] as? String ?? ""
        new.name = info["Name"] as? String ?? ""
        new.artist = info["Artist"] as? String ?? ""
        new.album = info["Album"] as? String ?? ""
        new.duration = ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
        new.sampledAt = Date()

        if let position = info["Playback Position"] as? NSNumber {
            new.position = position.doubleValue
        } else if new.trackID == state.trackID {
            new.position = state.position(at: new.sampledAt)
        }

        apply(new)
        // A new track needs its cover: ask AppleScript and, in case that's slow or not allowed, oEmbed.
        if new.status != .stopped, !new.trackID.isEmpty, new.trackID != artworkTrackID {
            refresh()
            Self.lookUpArtwork(trackID: new.trackID) { [weak self] url in
                guard let self, let url, self.state.trackID == new.trackID, self.artworkTrackID != new.trackID else { return }
                self.loadArtwork(url, for: new.trackID)
            }
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Self.bundleID { apply(PlaybackState()) }
    }

    @objc private func didWake(_ note: Notification) {
        refresh()
    }

    // MARK: State

    private func apply(_ new: PlaybackState) {
        detectCompletion(old: state, new: new)
        if !new.isEquivalent(to: state) { state = new }
        if new.status == .stopped {
            artworkTrackID = nil
            artworkURL = nil
            artwork = nil
        }
        updateResyncTimer()
    }

    /// A track is done — finished or skipped — as soon as playback moves on to another track or stops.
    private func detectCompletion(old: PlaybackState, new: PlaybackState) {
        guard !old.trackID.isEmpty, old.status != .stopped,
              new.trackID != old.trackID || new.status == .stopped else { return }
        if let url = artworkURLsByTrack[old.trackID] {
            onTrackCompleted?(old, url)
        } else {
            // AppleScript hasn't reported this track's cover (or isn't allowed to); ask Spotify's public oEmbed.
            Self.lookUpArtwork(trackID: old.trackID) { [weak self] url in
                guard let url else { return }
                self?.onTrackCompleted?(old, url)
            }
        }
    }

    /// Cover URL for any track via open.spotify.com/oembed (no sign-in needed). Calls back on main.
    static func lookUpArtwork(trackID: String, completion: @escaping (String?) -> Void) {
        var components = URLComponents(string: "https://open.spotify.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: trackID)]
        URLSession.shared.dataTask(with: components.url!) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let url = (json?["thumbnail_url"] as? String).map(canonicalArtworkURL)
            DispatchQueue.main.async { completion(url) }
        }.resume()
    }

    /// Spotify serves each cover at several sizes and hosts; map them all to the 640px URL
    /// so the same album is recognised wherever its URL came from.
    static func canonicalArtworkURL(_ url: String) -> String {
        guard let range = url.range(of: "ab67616d"), url.distance(from: range.lowerBound, to: url.endIndex) >= 56 else { return url }
        let id = url[range.lowerBound...]
        return "https://i.scdn.co/image/ab67616d0000b273" + id.suffix(40)
    }

    /// While playing, re-read the position now and then so the tonearm follows seeks.
    private func updateResyncTimer() {
        if state.status == .playing {
            guard resyncTimer == nil else { return }
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            resyncTimer = timer
        } else {
            resyncTimer?.invalidate()
            resyncTimer = nil
        }
    }

    /// Polls Spotify via AppleScript. Never launches Spotify.
    func refresh() {
        guard spotifyIsRunning else { apply(PlaybackState()); return }
        scriptQueue.async { [weak self] in
            guard let self, let result = self.run(Self.stateScript), result.numberOfItems >= 8 else { return }
            var new = PlaybackState()
            switch result.atIndex(1)?.stringValue?.lowercased() {
            case "playing": new.status = .playing
            case "paused": new.status = .paused
            default: new.status = .stopped
            }
            new.position = result.atIndex(2)?.doubleValue ?? 0
            new.duration = (result.atIndex(3)?.doubleValue ?? 0) / 1000
            new.trackID = result.atIndex(4)?.stringValue ?? ""
            let artworkURL = result.atIndex(5)?.stringValue ?? ""
            new.name = result.atIndex(6)?.stringValue ?? ""
            new.artist = result.atIndex(7)?.stringValue ?? ""
            new.album = result.atIndex(8)?.stringValue ?? ""
            new.sampledAt = Date()

            DispatchQueue.main.async {
                self.apply(new)
                if new.status != .stopped, new.trackID != self.artworkTrackID {
                    self.loadArtwork(artworkURL, for: new.trackID)
                }
            }
        }
    }

    /// Sends a transport command ("playpause", "next track", "previous track") to Spotify.
    /// Playing launches Spotify if needed; the state notification then updates the room.
    func send(_ command: String) {
        scriptQueue.async { [weak self] in
            _ = self?.run("tell application \"Spotify\" to \(command)")
        }
    }

    /// Runs on scriptQueue.
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = compiledScripts[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { return nil }
            compiledScripts[source] = fresh
            script = fresh
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("Spin: AppleScript error %@", error)
            return nil
        }
        return result
    }

    // MARK: Artwork

    private func loadArtwork(_ rawURL: String, for trackID: String) {
        let urlString = rawURL.isEmpty ? rawURL : Self.canonicalArtworkURL(rawURL)
        artworkTrackID = trackID
        if !urlString.isEmpty { artworkURLsByTrack[trackID] = urlString }
        // Consecutive tracks from the same album share a URL.
        if urlString == artworkURL { return }
        artworkURL = urlString
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            artwork = nil
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap(Self.decodeArtwork)
            DispatchQueue.main.async {
                guard let self, self.artworkURL == urlString else { return }
                self.artwork = image
            }
        }.resume()
    }

    private static func decodeArtwork(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension PlaybackState {
    /// The song's name without release clutter, e.g.
    /// "Money For Nothing (Single Edit) 2022 Remaster" → "Money For Nothing".
    var displayName: String { Self.cleanTitle(name) }

    /// Words that mark release clutter rather than part of a song's name.
    private static let clutter = #"remaster|re-?master|edit\b|version|\bmix\b|remix|\bmono\b|stereo|feat\.?|\bft\.|featuring|\bwith\b|single|radio|bonus|deluxe|anniversary|re-?recorded|explicit|\bclean\b"#

    static func cleanTitle(_ title: String) -> String {
        var t = title
        // " - Remastered 2011", " - Radio Edit": cut a spaced-dash suffix only if it's clutter.
        if let dash = t.range(of: #"\s+[-–—]\s+"#, options: .regularExpression), dash.lowerBound != t.startIndex,
           t[dash.upperBound...].range(of: clutter, options: [.regularExpression, .caseInsensitive]) != nil {
            t = String(t[..<dash.lowerBound])
        }
        // "(Single Edit)", "[2012 Remaster]", "(feat. Someone)" go; "(A Man After Midnight)" stays.
        let brackets = try! NSRegularExpression(pattern: #"\s*[\(\[]([^\)\]]*)[\)\]]"#)
        for match in brackets.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
            guard let whole = Range(match.range, in: t), let inner = Range(match.range(at: 1), in: t),
                  whole.lowerBound != t.startIndex,
                  t[inner].range(of: clutter, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            t.removeSubrange(whole)
        }
        // Clutter left loose at the end: "2022 Remaster", "Remastered 2009", "Radio Edit", "feat. X".
        let trailing = #"\s+((\d{4}\s+)?(digital(ly)?\s+)?(remaster(ed)?|re-?master|mono|stereo|radio edit|single edit|single version|album version)(\s+(version|\d{4}))*|(feat\.?|ft\.|featuring)\s+.*)$"#
        while let match = t.range(of: trailing, options: [.regularExpression, .caseInsensitive]) {
            t = String(t[..<match.lowerBound])
        }
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—,")))
        return t.isEmpty ? title : t
    }
}
