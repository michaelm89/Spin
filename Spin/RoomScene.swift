import AppKit
import SceneKit

/// What the room shows: album covers by URL.
struct RoomContent: Equatable {
    /// Most-played albums, best first, for the back wall.
    var wall: [String] = []
    /// Recently finished albums, newest first, for the stack on the right.
    var stack: [String] = []
    /// The current track's album, for the stand on the left.
    var nowPlaying: String?
}

/// Room dimensions in meters. The desk top is the reference height.
enum Room {
    static let deskTop: Float = 0.74
    static let wallZ: Float = -0.62
    static let panelTop: Float = deskTop + 0.083
    static let recordCenter = SIMD3<Float>(-0.06, panelTop + 0.0255, -0.12)
    static let recordDiameter: Float = 0.30
    static let sleeveSize: CGFloat = 0.315

    static let cameraPosition = SIMD3<Float>(0, 1.12, 1.8)
    static let cameraTarget = SIMD3<Float>(0, 1.05, -0.3)
    static let fieldOfView: CGFloat = 33

    static let wallRows = 4
    static let coverSize: CGFloat = 0.17
    static let coverPitch: Float = 0.192
    static let stackLimit = 7

    /// Transport buttons (previous, play/pause, next) on the turntable's front face.
    static let buttonRadius: Float = 0.016
    static let buttonCenters: [SIMD3<Float>] = [0.09, 0.14, 0.19].map {
        SIMD3($0, deskTop + 0.036, plinthFrontZ + 0.004)
    }
    static let plinthFrontZ: Float = -0.12 + 0.19
    /// The strip left of the buttons where the song and artist are printed.
    static let trackLabelMin = SIMD3<Float>(-0.225, deskTop + 0.016, plinthFrontZ + 0.001)
    static let trackLabelMax = SIMD3<Float>(0.06, deskTop + 0.056, plinthFrontZ + 0.001)

    /// How many covers fit across the visible wall for a screen of this aspect ratio.
    static func wallColumns(aspect: CGFloat) -> Int {
        let distance = cameraPosition.z - wallZ
        let halfHeight = CGFloat(distance) * tan(fieldOfView / 2 * .pi / 180)
        let width = halfHeight * 2 * aspect - 0.25
        return max(4, Int(width / CGFloat(coverPitch)))
    }

    static func wallCapacity(aspect: CGFloat) -> Int { wallRows * wallColumns(aspect: aspect) }
}

/// Renders the room to a still image off the main thread, and works out where the
/// live record layer goes so it lines up with the baked platter.
final class RoomRenderer {
    struct Bake {
        let image: CGImage
        /// Maps the record rig's canvas onto the view (anchor point at the origin).
        let recordTransform: CATransform3D
        /// Where the transport buttons appear, in view points (origin bottom-left).
        let buttonRects: [CGRect]
        /// Where the song and artist text goes, in view points.
        let trackLabelRect: CGRect
    }

    static let shared = RoomRenderer()

    private let queue = DispatchQueue(label: "spin.room-render", qos: .utility)
    private var renderer: SCNRenderer?
    /// snapshot() renders at a scale of its own choosing; this corrects for it.
    private var snapshotScale: CGFloat = 1

    /// `size` is in points; the image is rendered at `size × scale` pixels.
    func bake(content: RoomContent, images: [String: CGImage], size: CGSize, scale: CGFloat,
              rig: RecordRig.Layout, completion: @escaping (Bake?) -> Void) {
        queue.async {
            let built = RoomSceneBuilder(content: content, images: images,
                                         aspect: size.width / size.height, rig: rig).build()
            if self.renderer == nil {
                self.renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            }
            guard let renderer = self.renderer else { return DispatchQueue.main.async { completion(nil) } }
            renderer.scene = built.scene
            renderer.pointOfView = built.camera
            let targetWidth = Int((size.width * scale).rounded())
            var image = self.snapshot(renderer, size: size)
            if let rendered = image, abs(rendered.width - targetWidth) > 2 {
                self.snapshotScale *= CGFloat(targetWidth) / CGFloat(rendered.width)
                image = self.snapshot(renderer, size: size)
            }
            // Bakes are rare (track changes), so free the GPU renderer and its textures in between.
            renderer.scene = nil
            self.renderer = nil
            let project = Self.projector(camera: built.camera, viewSize: size)
            let transform = Self.recordTransform(project: project, rig: rig)
            let buttons = Room.buttonCenters.map { center -> CGRect in
                let r = Room.buttonRadius
                let a = project(center + SIMD3(-r, -r, 0)), b = project(center + SIMD3(r, r, 0))
                return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            }
            let a = project(Room.trackLabelMin), b = project(Room.trackLabelMax)
            let label = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            DispatchQueue.main.async {
                completion(image.map {
                    Bake(image: $0, recordTransform: transform, buttonRects: buttons, trackLabelRect: label)
                })
            }
        }
    }

