import AppKit
import Metal
import QuartzCore

/// The third ball: real mirrors drawn on the GPU, throwing a few hundred soft
/// specks of light that sweep across the screen as it turns.
///
/// Separate from the other two on purpose. They are layer trees run by
/// `CARenderer`; this is one `CAMetalLayer` dropped into the same overlay window,
/// with its own frame loop on its own thread. Nothing it does touches their code.
///
/// Per frame the CPU writes one 80-byte struct and issues eight draw calls. Every
/// tile, speck, beam, glint and the shadow are worked out on the GPU from the same tile
/// buffer, built once when the stage is.
///
/// The frame loop runs only while the ball is down and its window can be seen.
/// Retracting stops it, and the camera with it; tearing the stage down releases
/// every GPU object it made.
final class HyperrealBall: DiscoRenderer {

    private let settings: Settings
    /// False on secondary displays: they get the light, not the ball.
    private let carriesBall: Bool

    private var metalLayer: CAMetalLayer?
    private var stage: HyperrealStage?
    private var clock: FrameClock?
    private var camera: CameraReflection?
    private var occlusion: NSObjectProtocol?
    private let motion = Locked(HyperrealMotion())

    private var shown = false
    private var visible = true
    /// Same guard as CARenderer's: a retract's timer only acts if no drop came after it.
    private var generation = 0
    /// Bumped on attach and detach, so a shader compile that finishes late lands nowhere.
    private var attachment = 0

    init(settings: Settings, carriesBall: Bool) {
        self.settings = settings
        self.carriesBall = carriesBall
    }

    // MARK: - Build

    func attach(to hostLayer: CALayer, screenFrame: CGRect, notchCenterX: CGFloat) {
        detach()
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("DiscoBreak hyperreal: no Metal device — nothing to draw with")
            return
        }
        let window = NSApp.windows.first { ($0 as? OverlayWindow)?.hostLayer === hostLayer }
        let scale = window?.backingScaleFactor ?? 2

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.frame = hostLayer.bounds
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: hostLayer.bounds.width * scale,
                                    height: hostLayer.bounds.height * scale)
        hostLayer.addSublayer(layer)
        metalLayer = layer

        let stage = HyperrealStage(settings: settings, viewSize: screenFrame.size,
                                   hangX: carriesBall ? notchCenterX : screenFrame.width / 2,
                                   carriesBall: carriesBall)
        self.stage = stage

        if carriesBall, settings.ballCamera {
            camera = CameraReflection(device: device)
        }

        // A screen lock or a display going to sleep hides the overlay; stop
        // drawing for as long as it stays hidden.
        if let window {
            occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                self?.visible = window?.occlusionState.contains(.visible) ?? true
                self?.updateClock()
            }
        }

        attachment += 1
        let ticket = attachment
        let motion = self.motion
        let camera = self.camera
        let room: (() -> HyperrealPainter.Room?)? = camera.map { cam in
            { cam.latest().map { ($0.texture, $0.owner as AnyObject) } }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let painter: HyperrealPainter
            do {
                painter = try HyperrealPainter(device: device, stage: stage, motion: motion, room: room)
            } catch {
                NSLog("DiscoBreak hyperreal: could not build the GPU side — %@", String(describing: error))
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.attachment == ticket else { return }
                self.clock = FrameClock(layer: layer, painter: painter)
                self.updateClock()
            }
        }
    }

    func detach() {
        attachment += 1
        clock?.stop(); clock = nil
        camera?.stop(); camera = nil
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        metalLayer?.removeFromSuperlayer(); metalLayer = nil
        stage = nil
        shown = false
        motion.update { $0 = HyperrealMotion() }
    }

    // MARK: - Show control

    func drop() {
        guard let stage else { return }
        generation += 1
        let now = CACurrentMediaTime()
        motion.update { $0.change(to: .dropping, at: now, stage: stage) }
        shown = true
        camera?.start()
        updateClock()
    }

    func retract(completion: @escaping () -> Void) {
        guard let stage else { completion(); return }
        let era = generation
        let now = CACurrentMediaTime()
        motion.update { $0.change(to: .retracting, at: now, stage: stage) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) { [weak self] in
            guard let self, self.generation == era else { return }
            self.shown = false
            self.camera?.stop()
            self.updateClock()
            completion()
        }
    }

    private func updateClock() {
        clock?.isRunning = shown && visible
    }
}

// MARK: - Where the ball is

/// Fixed geometry for one display, in points, origin bottom-left.
struct HyperrealStage {
    let viewSize: CGSize
    /// Top of the cord, at the top edge of the screen.
    let pivot: CGPoint
    /// Pivot to ball centre once it has dropped.
    let reach: Double
    let radius: Double
    /// How far above its resting place the ball sits when hidden in the notch.
    let hiddenLift: Double
    let carriesBall: Bool

    let rotationSeconds: Double
    let wall: Float
    let intensity: Float
    let dim: Float
    let stiffness: Double, damping: Double

    /// A size and a height of its own: 30% bigger and 30% lower than the other
    /// two, so it reads as a different ball rather than a restyle of the same one.
    /// The Look sliders still scale it.
    static let sizeScale = 1.3
    static let dropScale = 1.3

