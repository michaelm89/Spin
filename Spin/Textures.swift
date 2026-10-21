import CoreGraphics
import Foundation

/// Procedural surface textures for the room, generated once.
enum Textures {
    typealias RGB = (r: Double, g: Double, b: Double)

    static let deskWood = wood(size: 1024, dark: (0.26, 0.11, 0.05), light: (0.52, 0.26, 0.12), rings: 0.11, seed: 1)
    static let walnut = wood(size: 512, dark: (0.13, 0.07, 0.04), light: (0.30, 0.17, 0.09), rings: 0.2, seed: 2)
    static let plaster = noise(size: 512, base: (0.80, 0.70, 0.60), amount: 0.035, scale: 0.02, seed: 3)
    static let cardboard = noise(size: 128, base: (0.86, 0.82, 0.74), amount: 0.04, scale: 0.2, seed: 4)

    static let stainedGlass = makeStainedGlass()

    /// Tiffany-style shade, laid out top (y = 0) to rim (y = 1) with 16 columns around.
    private static func makeStainedGlass() -> CGImage {
        let w = 1024, h = 512, columns = 16
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)) // draw top-down
        ctx.scaleBy(x: 1, y: -1)
        let W = CGFloat(w), H = CGFloat(h), col = W / CGFloat(columns)
        var rng = SystemRandomNumberGenerator()
        func glass(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ f: CGFloat) -> CGColor {
            // Mottled glass, a little brighter toward the rim where the bulb is closer.
            let m = 0.94 + CGFloat.random(in: 0...0.08, using: &rng) + f * 0.06
            return CGColor(srgbRed: min(r * m, 1), green: min(g * m, 1), blue: min(b * m, 1), alpha: 1)
        }
        let paleBlue = (0.80, 0.91, 0.94), lavender = (0.72, 0.67, 0.88), cream = (0.97, 0.90, 0.68)
        let yellow = (0.98, 0.80, 0.28), red = (0.82, 0.1, 0.1)
        let lead = CGColor(srgbRed: 0.07, green: 0.06, blue: 0.05, alpha: 1)
        func band(_ f0: CGFloat, _ f1: CGFloat, _ c: (Double, Double, Double)) {
            for i in 0..<columns {
                ctx.setFillColor(glass(c.0, c.1, c.2, f1))
                ctx.fill(CGRect(x: CGFloat(i) * col, y: f0 * H, width: col, height: (f1 - f0) * H))
            }
        }
        func hLead(_ f: CGFloat, _ width: CGFloat = 4) {
            ctx.setFillColor(lead)
            ctx.fill(CGRect(x: 0, y: f * H - width / 2, width: W, height: width))
        }
        func vLeads(_ f0: CGFloat, _ f1: CGFloat, offset: CGFloat = 0) {
            ctx.setFillColor(lead)
            for i in 0...columns {
                ctx.fill(CGRect(x: CGFloat(i) * col + offset * col - 1.5, y: f0 * H, width: 3, height: (f1 - f0) * H))
            }
        }

        // Dark crown.
        ctx.setFillColor(lead)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: 0.06 * H))
        // Two rows of pale blue panels, staggered like brickwork.
        band(0.06, 0.31, paleBlue); vLeads(0.06, 0.31)
        band(0.31, 0.56, paleBlue); vLeads(0.31, 0.56, offset: 0.5)
        hLead(0.06); hLead(0.31)
        // Lavender scallops hanging from each panel.
        band(0.56, 0.66, cream)
        for i in 0..<columns {
            let x = CGFloat(i) * col
            let arc = CGMutablePath()
            arc.move(to: CGPoint(x: x, y: 0.56 * H))
            arc.addQuadCurve(to: CGPoint(x: x + col, y: 0.56 * H), control: CGPoint(x: x + col / 2, y: 0.68 * H))
            arc.closeSubpath()
            ctx.addPath(arc)
            ctx.setFillColor(glass(lavender.0, lavender.1, lavender.2, 0.6))
            ctx.fillPath()
            ctx.addPath(arc)
            ctx.setStrokeColor(lead)
            ctx.setLineWidth(3)
            ctx.strokePath()
        }
        hLead(0.56)
        // Cream row with a small yellow diamond in each panel.
        band(0.66, 0.77, cream); vLeads(0.66, 0.77)
        for i in 0..<columns {
            let c = CGPoint(x: (CGFloat(i) + 0.5) * col, y: 0.715 * H), r = 0.035 * H
            let diamond = CGMutablePath()
            diamond.addLines(between: [CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + r * 0.8, y: c.y),
                                       CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x - r * 0.8, y: c.y)])
            diamond.closeSubpath()
            ctx.addPath(diamond)
            ctx.setFillColor(glass(yellow.0, yellow.1, yellow.2, 0.7))
            ctx.fillPath()
            ctx.addPath(diamond)
            ctx.setStrokeColor(lead)
            ctx.setLineWidth(2.5)
            ctx.strokePath()
        }
        hLead(0.66); hLead(0.77)
        // Dark ornamental band with red jewels.
        ctx.setFillColor(CGColor(srgbRed: 0.26, green: 0.2, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0.77 * H, width: W, height: 0.09 * H))
        for i in 0..<(columns * 2) {
            let x = CGFloat(i) * col / 2
            ctx.setFillColor(glass(cream.0 * 0.8, cream.1 * 0.75, cream.2 * 0.6, 0.8))
            ctx.fill(CGRect(x: x + col * 0.08, y: 0.79 * H, width: col * 0.34, height: 0.05 * H))
        }
        for i in 0..<columns where i % 2 == 0 {
            let c = CGPoint(x: (CGFloat(i) + 1) * col, y: 0.815 * H), r = 0.03 * H
            ctx.setFillColor(glass(red.0, red.1, red.2, 0.8))
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(lead)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        hLead(0.86)
        // Zigzag skirt: alternating pale blue and cream triangles.
        for i in 0..<(columns * 2) {
            let x = CGFloat(i) * col / 2
            let up = CGMutablePath(), down = CGMutablePath()
            up.addLines(between: [CGPoint(x: x, y: H), CGPoint(x: x + col / 4, y: 0.86 * H), CGPoint(x: x + col / 2, y: H)])
            down.addLines(between: [CGPoint(x: x - col / 4, y: 0.86 * H), CGPoint(x: x, y: H), CGPoint(x: x + col / 4, y: 0.86 * H)])
            for (path, c) in [(down, cream), (up, paleBlue)] {
                ctx.addPath(path)
                ctx.setFillColor(glass(c.0, c.1, c.2, 1))
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(lead)
                ctx.setLineWidth(2.5)
                ctx.strokePath()
            }
        }
        hLead(0.995, 6) // rim
        return ctx.makeImage()!
    }

    /// Long grain running along x, with warped growth rings and fine pores.
    static func wood(size: Int, dark: RGB, light: RGB, rings: Double, seed: UInt32) -> CGImage {
        let n = ValueNoise(seed: seed)
        return makeImage(size: size) { x, y in
            let fx = Double(x), fy = Double(y)
            let warp = n.fbm(fx * 0.004, fy * 0.03, octaves: 4) * 30
            let ring = 0.5 + 0.5 * sin((fy + warp) * rings)
            let streak = n.fbm(fx * 0.002, fy * 0.25, octaves: 3)
            let pores = n.value(fx * 0.6, fy * 3) * 0.12
            let t = min(max(ring * 0.55 + streak * 0.45 - pores, 0), 1)
            return (dark.r + (light.r - dark.r) * t, dark.g + (light.g - dark.g) * t, dark.b + (light.b - dark.b) * t)
        }
    }

    static func noise(size: Int, base: RGB, amount: Double, scale: Double, seed: UInt32) -> CGImage {
        let n = ValueNoise(seed: seed)
        return makeImage(size: size) { x, y in
            let v = (n.fbm(Double(x) * scale, Double(y) * scale, octaves: 4) - 0.5) * 2 * amount
                + (n.value(Double(x) * 0.9, Double(y) * 0.9) - 0.5) * amount * 0.5
            return (base.r + v, base.g + v, base.b + v)
        }
    }

    private static func makeImage(size: Int, pixel: (Int, Int) -> RGB) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let c = pixel(x, y)
                let i = (y * size + x) * 4
                bytes[i] = UInt8(min(max(c.r, 0), 1) * 255)
                bytes[i + 1] = UInt8(min(max(c.g, 0), 1) * 255)
                bytes[i + 2] = UInt8(min(max(c.b, 0), 1) * 255)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