    private func snapshot(_ renderer: SCNRenderer, size: CGSize) -> CGImage? {
        let requested = CGSize(width: (size.width * snapshotScale).rounded(), height: (size.height * snapshotScale).rounded())
        let snapshot = renderer.snapshot(atTime: 0, with: requested, antialiasingMode: .multisampling4X)
        return snapshot.representations
            .compactMap { ($0 as? NSBitmapImageRep)?.cgImage }
            .max { $0.width < $1.width }
            ?? snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: Projection

    /// World point → view point (origin bottom-left).
    private static func projector(camera: SCNNode, viewSize: CGSize) -> (SIMD3<Float>) -> CGPoint {
        let projection = simd_float4x4(camera.camera!.projectionTransform(withViewportSize: viewSize))
        let viewProjection: simd_float4x4 = projection * camera.simdWorldTransform.inverse
        return { p in
            let clip: SIMD4<Float> = viewProjection * SIMD4<Float>(p.x, p.y, p.z, 1)
            return CGPoint(x: CGFloat((clip.x / clip.w + 1) / 2) * viewSize.width,
                           y: CGFloat((clip.y / clip.w + 1) / 2) * viewSize.height)
        }
    }

    private static func recordTransform(project: (SIMD3<Float>) -> CGPoint, rig: RecordRig.Layout) -> CATransform3D {
        let canvas = rig.canvasSize
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: canvas.width, y: 0),
                       CGPoint(x: canvas.width, y: canvas.height), CGPoint(x: 0, y: canvas.height)]
        let quad = corners.map { project(RoomSceneBuilder.world(forCanvasPoint: $0, rig: rig)) }
        return homography(canvas: canvas, quad: quad)
    }

    /// Projective transform taking the canvas rectangle onto `quad` (corners in canvas order).
    private static func homography(canvas: CGSize, quad q: [CGPoint]) -> CATransform3D {
        let dx1 = q[1].x - q[2].x, dx2 = q[3].x - q[2].x, dx3 = q[0].x - q[1].x + q[2].x - q[3].x
        let dy1 = q[1].y - q[2].y, dy2 = q[3].y - q[2].y, dy3 = q[0].y - q[1].y + q[2].y - q[3].y
        let det = dx1 * dy2 - dx2 * dy1
        let g = (dx3 * dy2 - dx2 * dy3) / det
        let h = (dx1 * dy3 - dx3 * dy1) / det
        let a = q[1].x - q[0].x + g * q[1].x, b = q[3].x - q[0].x + h * q[3].x, c = q[0].x
        let d = q[1].y - q[0].y + g * q[1].y, e = q[3].y - q[0].y + h * q[3].y, f = q[0].y

        var t = CATransform3DIdentity
        t.m11 = a / canvas.width;  t.m12 = d / canvas.width;  t.m14 = g / canvas.width
        t.m21 = b / canvas.height; t.m22 = e / canvas.height; t.m24 = h / canvas.height
        t.m41 = c;                 t.m42 = f;                 t.m44 = 1
        return t
    }
}

/// Builds the SceneKit room: back wall of covers, desk, turntable, sleeve stand, sleeve stack and lamp.
struct RoomSceneBuilder {
    let content: RoomContent
    let images: [String: CGImage]
    let aspect: CGFloat
    let rig: RecordRig.Layout

    /// Where a point on the record rig's canvas sits on the turntable.
    static func world(forCanvasPoint p: CGPoint, rig: RecordRig.Layout) -> SIMD3<Float> {
        let metersPerPoint = Room.recordDiameter / Float(rig.diameter)
        let c = Room.recordCenter
        return SIMD3(c.x + Float(p.x - rig.center.x) * metersPerPoint,
                     c.y,
                     c.z - Float(p.y - rig.center.y) * metersPerPoint)
    }

