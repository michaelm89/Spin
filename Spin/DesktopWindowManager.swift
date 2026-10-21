import AppKit
import Combine

/// Keeps one click-through desktop window on every display: either the full room
/// or just the floating record.
final class DesktopWindowManager {
    private struct Entry {
        let window: NSWindow
        let rig: RecordRig
        let room: RoomView?
        let transport: TransportPanel?
        let occlusionObserver: NSObjectProtocol
    }

    private let monitor: SpotifyMonitor
    private let prefs: Preferences
    private let library: RoomLibrary
    private var entries: [Entry] = []
    private var cancellables = Set<AnyCancellable>()

    /// Just above the wallpaper, below the desktop icons.
    private static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    private static let margin: CGFloat = 24

    init(monitor: SpotifyMonitor, prefs: Preferences, library: RoomLibrary) {
        self.monitor = monitor
        self.prefs = prefs
        self.library = library

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        // objectWillChange fires before the new value lands; the debounce lets it settle.
        prefs.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        monitor.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.entries.forEach {
                    $0.rig.setState(state, animated: true)
                    $0.transport?.setPlaying(state.status == .playing)
                    let showing = state.status != .stopped
                    $0.room?.setTrack(name: showing ? state.displayName : "", artist: showing ? state.artist : "")
                }
            }
            .store(in: &cancellables)

        monitor.$artwork
            .sink { [weak self] image in
                self?.entries.forEach { $0.rig.setArtwork(image) }
            }
            .store(in: &cancellables)

        // Re-bake the room when any of its covers change, coalescing bursts.
        Publishers.CombineLatest3(library.$wall, library.$stack, monitor.$artworkURL)
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateRooms() }
            .store(in: &cancellables)

        rebuild()
    }

    private var roomContent: RoomContent {
        RoomContent(wall: library.wall, stack: library.stack, nowPlaying: monitor.artworkURL)
    }

    private func updateRooms() {
        let content = roomContent
        for entry in entries {
            guard let room = entry.room, let screen = entry.window.screen else { continue }
            let capacity = Room.wallCapacity(aspect: screen.frame.width / screen.frame.height)
            var trimmed = content
            trimmed.wall = Array(content.wall.prefix(capacity))
            room.show(trimmed)
        }
    }

    private func rebuild() {
        for entry in entries {
            NotificationCenter.default.removeObserver(entry.occlusionObserver)
            entry.window.orderOut(nil)
            entry.transport?.orderOut(nil)
        }
        entries = NSScreen.screens.map(makeEntry)
        updateRooms()
    }

    private func makeEntry(for screen: NSScreen) -> Entry {
        let view: NSView
        let rig: RecordRig
        let room: RoomView?
        var transport: TransportPanel?
        let frame: NSRect
        switch prefs.style {
        case .room:
            frame = screen.frame
            let roomView = RoomView(size: frame.size, scale: screen.backingScaleFactor, showTonearm: prefs.showTonearm)
            view = roomView
            rig = roomView.rig
            room = roomView
            roomView.setTrack(name: monitor.state.status == .stopped ? "" : monitor.state.displayName, artist: monitor.state.artist)
            let panel = TransportPanel()
            panel.setPlaying(monitor.state.status == .playing)
            panel.onPress = { [weak monitor] button in
                switch button {
                case .previous: monitor?.send("previous track")
                case .playPause: monitor?.send("playpause")
                case .next: monitor?.send("next track")
                }
            }
            roomView.onButtonsPlaced = { [weak panel] rects in
                panel?.place(buttons: rects.map { $0.offsetBy(dx: frame.minX, dy: frame.minY) })
            }
            transport = panel
        case .floating:
            let layout = RecordRig.Layout(diameter: prefs.size.diameter, showTonearm: prefs.showTonearm)
            rig = RecordRig(layout: layout, scale: screen.backingScaleFactor)
            view = FloatingRecordView(rig: rig)
            room = nil
            frame = floatingFrame(for: layout.canvasSize, on: screen)
        }
        rig.setArtwork(monitor.artwork)
        rig.setState(monitor.state, animated: false)

        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = Self.level
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.isOpaque = prefs.style == .room
        window.backgroundColor = prefs.style == .room ? .black : .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()

        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak window] _ in
            guard let window else { return }
            rig.setVisible(window.occlusionState.contains(.visible))
        }
        return Entry(window: window, rig: rig, room: room, transport: transport, occlusionObserver: observer)
    }

    private func floatingFrame(for size: CGSize, on screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        let m = Self.margin
        let origin: CGPoint
        switch prefs.position {
        case .topLeft: origin = CGPoint(x: area.minX + m, y: area.maxY - m - size.height)
        case .topRight: origin = CGPoint(x: area.maxX - m - size.width, y: area.maxY - m - size.height)
        case .bottomLeft: origin = CGPoint(x: area.minX + m, y: area.minY + m)
        case .bottomRight: origin = CGPoint(x: area.maxX - m - size.width, y: area.minY + m)
        case .center: origin = CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        }
        return NSRect(origin: origin, size: size).integral
    }
}