/// Tileable-enough 2D value noise.
private struct ValueNoise {
    private var table = [Double](repeating: 0, count: 256)
    private var perm = [Int](repeating: 0, count: 512)

    init(seed: UInt32) {
        var state = seed &* 747796405 &+ 2891336453
        func next() -> UInt32 {
            state = state &* 747796405 &+ 2891336453
            let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277803737
            return (word >> 22) ^ word
        }
        for i in 0..<256 { table[i] = Double(next() % 10000) / 10000 }
        var p = Array(0..<256)
        for i in stride(from: 255, to: 0, by: -1) { p.swapAt(i, Int(next() % UInt32(i + 1))) }
        for i in 0..<512 { perm[i] = p[i & 255] }
    }

    func value(_ x: Double, _ y: Double) -> Double {
        let xi = Int(floor(x)), yi = Int(floor(y))
        let xf = x - floor(x), yf = y - floor(y)
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
        func h(_ i: Int, _ j: Int) -> Double { table[perm[(perm[i & 255] + j) & 511] & 255] }
        let a = h(xi, yi), b = h(xi + 1, yi), c = h(xi, yi + 1), d = h(xi + 1, yi + 1)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }

    func fbm(_ x: Double, _ y: Double, octaves: Int) -> Double {
        var sum = 0.0, amp = 0.5, freq = 1.0, norm = 0.0
        for _ in 0..<octaves {
            sum += value(x * freq, y * freq) * amp
            norm += amp
            amp *= 0.5
            freq *= 2
        }
        return sum / norm
    }
}