    init(settings: Settings, viewSize: CGSize, hangX: CGFloat, carriesBall: Bool) {
        self.viewSize = viewSize
        self.pivot = CGPoint(x: hangX, y: viewSize.height)
        self.radius = Double(settings.ballDiameter) / 2 * Self.sizeScale
        self.reach = Double(settings.dropDistance) * Self.dropScale
        self.hiddenLift = reach + radius * 2.2
        self.carriesBall = carriesBall
        self.rotationSeconds = max(1, settings.rotationSeconds)
        self.wall = Float(settings.wallDistance)
        self.intensity = Float(settings.lightIntensity)
        self.dim = Float(min(0.85, max(0, settings.dimBackground)))
        self.stiffness = Double(settings.dropStiffness)
        self.damping = Double(settings.dropDamping)
    }

    func frame(at t: Double, pose: HyperrealMotion.Pose, hasCamera: Bool) -> HyperrealFrame {
        // Hangs, so it sways a little — the same period and swing as the other two.
        let sway = 0.018 * sin(2 * .pi * t / 6.2)
        let length = reach - pose.lift
        let centre = SIMD2<Float>(Float(Double(pivot.x) + sin(sway) * length),
                                  Float(Double(pivot.y) - cos(sway) * length))

        var f = HyperrealFrame()
        f.viewSize = SIMD2(Float(viewSize.width), Float(viewSize.height))
        f.centre = centre
        f.radius = Float(radius)
        // From the shared media clock, like the other two: never drifts, and two
        // displays stay in lockstep without talking to each other.
        f.theta = Float(t.truncatingRemainder(dividingBy: rotationSeconds) / rotationSeconds * 2 * .pi)
        f.time = Float(t.truncatingRemainder(dividingBy: 1000))
        f.opacity = Float(pose.opacity)
        f.wall = wall
        f.intensity = intensity
        f.hasCamera = hasCamera ? 1 : 0
        f.pivot = SIMD2(Float(pivot.x), Float(pivot.y))
        f.dim = dim
        return f
    }

    /// Closed-form damped spring, the same one `CASpringAnimation` runs for the
    /// other two balls (mass 1.1), so the drop feels identical.
    func spring(from start: Double, after t: Double) -> Double {
        let mass = 1.1
        let w0 = (stiffness / mass).squareRoot()
        let zeta = min(0.999, damping / (2 * (stiffness * mass).squareRoot()))
        let wd = w0 * (1 - zeta * zeta).squareRoot()
        return exp(-zeta * w0 * t) * (start * cos(wd * t) + (zeta * w0 * start / wd) * sin(wd * t))
    }
}

/// Drop and retract, as a function of time rather than as animations, so the
/// render thread can ask "where is it now?" for any frame without a callback.
struct HyperrealMotion {
    enum Phase { case hidden, dropping, retracting }
    /// `lift` is points above the resting place; `opacity` fades the whole stage.
    typealias Pose = (lift: Double, opacity: Double)

    private var phase = Phase.hidden
    private var since: Double = 0
    private var from: Pose = (0, 0)

    func pose(at t: Double, stage: HyperrealStage) -> Pose {
        let dt = max(0, t - since)
        let hidden = stage.carriesBall ? stage.hiddenLift : 0
        switch phase {
        case .hidden:
            return (hidden, 0)
        case .dropping:
            let lift = stage.carriesBall ? stage.spring(from: from.lift, after: dt) : 0
            let fade = stage.carriesBall ? 0.18 : 0.55
            return (lift, from.opacity + (1 - from.opacity) * min(1, dt / fade))
        case .retracting:
            let u = min(1, dt / 0.45)
            return (from.lift + (hidden - from.lift) * u * u,      // ease in
                    from.opacity * (1 - min(1, dt / 0.40)))
        }
    }

    /// Starts from wherever the ball is right now, so a hesitant pointer never makes it jump.
    mutating func change(to next: Phase, at t: Double, stage: HyperrealStage) {
        from = pose(at: t, stage: stage)
        phase = next
        since = t
    }
}

// MARK: - The frame clock

/// A `CAMetalDisplayLink` on a thread of its own. It ticks at the display's own
/// rate — 120Hz on ProMotion, 60 elsewhere, lower when the Mac is hot or on Low
/// Power — and the main thread never waits on it or runs a frame.
private final class FrameClock {
    private let link: CAMetalDisplayLink
    private let loop: CFRunLoop
    /// The link holds its delegate weakly; this keeps the painter alive for it.
    private let painter: HyperrealPainter

    init(layer: CAMetalLayer, painter: HyperrealPainter) {
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = painter
        link.preferredFrameLatency = 2
        let fps = Float(EnergyBudget.frameRate(120))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
        link.isPaused = true

        var found: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            found = CFRunLoopGetCurrent()
            link.add(to: .current, forMode: .default)
            ready.signal()
            CFRunLoopRun()                  // until stop()
        }
        thread.name = "DiscoBreak hyperreal frames"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        self.link = link
        self.loop = found!
        self.painter = painter
    }

    var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            let link = link, paused = !isRunning
            perform { link.isPaused = paused }
        }
    }

    func stop() {
        let link = link
        perform {
            link.invalidate()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    /// Changes to the link happen on its own thread, never under it.
    private func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }
}