    func build() -> (scene: SCNScene, camera: SCNNode) {
        let scene = SCNScene()
        scene.background.contents = NSColor(srgbRed: 0.1, green: 0.06, blue: 0.04, alpha: 1)
        let root = scene.rootNode
        root.addChildNode(makeWall())
        root.addChildNode(makeDesk())
        root.addChildNode(makeCoverWall())
        root.addChildNode(makeTurntable())
        root.addChildNode(makeStand())
        root.addChildNode(makeStack())
        root.addChildNode(makeLamp())
        addLights(to: root)
        let camera = makeCamera()
        root.addChildNode(camera)
        return (scene, camera)
    }

    // MARK: Materials

    private func material(_ contents: Any, roughness: CGFloat, metalness: CGFloat = 0,
                          repeat tiles: CGSize? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = contents
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        if let tiles {
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(tiles.width, tiles.height, 1)
        }
        return m
    }

    private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private var brass: SCNMaterial { material(color(0.80, 0.62, 0.36), roughness: 0.32, metalness: 1) }
    private var aluminum: SCNMaterial { material(color(0.78, 0.78, 0.76), roughness: 0.28, metalness: 1) }
    private var blackPlastic: SCNMaterial { material(color(0.03, 0.03, 0.03), roughness: 0.4) }
    private var cardboard: SCNMaterial { material(Textures.cardboard, roughness: 0.85) }

    /// A record sleeve. `artFace` is the SCNBox face index (0 front, 4 top) that shows the cover.
    private func sleeve(_ url: String?, size: CGFloat, thickness: CGFloat, artFace: Int) -> SCNNode {
        let isFlat = artFace == 4
        let box = SCNBox(width: size, height: isFlat ? thickness : size, length: isFlat ? size : thickness,
                         chamferRadius: thickness * 0.3)
        let art: SCNMaterial
        if let url, let image = images[url] {
            art = material(image, roughness: 0.5)
        } else {
            art = material(color(0.88, 0.85, 0.78), roughness: 0.8)
        }
        var faces = Array(repeating: cardboard, count: 6)
        faces[artFace] = art
        box.materials = faces
        let node = SCNNode(geometry: box)
        node.castsShadow = true
        return node
    }

    // MARK: Room

    private func makeWall() -> SCNNode {
        let plane = SCNPlane(width: 9, height: 5)
        plane.materials = [material(Textures.plaster, roughness: 0.95, repeat: CGSize(width: 6, height: 3.3))]
        let node = SCNNode(geometry: plane)
        node.simdPosition = SIMD3(0, 2.2, Room.wallZ)
        return node
    }

    private func makeDesk() -> SCNNode {
        let desk = SCNNode()
        let depth: CGFloat = 2.6
        let top = SCNBox(width: 5, height: 0.04, length: depth, chamferRadius: 0.004)
        let wood = material(Textures.deskWood, roughness: 0.6, repeat: CGSize(width: 5, height: 2.6))
        top.materials = [wood]
        let topNode = SCNNode(geometry: top)
        topNode.simdPosition = SIMD3(0, Room.deskTop - 0.02, Room.wallZ + Float(depth) / 2)
        desk.addChildNode(topNode)
        return desk
    }

    private func makeCoverWall() -> SCNNode {
        let group = SCNNode()
        let columns = Room.wallColumns(aspect: aspect)
        let topY: Float = 1.6
        let half = Float(Room.coverSize) / 2
        let z = Room.wallZ + 0.014

        // Leave out any slot that the lamp or the now-playing stand would hide from the camera.
        let project = projector()
        let occluders = occluderBoxes.map { box in screenRect(of: corners(box.min, box.max), project) }
        var slots: [SIMD3<Float>] = []
        for row in 0..<Room.wallRows {
            for column in 0..<columns {
                let center = SIMD3<Float>((Float(column) - Float(columns - 1) / 2) * Room.coverPitch,
                                          topY - Float(row) * Room.coverPitch, z)
                let rect = screenRect(of: corners(center - SIMD3(half, half, 0), center + SIMD3(half, half, 0)), project)
                if !occluders.contains(where: { $0.intersects(rect) }) { slots.append(center) }
            }
        }

        for (url, position) in zip(content.wall, slots) {
            let node = sleeve(url, size: Room.coverSize, thickness: 0.006, artFace: 0)
            node.simdPosition = position
            group.addChildNode(node)
        }
        return group
    }

