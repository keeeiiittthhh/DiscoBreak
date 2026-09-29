import Metal
import QuartzCore
import simd

/// Per-frame uniforms. Field order and types mirror `Frame` in `HyperrealShaders`
/// exactly — Swift and Metal lay these out identically, 80 bytes.
struct HyperrealFrame {
    var viewSize: SIMD2<Float> = .zero
    var centre: SIMD2<Float> = .zero
    var radius: Float = 0
    var theta: Float = 0
    var time: Float = 0
    var opacity: Float = 0
    var eye: Float = 7
    var wall: Float = 3.4
    var intensity: Float = 1
    var hasCamera: Float = 0
    /// The same lamp position the reflection solver uses, so all three balls are lit alike.
    var light = SIMD4<Float>(simd_normalize(SIMD3<Float>(0.30, 0.52, 1.0)), 0)
    var pivot: SIMD2<Float> = .zero
    var cordWidth: Float = 1.2
    /// How dark the screen goes behind the show, 0...0.85.
    var dim: Float = 0
}

/// One mirror. Mirrors `Tile` in `HyperrealShaders`.
struct HyperrealTile {
    var normal: SIMD4<Float>
    var mirror: SIMD4<Float>
    var tint: SIMD4<Float>
}

/// Everything the render thread touches. Built whole off the main thread, never
/// changed afterwards — the only live inputs are the motion (behind a lock) and
/// the camera's latest frame (behind its own).
final class HyperrealPainter: NSObject, CAMetalDisplayLinkDelegate {

    /// A frame to reflect, and whatever has to stay alive while the GPU reads it.
    typealias Room = (texture: MTLTexture, owner: AnyObject)

    let tileCount: Int
    private let queue: MTLCommandQueue
    private let tiles: MTLBuffer
    private let pipes: Pipes
    private let stage: HyperrealStage
    private let motion: Locked<HyperrealMotion>
    private let room: (() -> Room?)?
    private let beams: Bool
    private let glints: Bool

    /// Compiles the shaders, so it belongs on a background queue: about 100ms
    /// the first time, near nothing once Metal's own cache has them.
    init(device: MTLDevice, stage: HyperrealStage, motion: Locked<HyperrealMotion>,
         room: (() -> Room?)?) throws {
        guard let queue = device.makeCommandQueue() else { throw HyperrealError.noQueue }
        let tiles = Self.makeTiles(rings: EnergyBudget.ballRings(28))
        guard let buffer = device.makeBuffer(bytes: tiles,
                                             length: MemoryLayout<HyperrealTile>.stride * tiles.count,
                                             options: .storageModeShared)
        else { throw HyperrealError.noBuffer }

        self.queue = queue
        self.tiles = buffer
        self.tileCount = tiles.count
        self.pipes = try Pipes(device: device)
        self.stage = stage
        self.motion = motion
        self.room = room
        // Energy is read once per show; a change of power state rebuilds the stage anyway.
        self.beams = EnergyBudget.level == .full
        self.glints = EnergyBudget.level != .minimal
        super.init()
    }

