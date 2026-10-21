import CoreGraphics

/// Renders the whole record (vinyl, grooves, label, spindle) into a single bitmap,
/// so spinning it is just rotating one textured layer.
enum DiscRenderer {
    /// Label radius as a fraction of the record radius.
    static let labelRatio: CGFloat = 0.36
    /// Innermost groove radius as a fraction of the record radius.
    static let innerGrooveRatio: CGFloat = labelRatio * 1.12
    /// Outermost groove radius as a fraction of the record radius.
    static let outerGrooveRatio: CGFloat = 0.965

    static func image(diameter: CGFloat, scale: CGFloat, artwork: CGImage?, labelTint: CGColor? = nil) -> CGImage? {
        let pixels = Int((diameter * scale).rounded(.up))
        guard let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.scaleBy(x: CGFloat(pixels) / diameter, y: CGFloat(pixels) / diameter)
        ctx.interpolationQuality = .high

        let r = diameter / 2
        let center = CGPoint(x: r, y: r)
        let labelR = r * labelRatio
        func circle(_ radius: CGFloat) -> CGRect {
            CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }

        // Vinyl body.
        ctx.setFillColor(gray(0.055))
        ctx.fillEllipse(in: circle(r))

        // Grooves: many faint concentric rings with slightly varying brightness.
        var rng = SplitMix64(seed: 0x5EED)
        let step = max(0.9, r / 220)
        ctx.setLineWidth(step * 0.45)
        var grooveR = r * outerGrooveRatio
        while grooveR > r * innerGrooveRatio {
            ctx.setStrokeColor(gray(0.085 + 0.06 * rng.nextUnit()))
            ctx.strokeEllipse(in: circle(grooveR))
            grooveR -= step * (0.8 + 0.4 * rng.nextUnit())
        }

        // Gaps between tracks: smooth, darker bands.
        ctx.setStrokeColor(gray(0.035))
        ctx.setLineWidth(max(1.2, r * 0.008))
        for fraction in [0.84, 0.73, 0.63, 0.52] as [CGFloat] {
            ctx.strokeEllipse(in: circle(r * fraction))
        }

        // Smooth run-out area between the last groove and the label.
        let runout = CGMutablePath()
        runout.addEllipse(in: circle(r * innerGrooveRatio))
        runout.addEllipse(in: circle(labelR))
        ctx.addPath(runout)
        ctx.setFillColor(gray(0.06))
        ctx.fillPath(using: .evenOdd)

        // Rim.
        ctx.setStrokeColor(gray(0.22))
        ctx.setLineWidth(0.75)
        ctx.strokeEllipse(in: circle(r - 0.5))

        // Label.
        ctx.saveGState()
        ctx.addEllipse(in: circle(labelR))
        ctx.clip()
        if let artwork {
            let aspect = CGFloat(artwork.width) / CGFloat(max(artwork.height, 1))
            var rect = circle(labelR)
            if aspect > 1 {
                rect = rect.insetBy(dx: -(rect.height * aspect - rect.width) / 2, dy: 0)
            } else if aspect < 1 {
                rect = rect.insetBy(dx: 0, dy: -(rect.width / aspect - rect.height) / 2)
            }
            ctx.draw(artwork, in: rect)
        } else {
            let colors = [
                CGColor(srgbRed: 0.72, green: 0.16, blue: 0.12, alpha: 1),
                CGColor(srgbRed: 0.45, green: 0.07, blue: 0.06, alpha: 1),
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1]) {
                ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: labelR, options: [])
            }
        }
        if let labelTint {
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(labelTint)
            ctx.fill(circle(labelR))
        }
        ctx.restoreGState()

        // Label edge.
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.45))
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: circle(labelR))

        // Spindle.
        let spindle = circle(r * 0.022)
        ctx.setFillColor(gray(0.78))
        ctx.fillEllipse(in: spindle)
        ctx.setStrokeColor(gray(0.35))
        ctx.setLineWidth(0.75)
        ctx.strokeEllipse(in: spindle)

        return ctx.makeImage()
    }

    private static func gray(_ white: CGFloat) -> CGColor {
        CGColor(srgbRed: white, green: white, blue: white, alpha: 1)
    }
}

/// Small deterministic RNG so the groove pattern is identical on every render.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53)
    }
}