    /// World-space boxes around the objects standing in front of the cover wall.
    private var occluderBoxes: [(min: SIMD3<Float>, max: SIMD3<Float>)] {
        let lamp = lampPosition
        return [
            (lamp + SIMD3(-0.11, 0, -0.11), lamp + SIMD3(0.11, Self.lampHeight + 0.03, 0.11)),
            (SIMD3(-0.84, Room.deskTop, -0.56), SIMD3(-0.40, Room.deskTop + 0.36, -0.36)),
        ]
    }

    /// Maps a world point to normalized screen coordinates (0…aspect, 0…1).
    private func projector() -> (SIMD3<Float>) -> CGPoint {
        let camera = makeCamera()
        let viewport = CGSize(width: aspect * 1000, height: 1000)
        let projection = simd_float4x4(camera.camera!.projectionTransform(withViewportSize: viewport))
        let viewProjection: simd_float4x4 = projection * camera.simdWorldTransform.inverse
        return { p in
            let clip: SIMD4<Float> = viewProjection * SIMD4<Float>(p.x, p.y, p.z, 1)
            return CGPoint(x: CGFloat((clip.x / clip.w + 1) / 2) * self.aspect, y: CGFloat((clip.y / clip.w + 1) / 2))
        }
    }

    private func corners(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> [SIMD3<Float>] {
        [lo.x, hi.x].flatMap { x in [lo.y, hi.y].flatMap { y in [lo.z, hi.z].map { z in SIMD3(x, y, z) } } }
    }

    private func screenRect(of points: [SIMD3<Float>], _ project: (SIMD3<Float>) -> CGPoint) -> CGRect {
        let screen = points.map(project)
        let xs = screen.map(\.x), ys = screen.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    // MARK: Turntable

    private func makeTurntable() -> SCNNode {
        let group = SCNNode()
        let center = SIMD3<Float>(0, 0, -0.12)

        let plinth = SCNBox(width: 0.50, height: 0.075, length: 0.38, chamferRadius: 0.006)
        plinth.materials = [material(Textures.walnut, roughness: 0.45)]
        let plinthNode = SCNNode(geometry: plinth)
        plinthNode.simdPosition = SIMD3(center.x, Room.deskTop + 0.0375, center.z)
        group.addChildNode(plinthNode)

        let panel = SCNBox(width: 0.486, height: 0.008, length: 0.366, chamferRadius: 0.003)
        panel.materials = [material(color(0.72, 0.68, 0.6), roughness: 0.55)]
        let panelNode = SCNNode(geometry: panel)
        panelNode.simdPosition = SIMD3(center.x, Room.panelTop - 0.004, center.z)
        group.addChildNode(panelNode)

        let platter = SCNCylinder(radius: 0.152, height: 0.022)
        platter.materials = [aluminum, blackPlastic, blackPlastic]
        let platterNode = SCNNode(geometry: platter)
        platterNode.simdPosition = SIMD3(Room.recordCenter.x, Room.panelTop + 0.011, Room.recordCenter.z)
        group.addChildNode(platterNode)

        if rig.showTonearm {
            let pivot = Self.world(forCanvasPoint: rig.pivot, rig: rig)
            let post = SCNCylinder(radius: 0.02, height: 0.026)
            post.materials = [blackPlastic]
            let postNode = SCNNode(geometry: post)
            postNode.simdPosition = SIMD3(pivot.x, Room.panelTop + 0.013, pivot.z)
            group.addChildNode(postNode)

            let collar = SCNCylinder(radius: 0.011, height: 0.008)
            collar.materials = [aluminum]
            let collarNode = SCNNode(geometry: collar)
            collarNode.simdPosition = SIMD3(pivot.x, Room.panelTop + 0.03, pivot.z)
            group.addChildNode(collarNode)
        }

        let knob = SCNCylinder(radius: 0.011, height: 0.012)
        knob.materials = [brass]
        let knobNode = SCNNode(geometry: knob)
        knobNode.simdPosition = SIMD3(center.x + 0.2, Room.panelTop + 0.006, center.z + 0.14)
        group.addChildNode(knobNode)

        // Transport button caps, facing the camera; their symbols are drawn live by TransportPanel.
        for center in Room.buttonCenters {
            let cap = SCNCylinder(radius: CGFloat(Room.buttonRadius), height: 0.008)
            let satin = material(color(0.8, 0.78, 0.73), roughness: 0.35) // brushed-look, non-metal so it isn't black
            cap.materials = [satin, satin, blackPlastic]
            let capNode = SCNNode(geometry: cap)
            capNode.simdEulerAngles = SIMD3(.pi / 2, 0, 0)
            capNode.simdPosition = center
            group.addChildNode(capNode)

            let bezel = SCNCylinder(radius: CGFloat(Room.buttonRadius) + 0.003, height: 0.002)
            bezel.materials = [blackPlastic]
            let bezelNode = SCNNode(geometry: bezel)
            bezelNode.simdEulerAngles = SIMD3(.pi / 2, 0, 0)
            bezelNode.simdPosition = SIMD3(center.x, center.y, Room.plinthFrontZ + 0.0005)
            group.addChildNode(bezelNode)
        }

        let light = SCNCylinder(radius: 0.004, height: 0.002)
        light.materials = [blackPlastic]
        let lightNode = SCNNode(geometry: light)
        lightNode.simdPosition = SIMD3(center.x + 0.15, Room.panelTop + 0.001, center.z + 0.14)
        group.addChildNode(lightNode)
        return group
    }

    // MARK: Sleeves

    /// The now-playing sleeve, leaning on a small wooden ledge.
    private func makeStand() -> SCNNode {
        let group = SCNNode()
        group.simdPosition = SIMD3(-0.62, Room.deskTop, -0.46)
        group.simdEulerAngles = SIMD3(0, 0.22, 0)

        let ledge = SCNBox(width: 0.37, height: 0.028, length: 0.08, chamferRadius: 0.003)
        ledge.materials = [material(Textures.walnut, roughness: 0.4)]
        let ledgeNode = SCNNode(geometry: ledge)
        ledgeNode.simdPosition = SIMD3(0, 0.014, 0)
        group.addChildNode(ledgeNode)

        let lean: Float = 0.13
        let size = Float(Room.sleeveSize)
        let sleeveNode = sleeve(content.nowPlaying, size: Room.sleeveSize, thickness: 0.004, artFace: 0)
        sleeveNode.simdEulerAngles = SIMD3(-lean, 0, 0)
        sleeveNode.simdPosition = SIMD3(0, 0.022 + size / 2 * cos(lean), -0.01 - size / 2 * sin(lean))
        group.addChildNode(sleeveNode)
        return group
    }

    /// Recently finished albums lying flat, newest on top.
    private func makeStack() -> SCNNode {
        let group = SCNNode()
        group.simdPosition = SIMD3(0.56, Room.deskTop, -0.16)
        group.simdEulerAngles = SIMD3(0, -0.12, 0)
        let albums = Array(content.stack.prefix(Room.stackLimit).reversed()) // bottom first
        var rng = SystemRandomNumberGenerator.seeded(7)
        for (i, url) in albums.enumerated() {
            let node = sleeve(url, size: Room.sleeveSize, thickness: 0.0034, artFace: 4)
            let jitter = i == albums.count - 1 ? 0 : 1 // keep the newest neat
            node.simdPosition = SIMD3(Float(jitter) * rng.next(in: -0.015...0.015),
                                      0.0017 + Float(i) * 0.0036,
                                      Float(jitter) * rng.next(in: -0.015...0.015))
            node.simdEulerAngles = SIMD3(0, Float(jitter) * rng.next(in: -0.14...0.14), 0)
            group.addChildNode(node)
        }
        return group
    }

    // MARK: Lamp and light

    private var lampPosition: SIMD3<Float> { SIMD3(0.9, Room.deskTop, -0.48) }
    private static let lampHeight: Float = 0.45

    /// Tiffany-style table lamp: bronze foot and column, domed stained-glass shade lit from inside.
    /// Same footprint as before: 0.19 m wide, 0.47 m tall.
    private func makeLamp() -> SCNNode {
        let group = SCNNode()
        group.simdPosition = lampPosition
        let bronze = material(color(0.055, 0.042, 0.026), roughness: 0.36, metalness: 0.2)

        func add(_ geometry: SCNGeometry, y: Float) {
            geometry.materials = [bronze]
            let node = SCNNode(geometry: geometry)
            node.simdPosition = SIMD3(0, y, 0)
            group.addChildNode(node)
        }
        // Flared, lobed foot.
        add(SCNCylinder(radius: 0.072, height: 0.008), y: 0.004)
        add(SCNTorus(ringRadius: 0.064, pipeRadius: 0.008), y: 0.01)
        add(SCNCone(topRadius: 0.024, bottomRadius: 0.062, height: 0.035), y: 0.026)
        // Turned column with collars.
        add(SCNCylinder(radius: 0.026, height: 0.012), y: 0.048)
        add(SCNCone(topRadius: 0.013, bottomRadius: 0.02, height: 0.03), y: 0.069)
        add(SCNCylinder(radius: 0.013, height: 0.16), y: 0.16)
        add(SCNTorus(ringRadius: 0.016, pipeRadius: 0.005), y: 0.15)
        add(SCNCone(topRadius: 0.024, bottomRadius: 0.013, height: 0.03), y: 0.255)
        add(SCNCylinder(radius: 0.024, height: 0.008), y: 0.274)
        // Socket under the shade.
        add(SCNCylinder(radius: 0.016, height: 0.03), y: 0.292)

        let glass = SCNMaterial()
        glass.lightingModel = .constant
        glass.diffuse.contents = Textures.stainedGlass
        glass.diffuse.intensity = 5.5 // offsets the camera's negative exposure, and feeds the bloom
        glass.isDoubleSided = true
        let shade = SCNNode(geometry: domeShade())
        shade.geometry?.materials = [glass]
        shade.castsShadow = false
        group.addChildNode(shade)

        // Finial on top.
        add(SCNSphere(radius: 0.011), y: 0.458)
        return group
    }

    /// Surface of revolution: a short skirt at the rim curving up into a dome.
    /// u runs around the shade, v from the top (0) to the rim (1).
    private func domeShade() -> SCNGeometry {
        let rimY: Float = 0.315, skirtTop: Float = 0.345, topY: Float = 0.452
        let rim: Float = 0.095, skirt: Float = 0.092
        var profile: [(r: Float, y: Float)] = []
        let domeSteps = 24
        for i in 0...domeSteps { // top → base of dome
            let theta = Float.pi / 2 * Float(i) / Float(domeSteps)
            profile.append((skirt * sin(theta) + 0.004, skirtTop + (topY - skirtTop) * cos(theta)))
        }
        profile.append((rim, rimY))

        // Arc length gives an even v along the profile.
        var lengths: [Float] = [0]
        for i in 1..<profile.count {
            lengths.append(lengths[i - 1] + hypot(profile[i].r - profile[i - 1].r, profile[i].y - profile[i - 1].y))
        }
        let segments = 96
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], uvs: [CGPoint] = []
        for (i, point) in profile.enumerated() {
            let prev = profile[max(i - 1, 0)], next = profile[min(i + 1, profile.count - 1)]
            let tangent = SIMD2(next.r - prev.r, next.y - prev.y)
            let outward = simd_normalize(SIMD2(tangent.y, -tangent.x))
            for j in 0...segments {
                let angle = Float(j) / Float(segments) * 2 * .pi
                vertices.append(SCNVector3(point.r * cos(angle), point.y, point.r * sin(angle)))
                normals.append(SCNVector3(outward.x * cos(angle), outward.y, outward.x * sin(angle)))
                uvs.append(CGPoint(x: CGFloat(j) / CGFloat(segments), y: CGFloat(lengths[i] / lengths.last!)))
            }
        }
        var indices: [Int32] = []
        let ring = Int32(segments + 1)
        for i in 0..<Int32(profile.count - 1) {
            for j in 0..<Int32(segments) {
                let a = i * ring + j, b = a + ring
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
                                     SCNGeometrySource(normals: normals),
                                     SCNGeometrySource(textureCoordinates: uvs)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    private func addLights(to root: SCNNode) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = color(0.95, 0.75, 0.58)
        ambient.intensity = 14
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        // Warm key light from the upper left, like low evening sun.
        let key = SCNLight()
        key.type = .spot
        key.color = color(1.0, 0.8, 0.58)
        key.intensity = 700
        key.spotInnerAngle = 15
        key.spotOuterAngle = 62
        key.castsShadow = true
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.shadowSampleCount = 16
        key.shadowRadius = 5
        key.shadowBias = 0.5
        key.shadowColor = NSColor(white: 0, alpha: 0.72)
        key.zNear = 0.5
        key.zFar = 8
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdPosition = SIMD3(-2.6, 2.9, 1.6)
        keyNode.simdLook(at: SIMD3(0.1, 0.95, -0.45))
        root.addChildNode(keyNode)

        // Soft wash over the cover wall from above.
        let wash = SCNLight()
        wash.type = .spot
        wash.color = color(1.0, 0.82, 0.62)
        wash.intensity = 90
        wash.spotInnerAngle = 30
        wash.spotOuterAngle = 100
        wash.castsShadow = true
        wash.shadowMapSize = CGSize(width: 2048, height: 2048)
        wash.shadowSampleCount = 16
        wash.shadowRadius = 6
        wash.shadowColor = NSColor(white: 0, alpha: 0.5)
        let washNode = SCNNode()
        washNode.light = wash
        washNode.simdPosition = SIMD3(0.2, 2.6, 0.7)
        washNode.simdLook(at: SIMD3(0, 1.3, Room.wallZ))
        root.addChildNode(washNode)

        // The Tiffany lamp. The bulb sits inside the shade, so most light leaves through the open
        // bottom: a warm downward cone that pools on the desk and fans across the lower wall,
        // with the column casting its shadow.
        let bulb = lampPosition + SIMD3(0, 0.33, 0)
        let pool = SCNLight()
        pool.type = .spot
        pool.color = color(1.0, 0.72, 0.4)
        pool.intensity = 32
        pool.spotInnerAngle = 70
        pool.spotOuterAngle = 150
        pool.attenuationStartDistance = 0
        pool.attenuationEndDistance = 1.6
        pool.attenuationFalloffExponent = 2
        pool.castsShadow = true
        pool.shadowMapSize = CGSize(width: 1024, height: 1024)
        pool.shadowSampleCount = 12
        pool.shadowRadius = 4
        pool.shadowColor = NSColor(white: 0, alpha: 0.55)
        pool.zNear = 0.02
        let poolNode = SCNNode()
        poolNode.light = pool
        poolNode.simdPosition = bulb
        poolNode.simdLook(at: bulb - SIMD3(0, 1, 0))
        root.addChildNode(poolNode)

        // The glass itself only lets a faint, cooler-tinted glow out to the sides.
        let glow = SCNLight()
        glow.type = .omni
        glow.color = color(0.95, 0.88, 0.72)
        glow.intensity = 4
        glow.attenuationStartDistance = 0
        glow.attenuationEndDistance = 0.6
        glow.attenuationFalloffExponent = 2
        let glowNode = SCNNode()
        glowNode.light = glow
        glowNode.simdPosition = bulb + SIMD3(0, 0.03, 0.14)
        root.addChildNode(glowNode)
    }

    private func makeCamera() -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = Room.fieldOfView
        camera.zNear = 0.1
        camera.zFar = 20
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -2.25
        camera.bloomIntensity = 0.7
        camera.bloomThreshold = 1.6 // only the lamp glows; covers stay crisp
        camera.bloomBlurRadius = 14
        camera.vignettingIntensity = 0.55
        camera.vignettingPower = 0.45
        camera.screenSpaceAmbientOcclusionIntensity = 1.0
        camera.screenSpaceAmbientOcclusionRadius = 0.12
        camera.grainIntensity = 0.06
        camera.wantsDepthOfField = true
        camera.focusDistance = CGFloat(simd_distance(Room.cameraPosition, Room.recordCenter))
        camera.fStop = 4
        let node = SCNNode()
        node.camera = camera
        node.simdPosition = Room.cameraPosition
        node.simdLook(at: Room.cameraTarget)
        return node
    }
}

private extension SystemRandomNumberGenerator {
    /// Deterministic jitter so the stack doesn't reshuffle on every bake.
    static func seeded(_ seed: UInt64) -> SeededGenerator { SeededGenerator(state: seed) }
}

struct SeededGenerator {
    var state: UInt64
    mutating func next(in range: ClosedRange<Float>) -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Float(state >> 40) / Float(1 << 24)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}
