import AppKit
import Combine

/// Full-screen room: a baked still of the scene with the live record rig laid over the platter.
final class RoomView: NSView {
    static func rigLayout(showTonearm: Bool) -> RecordRig.Layout {
        RecordRig.Layout(diameter: 360, showTonearm: showTonearm, drawsShadowAndBase: false,
                         labelTint: CGColor(srgbRed: 1.0, green: 0.86, blue: 0.72, alpha: 1))
    }

    let rig: RecordRig
    private let scale: CGFloat
    private let background = CALayer()
    private let recordPlane = CALayer()
    private let trackLabel = CATextLayer()
    private var track: (name: String, artist: String) = ("", "")
    private var bakedContent: RoomContent?
    private var pendingContent: RoomContent?
    private var isBaking = false
    /// Called after each bake with the transport buttons' rects, in view points.
    var onButtonsPlaced: (([CGRect]) -> Void)?

    init(size: CGSize, scale: CGFloat, showTonearm: Bool) {
        rig = RecordRig(layout: Self.rigLayout(showTonearm: showTonearm), scale: scale)
        self.scale = scale
        super.init(frame: NSRect(origin: .zero, size: size))

        let host = CALayer()
        host.backgroundColor = CGColor(srgbRed: 0.12, green: 0.07, blue: 0.04, alpha: 1)
        layer = host
        wantsLayer = true

        background.frame = bounds
        background.contentsGravity = .resize
        host.addSublayer(background)

        recordPlane.anchorPoint = .zero
        recordPlane.position = .zero
        recordPlane.bounds = CGRect(origin: .zero, size: rig.layout.canvasSize)
        recordPlane.isHidden = true
        recordPlane.addSublayer(rig.root)
        host.addSublayer(recordPlane)

        // Song and artist "printed" on the turntable's front, left of the buttons.
        trackLabel.contentsScale = scale
        trackLabel.alignmentMode = .right
        trackLabel.truncationMode = .end
        trackLabel.isWrapped = true
        trackLabel.isHidden = true
        trackLabel.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        host.addSublayer(trackLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setTrack(name: String, artist: String) {
        guard name != track.name || artist != track.artist else { return }
        track = (name, artist)
        updateTrackLabel()
    }

    private func updateTrackLabel() {
        let height = trackLabel.bounds.height
        guard height > 0, !track.name.isEmpty else { trackLabel.isHidden = true; return }
        // Two lines sized to the strip: the title, then the artist a little smaller and dimmer.
        let titleSize = (height * 0.36).rounded(.down)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.maximumLineHeight = height / 2
        func attrs(_ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: size, weight: weight),
             .foregroundColor: NSColor(srgbRed: 0.93, green: 0.86, blue: 0.74, alpha: alpha),
             .kern: size * 0.04,
             .paragraphStyle: paragraph]
        }
        let text = NSMutableAttributedString(string: track.name + "\n", attributes: attrs(titleSize, .semibold, 0.92))
        text.append(NSAttributedString(string: track.artist, attributes: attrs(titleSize * 0.86, .regular, 0.7)))
        trackLabel.string = text
        trackLabel.shadowColor = .black
        trackLabel.shadowOpacity = 0.5
        trackLabel.shadowRadius = 0.5
        trackLabel.shadowOffset = CGSize(width: 0, height: -0.5)
        trackLabel.isHidden = false
    }

    /// Re-renders the room if `content` differs from what's shown. Bakes never overlap.
    func show(_ content: RoomContent) {
        guard content != bakedContent else { return }
        pendingContent = content
        bakeNextIfIdle()
    }

    private func bakeNextIfIdle() {
        guard !isBaking, let content = pendingContent else { return }
        pendingContent = nil
        isBaking = true
        var urls = content.wall + content.stack
        if let nowPlaying = content.nowPlaying { urls.append(nowPlaying) }
        Task { @MainActor in
            let images = await ArtworkStore.shared.images(for: urls, maxPixels: 512)
            RoomRenderer.shared.bake(content: content, images: images, size: bounds.size,
                                     scale: scale, rig: rig.layout) { [weak self] bake in
                guard let self else { return }
                self.isBaking = false
                if let bake {
                    self.bakedContent = content
                    self.background.contents = bake.image // implicit cross-fade
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.recordPlane.transform = bake.recordTransform
                    self.recordPlane.isHidden = false
                    CATransaction.commit()
                    self.onButtonsPlaced?(bake.buttonRects)
                    self.trackLabel.frame = bake.trackLabelRect
                    self.updateTrackLabel()
                }
                self.bakeNextIfIdle()
            }
        }
    }
}

/// Decides which covers go where in the room.
final class RoomLibrary: ObservableObject {
    static let shared = RoomLibrary()

    @Published private(set) var wall: [String] = []
    @Published private(set) var stack: [String] = []

    private let history = ListeningHistory.shared
    private let account = SpotifyAccount.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // @Published fires before the value changes, so recompute on the next turn of the run loop.
        Publishers.Merge3(history.objectWillChange, account.$topAlbums.map { _ in }, account.$recentlyPlayed.map { _ in })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        recompute()
    }

    private func recompute() {
        let top = account.topAlbums.isEmpty ? history.mostPlayedAlbums : account.topAlbums
        let newWall = top.map(\.artworkURL)
        if newWall != wall { wall = newWall }

        // Local completions plus the account's recently played, newest first.
        let merged = (history.recentAlbums + account.recentlyPlayed).sorted { $0.date > $1.date }
        var seen = Set<String>()
        let newStack = Array(merged.map(\.album.artworkURL).filter { seen.insert($0).inserted }.prefix(Room.stackLimit))
        if newStack != stack { stack = newStack }
    }
}
