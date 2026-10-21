import AppKit
import QuartzCore

/// Layer tree that draws the record and tonearm. All motion is Core Animation,
/// so the app does no per-frame work of its own.
final class RecordRig {
    struct Layout {
        let diameter: CGFloat
        let showTonearm: Bool
        /// The floating style draws its own shadow and tonearm base; the room bakes them into the scene.
        var drawsShadowAndBase = true
        /// Multiplied over the label so the art picks up the room's light.
        var labelTint: CGColor?

        var radius: CGFloat { diameter / 2 }
        var padding: CGFloat { (diameter * 0.05).rounded() }
        var canvasSize: CGSize {
            CGSize(width: diameter + padding * 2 + (showTonearm ? radius * 0.32 : 0),
                   height: diameter + padding * 2 + (showTonearm ? radius * 0.14 : 0)) // counterweight headroom
        }
        var center: CGPoint { CGPoint(x: padding + radius, y: padding + radius) }
        var discRect: CGRect {
            CGRect(x: center.x - radius, y: center.y - radius, width: diameter, height: diameter)
        }
        var pivot: CGPoint { CGPoint(x: center.x + radius * 1.08, y: center.y + radius * 0.78) }
        var armLength: CGFloat { radius * 1.2 }

        /// Arm angle (radians, CA convention) that puts the stylus at `fraction` of the record radius.
        func armAngle(forRadiusFraction fraction: CGFloat) -> CGFloat {
            let target = radius * fraction
            var lo = atan2(center.y - pivot.y, center.x - pivot.x) // pointing at the spindle
            var hi = -CGFloat.pi / 2                                 // pointing straight down
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                let tip = CGPoint(x: pivot.x + armLength * cos(mid), y: pivot.y + armLength * sin(mid))
                if hypot(tip.x - center.x, tip.y - center.y) < target { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }
    }

    /// 33⅓ RPM in radians per second.
    private static let angularVelocity = 2 * Double.pi * (100.0 / 3.0) / 60.0
    private static let spinUpDuration: CFTimeInterval = 0.9
    private static let spinDownDuration: CFTimeInterval = 1.6
    /// Rotation is slow and smooth; capping the frame rate keeps GPU/WindowServer work down.
    private static let frameRate = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)

    let layout: Layout
    let root = CALayer()
    private let scale: CGFloat
    private let shadowLayer = CALayer()
    private let discLayer = CALayer()
    private let sheenLayer = CAGradientLayer()
    private let armLayer = CALayer()

    private let armRestAngle: CGFloat
    private let armStartAngle: CGFloat
    private let armEndAngle: CGFloat

    private var state = PlaybackState()
    private var spinning = false
    private var visible = true
    private var artwork: CGImage?
    private var hasRendered = false

    init(layout: Layout, scale: CGFloat) {
        self.layout = layout
        self.scale = scale
        armRestAngle = -.pi / 2 + 0.06
        armStartAngle = layout.armAngle(forRadiusFraction: DiscRenderer.outerGrooveRatio - 0.01)
        armEndAngle = layout.armAngle(forRadiusFraction: DiscRenderer.innerGrooveRatio + 0.01)

        root.bounds = CGRect(origin: .zero, size: layout.canvasSize)
        root.anchorPoint = .zero
        root.contentsScale = scale
        setUpDisc(in: root)
        if layout.showTonearm { setUpTonearm(in: root) }
    }

    // MARK: Layers

