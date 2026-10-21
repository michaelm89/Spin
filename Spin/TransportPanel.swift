import AppKit

/// Small clickable window over the turntable's front buttons. The room window lets every
/// click through to the desktop, so the buttons need a window of their own; it sits just
/// above the desktop icons (Finder's icon layer would otherwise take the clicks).
final class TransportPanel: NSPanel {
    enum Button: CaseIterable { case previous, playPause, next }

    var onPress: ((Button) -> Void)? {
        get { transportView.onPress }
        set { transportView.onPress = newValue }
    }

    private let transportView = TransportView()
    private static let padding: CGFloat = 6

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        contentView = transportView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `rects` are the three buttons in screen coordinates.
    func place(buttons rects: [CGRect]) {
        guard rects.count == 3 else { return }
        let frame = rects.reduce(rects[0]) { $0.union($1) }.insetBy(dx: -Self.padding, dy: -Self.padding)
        setFrame(frame.integral, display: true)
        transportView.buttonRects = rects.map {
            $0.offsetBy(dx: -self.frame.minX, dy: -self.frame.minY)
        }
        orderFrontRegardless()
    }

    func setPlaying(_ playing: Bool) {
        transportView.isPlaying = playing
    }
}

private final class TransportView: NSView {
    var onPress: ((TransportPanel.Button) -> Void)?
    var buttonRects: [CGRect] = [] { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var isPlaying = false { didSet { if isPlaying != oldValue { needsDisplay = true } } }
    private var pressed: Int?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let symbols = ["backward.fill", isPlaying ? "pause.fill" : "play.fill", "forward.fill"]
        for (index, rect) in buttonRects.enumerated() {
            // Pressed state: a soft shade over the cap, as if pushed in.
            if index == pressed {
                NSColor(white: 0, alpha: 0.28).setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
            let size = rect.height * 0.42
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            guard let image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { continue }
            let tinted = NSImage(size: image.size, flipped: false) { bounds in
                image.draw(in: bounds)
                NSColor(white: 0.16, alpha: 0.85).set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            let origin = CGPoint(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2)
            tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    override func resetCursorRects() {
        buttonRects.forEach { addCursorRect($0, cursor: .pointingHand) }
    }

    private func button(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return buttonRects.firstIndex { $0.insetBy(dx: -3, dy: -3).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = button(at: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; needsDisplay = true }
        guard let index = pressed, button(at: event) == index else { return }
        onPress?(TransportPanel.Button.allCases[index])
    }

    // Only the caps respond; the few points of padding around them do nothing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return buttonRects.contains { $0.insetBy(dx: -3, dy: -3).contains(local) } ? self : nil
    }
}