    // MARK: - Frame loop

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard let commands = queue.makeCommandBuffer() else { return }
        let frame = room?()
        encode(into: update.drawable.texture, commands,
               at: update.targetPresentationTimestamp, room: frame?.texture)
        commands.present(update.drawable)
        if let owner = frame?.owner {
            commands.addCompletedHandler { _ in withExtendedLifetime(owner) {} }
        }
        commands.commit()
    }

    /// One whole frame: eight draw calls, whatever the tile count. Also used on its
    /// own to render stills and time the GPU without putting anything on screen.
    func encode(into target: MTLTexture, _ commands: MTLCommandBuffer, at time: Double,
                room: MTLTexture?) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        var f = stage.frame(at: time, pose: motion.value.pose(at: time, stage: stage),
                            hasCamera: room != nil)
        f.light.w = beams ? 0.03 : 0

        encoder.setVertexBuffer(tiles, offset: 0, index: 0)
        encoder.setVertexBytes(&f, length: MemoryLayout<HyperrealFrame>.stride, index: 1)
        encoder.setFragmentBytes(&f, length: MemoryLayout<HyperrealFrame>.stride, index: 0)
        encoder.setFragmentTexture(room ?? pipes.blank, index: 0)
        encoder.setFragmentSamplerState(pipes.sampler, index: 0)

        func draw(_ pipe: MTLRenderPipelineState, _ instances: Int) {
            encoder.setRenderPipelineState(pipe)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: instances)
        }
        if f.dim > 0 { draw(pipes.dim, 1) }
        if stage.carriesBall { draw(pipes.shadow, 1) }
        if beams { draw(pipes.beam, tileCount) }
        draw(pipes.speck, tileCount)
        if stage.carriesBall {
            draw(pipes.cord, 1)
            draw(pipes.core, 1)
            draw(pipes.tile, tileCount)
            if glints { draw(pipes.glint, tileCount) }
        }
        encoder.endEncoding()
    }

    // MARK: - Tiles

    /// Latitude rings from pole to pole, as many square mirrors per ring as its
    /// circumference fits. Each one is tipped a degree or two off true and has
    /// its own silvering, which is where the individual sparkle comes from.
    static func makeTiles(rings: Int) -> [HyperrealTile] {
        var out: [HyperrealTile] = []
        var rng = SystemRandomNumberGenerator()
        let step = Float.pi / Float(rings)
        let cool = SIMD3<Float>(0.84, 0.91, 1.0)
        let warm = SIMD3<Float>(1.0, 0.9, 0.76)
        // About one mirror in four catches something coloured in the room —
        // a lamp shade, a poster, a red light on a speaker — and throws that.
        let colours: [SIMD3<Float>] = [
            SIMD3(1.0, 0.62, 0.32),   // amber
            SIMD3(1.0, 0.45, 0.62),   // rose
            SIMD3(0.42, 0.78, 1.0),   // sky
            SIMD3(0.68, 0.52, 1.0),   // violet
        ]

        for ring in 0..<rings {
            let lat = step * (Float(ring) + 0.5)
            let y = cos(lat), ringRadius = sin(lat)
            let count = max(3, Int((2 * .pi * ringRadius / step).rounded()))
            // Real balls don't line their rings up; neither do these.
            let stagger = Float.random(in: 0..<1, using: &rng)
            for i in 0..<count {
                let lon = 2 * .pi * (Float(i) + stagger) / Float(count)
                let n = SIMD3<Float>(ringRadius * cos(lon), y, ringRadius * sin(lon))
                let wobble = SIMD3<Float>(.random(in: -1...1, using: &rng),
                                          .random(in: -1...1, using: &rng),
                                          .random(in: -1...1, using: &rng))
                let facing = simd_normalize(n + wobble * 0.03)       // about two degrees at most
                let tint = Float.random(in: 0...1, using: &rng) < 0.25
                    ? colours.randomElement(using: &rng)!
                    : simd_mix(cool, warm, SIMD3(repeating: .random(in: 0...1, using: &rng)))
                out.append(HyperrealTile(
                    normal: SIMD4(n, step * 0.5),
                    mirror: SIMD4(facing, .random(in: 0.86...1.0, using: &rng)),
                    tint: SIMD4(tint, .random(in: 0..<1, using: &rng))))
            }
        }
        return out
    }

    // MARK: - Pipelines

    private struct Pipes {
        let dim, shadow, beam, speck, cord, core, tile, glint: MTLRenderPipelineState
        let sampler: MTLSamplerState
        /// Bound when there is no camera frame, so the tile shader never reads an empty slot.
        let blank: MTLTexture

        init(device: MTLDevice) throws {
            let library = try device.makeLibrary(source: HyperrealShaders.source, options: nil)

            func pipe(_ name: String, additive: Bool) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: name + "Vertex")
                d.fragmentFunction = library.makeFunction(name: name + "Fragment")
                let c = d.colorAttachments[0]!
                c.pixelFormat = .bgra8Unorm
                c.isBlendingEnabled = true
                // Premultiplied throughout. Additive draws add their colour, so
                // overlapping specks build up into brighter light.
                c.sourceRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                // Alpha always composites "over", even for light. Summing it
                // instead would make a speck on a dimmed white window come out
                // exactly as grey as the window around it.
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: d)
            }
            dim = try pipe("dim", additive: false)
            shadow = try pipe("shadow", additive: false)
            beam = try pipe("beam", additive: true)
            speck = try pipe("speck", additive: true)
            cord = try pipe("cord", additive: false)
            core = try pipe("core", additive: false)
            tile = try pipe("tile", additive: false)
            glint = try pipe("glint", additive: true)

            let s = MTLSamplerDescriptor()
            s.minFilter = .linear
            s.magFilter = .linear
            s.sAddressMode = .mirrorRepeat
            s.tAddressMode = .mirrorRepeat
            guard let sampler = device.makeSamplerState(descriptor: s) else { throw HyperrealError.noSampler }
            self.sampler = sampler

            let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                             width: 1, height: 1, mipmapped: false)
            guard let blank = device.makeTexture(descriptor: t) else { throw HyperrealError.noTexture }
            self.blank = blank
        }
    }
}

enum HyperrealError: Error { case noQueue, noBuffer, noSampler, noTexture }

/// A value shared between the main thread and the render thread.
final class Locked<Value> {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