    private func setUpDisc(in root: CALayer) {
        let rect = layout.discRect
        let d = layout.diameter

        // Static shadow with an explicit path so it never needs an offscreen pass.
        shadowLayer.frame = rect
        shadowLayer.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: rect.size), transform: nil)
        shadowLayer.shadowColor = .black
        shadowLayer.shadowOpacity = 0.45
        shadowLayer.shadowRadius = d * 0.025
        shadowLayer.shadowOffset = CGSize(width: 0, height: -d * 0.012)
        if layout.drawsShadowAndBase { root.addSublayer(shadowLayer) }

        discLayer.frame = rect
        discLayer.allowsEdgeAntialiasing = true
        discLayer.contentsScale = scale
        discLayer.contentsGravity = .resize
        root.addSublayer(discLayer)

        // Sheen stays still while the disc turns underneath it, like light on real vinyl.
        let highlight = CGColor(gray: 1, alpha: 0.085)
        let clear = CGColor(gray: 1, alpha: 0)
        sheenLayer.frame = rect
        sheenLayer.type = .conic
        sheenLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        sheenLayer.endPoint = CGPoint(x: 0.5, y: 0)
        sheenLayer.colors = [clear, highlight, clear, clear, highlight, clear, clear]
        sheenLayer.locations = [0, 0.09, 0.2, 0.5, 0.59, 0.7, 1]
        let mask = CAShapeLayer()
        let ring = CGMutablePath()
        let local = CGRect(origin: .zero, size: rect.size)
        ring.addEllipse(in: local.insetBy(dx: d * 0.008, dy: d * 0.008))
        let labelInset = layout.radius * (1 - DiscRenderer.labelRatio)
        ring.addEllipse(in: local.insetBy(dx: labelInset, dy: labelInset))
        mask.path = ring
        mask.fillRule = .evenOdd
        sheenLayer.mask = mask
        sheenLayer.shouldRasterize = true
        sheenLayer.rasterizationScale = scale
        root.addSublayer(sheenLayer)
    }

    private func setUpTonearm(in root: CALayer) {
        let r = layout.radius
        let pivot = layout.pivot

        let base = CAShapeLayer()
        base.path = CGPath(ellipseIn: CGRect(x: pivot.x - r * 0.11, y: pivot.y - r * 0.11,
                                             width: r * 0.22, height: r * 0.22), transform: nil)
        base.fillColor = CGColor(gray: 0.13, alpha: 1)
        base.strokeColor = CGColor(gray: 0.32, alpha: 1)
        base.lineWidth = 1
        base.shadowPath = base.path
        base.shadowOpacity = 0.4
        base.shadowRadius = r * 0.02
        base.shadowOffset = CGSize(width: 0, height: -r * 0.015)
        base.contentsScale = scale
        if layout.drawsShadowAndBase { root.addSublayer(base) }

        // Arm in local coordinates: pivot at x = behind, stylus at x = behind + armLength.
        let behind = r * 0.3
        let ahead = r * 0.06
        let width = behind + layout.armLength + ahead
        let height = r * 0.2
        let mid = height / 2
        let tip = behind + layout.armLength
        armLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        armLayer.anchorPoint = CGPoint(x: behind / width, y: 0.5)
        armLayer.position = pivot
        armLayer.allowsEdgeAntialiasing = true

        let weight = CAShapeLayer()
        weight.path = CGPath(roundedRect: CGRect(x: behind - r * 0.28, y: mid - r * 0.065,
                                                 width: r * 0.15, height: r * 0.13),
                             cornerWidth: r * 0.03, cornerHeight: r * 0.03, transform: nil)
        weight.fillColor = CGColor(gray: 0.17, alpha: 1)
        weight.strokeColor = CGColor(gray: 0.4, alpha: 1)
        weight.lineWidth = 1

        let tube = CAShapeLayer()
        let tubePath = CGMutablePath()
        tubePath.move(to: CGPoint(x: behind - r * 0.14, y: mid))
        tubePath.addLine(to: CGPoint(x: tip - r * 0.1, y: mid))
        tube.path = tubePath
        tube.strokeColor = CGColor(gray: 0.8, alpha: 1)
        tube.lineWidth = max(2, r * 0.022)
        tube.lineCap = .round

        let head = CAShapeLayer()
        head.path = CGPath(roundedRect: CGRect(x: tip - r * 0.12, y: mid - r * 0.04,
                                               width: r * 0.16, height: r * 0.08),
                           cornerWidth: r * 0.015, cornerHeight: r * 0.015, transform: nil)
        head.fillColor = CGColor(gray: 0.12, alpha: 1)
        head.strokeColor = CGColor(gray: 0.6, alpha: 1)
        head.lineWidth = 1

        for part in [tube, weight, head] {
            part.contentsScale = scale
            armLayer.addSublayer(part)
        }
        armLayer.shadowPath = CGPath(rect: CGRect(x: behind - r * 0.28, y: mid - r * 0.03,
                                                  width: tip + r * 0.04 - (behind - r * 0.28),
                                                  height: r * 0.06), transform: nil)
        armLayer.shadowOpacity = 0.35
        armLayer.shadowRadius = r * 0.02
        armLayer.shadowOffset = CGSize(width: r * 0.01, height: -r * 0.03)
        setRotation(armLayer, armRestAngle)
        root.addSublayer(armLayer)

        let cap = CAShapeLayer()
        cap.path = CGPath(ellipseIn: CGRect(x: pivot.x - r * 0.045, y: pivot.y - r * 0.045,
                                            width: r * 0.09, height: r * 0.09), transform: nil)
        cap.fillColor = CGColor(gray: 0.75, alpha: 1)
        cap.strokeColor = CGColor(gray: 0.35, alpha: 1)
        cap.lineWidth = 0.75
        cap.contentsScale = scale
        if layout.drawsShadowAndBase { root.addSublayer(cap) }
    }

    // MARK: Updates

    func setArtwork(_ image: CGImage?) {
        if hasRendered && image === artwork { return }
        artwork = image
        hasRendered = true
        discLayer.contents = DiscRenderer.image(diameter: layout.diameter, scale: scale, artwork: image,
                                                labelTint: layout.labelTint)
    }

    func setState(_ new: PlaybackState, animated: Bool) {
        state = new
        guard visible else { return }
        if new.status == .playing, !spinning {
            startSpinning(animated: animated)
        } else if new.status != .playing, spinning {
            stopSpinning(animated: animated)
        }
        if layout.showTonearm { updateArm(animated: animated) }
    }

    /// Stops all animation while the window is fully covered; resyncs when it shows again.
    func setVisible(_ isVisible: Bool) {
        guard isVisible != visible else { return }
        visible = isVisible
        if isVisible {
            setState(state, animated: false)
        } else {
            stopSpinning(animated: false)
            freeze(armLayer)
        }
    }

    // MARK: Spinning

    private func startSpinning(animated: Bool) {
        spinning = true
        let start = currentRotation(discLayer)
        discLayer.removeAllAnimations()
        let now = discLayer.convertTime(CACurrentMediaTime(), from: nil)
        var loopStart = start
        var loopBegin = now

        if animated {
            // Constant acceleration up to 33⅓ RPM: quadratic ease-in covering ωT/2.
            let rampAngle = -CGFloat(Self.angularVelocity * Self.spinUpDuration / 2)
            let ramp = rotation(from: start, to: start + rampAngle, duration: Self.spinUpDuration)
            ramp.timingFunction = CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 1 / 3)
            ramp.beginTime = now
            ramp.fillMode = .forwards
            ramp.isRemovedOnCompletion = false
            discLayer.add(ramp, forKey: "spinUp")
            loopStart += rampAngle
            loopBegin += Self.spinUpDuration
        }

        // Clockwise, as seen from above (negative angles in CA's y-up space).
        let loop = rotation(from: loopStart, to: loopStart - 2 * .pi, duration: 2 * .pi / Self.angularVelocity)
        loop.beginTime = loopBegin
        loop.repeatCount = .infinity
        discLayer.add(loop, forKey: "spin")
    }

    private func stopSpinning(animated: Bool) {
        spinning = false
        let start = currentRotation(discLayer)
        discLayer.removeAllAnimations()
        let end = animated ? start - CGFloat(Self.angularVelocity * Self.spinDownDuration / 2) : start
        setRotation(discLayer, end)
        guard animated else { return }
        // Constant deceleration: quadratic ease-out.
        let spinDown = rotation(from: start, to: end, duration: Self.spinDownDuration)
        spinDown.timingFunction = CAMediaTimingFunction(controlPoints: 1 / 3, 2 / 3, 2 / 3, 1)
        discLayer.add(spinDown, forKey: "spinDown")
    }

    // MARK: Tonearm

    private func armAngle(forProgress progress: Double) -> CGFloat {
        armStartAngle + (armEndAngle - armStartAngle) * CGFloat(progress)
    }

    private func updateArm(animated: Bool) {
        let start = currentRotation(armLayer)
        armLayer.removeAllAnimations()
        let moveDuration: CFTimeInterval = animated ? 0.8 : 0

        guard state.status != .stopped, state.duration > 0 else {
            setRotation(armLayer, armRestAngle)
            if animated { addArmMove(from: start, to: armRestAngle, duration: moveDuration) }
            return
        }

        let now = Date()
        if state.status == .paused {
            let target = armAngle(forProgress: state.progress(at: now))
            setRotation(armLayer, target)
            if animated { addArmMove(from: start, to: target, duration: moveDuration) }
            return
        }

        // Playing: glide into place, then track linearly to the end of the side.
        let trackFrom = state.progress(at: now.addingTimeInterval(moveDuration))
        let trackFromAngle = armAngle(forProgress: trackFrom)
        let remaining = max(state.duration * (1 - trackFrom), 0.1)
        setRotation(armLayer, armEndAngle)
        let layerNow = armLayer.convertTime(CACurrentMediaTime(), from: nil)
        if animated {
            let move = addArmMove(from: start, to: trackFromAngle, duration: moveDuration)
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false
        }
        let track = rotation(from: trackFromAngle, to: armEndAngle, duration: remaining)
        track.beginTime = layerNow + moveDuration
        track.fillMode = animated ? .removed : .backwards
        armLayer.add(track, forKey: "armTrack")
    }

    @discardableResult
    private func addArmMove(from: CGFloat, to: CGFloat, duration: CFTimeInterval) -> CABasicAnimation {
        let move = rotation(from: from, to: to, duration: duration)
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Added before "armTrack", so the tracking animation takes over once it begins.
        armLayer.add(move, forKey: "armMove")
        return move
    }

    // MARK: Helpers

    private func rotation(from: CGFloat, to: CGFloat, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.preferredFrameRateRange = Self.frameRate
        return animation
    }

    private func currentRotation(_ layer: CALayer) -> CGFloat {
        let source = layer.presentation() ?? layer
        return (source.value(forKeyPath: "transform.rotation.z") as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }

    private func setRotation(_ layer: CALayer, _ angle: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
    }

    private func freeze(_ layer: CALayer) {
        let angle = currentRotation(layer)
        layer.removeAllAnimations()
        setRotation(layer, angle)
    }
}

/// The floating style: a transparent view showing just the record rig.
final class FloatingRecordView: NSView {
    let rig: RecordRig

    init(rig: RecordRig) {
        self.rig = rig
        super.init(frame: NSRect(origin: .zero, size: rig.layout.canvasSize))
        let host = CALayer()
        layer = host
        wantsLayer = true
        host.addSublayer(rig.root)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
