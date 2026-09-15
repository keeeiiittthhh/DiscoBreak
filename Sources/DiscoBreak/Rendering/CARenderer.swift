import AppKit
import CoreImage
import QuartzCore

/// Core Animation disco ball — the v1 placeholder for the eventual Metal renderer.
///
/// Layer tree (AppKit coords, +y up):
///
///     host
///     └── rig            pivot inside the notch; position.y animates for drop/retract
///         ├── chain      vertical line from the notch down to the ball
///         ├── rays       CAReplicatorLayer starburst, additive, rotating
///         ├── spots      orbiting light blobs, additive, rotating the other way
///         └── ball       mirrored sphere (gradient + facet grid + specular)
final class CARenderer: DiscoRenderer {

    /// A secondary display gets the light field only — the ball itself hangs on the
    /// notch screen. Two balls on two screens would read as two balls, not one room.
    enum Role { case full, lightsOnly }

    let settings: Settings
    let role: Role

    private var rig: CALayer?
    private var ball: CALayer?
    private var spots: CALayer?
    private var rays: CALayer?
    private var chain: CAShapeLayer?
    private var facets: CALayer?

    private var solver = ReflectionSolver()
    private var spotPool: [CALayer] = []
    private var solverTimer: Timer?
    private var ballCentreOnScreen: CGPoint = .zero
    private var screenSize: CGSize = .zero
    private var pointsPerUnit: CGFloat = 1

    private var hiddenY: CGFloat = 0
    private var shownY: CGFloat = 0

    init(settings: Settings, role: Role = .full) {
        self.settings = settings
        self.role = role
    }

    // MARK: - Build

    func attach(to hostLayer: CALayer, screenFrame: CGRect, notchCenterX: CGFloat) {
        detach()

        let radius = settings.ballDiameter / 2
        let drop = settings.dropDistance
        let topY = screenFrame.height          // host layer is screen-sized, origin 0,0

        let rig = CALayer()
        rig.bounds = .zero
        rig.masksToBounds = false
        rig.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        shownY = topY
        // Far enough up that the ball and its glow are entirely inside the notch cutout.
        hiddenY = topY + drop + radius * 2.2
        // A lights-only stage never travels: the field just fades up in place.
        rig.position = CGPoint(x: notchCenterX, y: role == .full ? hiddenY : shownY)
        if role == .lightsOnly { rig.opacity = 0 }

        let ballCentre = CGPoint(x: 0, y: -drop)

        // --- chain -------------------------------------------------------
        let chain = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 40))     // start above the pivot so it never shows a gap
        path.addLine(to: CGPoint(x: 0, y: ballCentre.y + radius * 0.35))
        chain.path = path
        chain.strokeColor = NSColor(calibratedWhite: 0.72, alpha: 0.95).cgColor
        chain.lineWidth = 2.5
        chain.fillColor = nil
        chain.shadowColor = NSColor.black.cgColor
        chain.shadowOpacity = 0.45
        chain.shadowRadius = 2
        chain.shadowOffset = CGSize(width: 1, height: -1)

        // --- light rays (starburst) --------------------------------------
        let rays = makeRayBurst(radius: radius)
        rays.position = ballCentre

        if role == .full {
            rig.addSublayer(chain)
            rig.addSublayer(rays)
        }

        // --- light spots, driven by the reflection solver -----------------
        let (spots, pool) = makeSpots(
            count: EnergyBudget.spotCount(settings.spotCount, secondary: role != .full))
        spots.position = ballCentre
        spotPool = pool
        solver.wallDistance = Float(settings.wallDistance)
        pointsPerUnit = radius
        screenSize = screenFrame.size
        ballCentreOnScreen = CGPoint(x: notchCenterX, y: topY - drop)
        rig.addSublayer(spots)

        // --- the ball itself ---------------------------------------------
        let ball = makeBall(radius: radius)
        ball.position = ballCentre
        if role == .full { rig.addSublayer(ball) }

        hostLayer.addSublayer(rig)

        self.rig = rig
        self.ball = ball
        self.spots = spots
        self.rays = rays
        self.chain = chain
        self.facets = role == .full
            ? ball.sublayers?.first?.sublayers?.first(where: { $0.name == "facets" })
            : nil
    }

    func detach() {
        rig?.removeAllAnimations()
        rig?.removeFromSuperlayer()
        solverTimer?.invalidate(); solverTimer = nil
        spotPool.removeAll()
        rig = nil; ball = nil; spots = nil; rays = nil; chain = nil; facets = nil
    }

    // MARK: - Show control

    func drop() {
        guard let rig else { return }
        rig.removeAnimation(forKey: "travel")

        startPerpetualMotion()

        guard role == .full else {
            fade(to: 1.0, duration: 0.55)
            return
        }

        let current = rig.presentation()?.position.y ?? rig.position.y
        let spring = CASpringAnimation(keyPath: "position.y")
        spring.fromValue = current
        spring.toValue = shownY
        spring.damping = settings.dropDamping
        spring.stiffness = settings.dropStiffness
        spring.mass = 1.1
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false

        rig.position.y = shownY
        rig.add(spring, forKey: "travel")

        fade(to: 1.0, duration: 0.18)
    }

    func retract(completion: @escaping () -> Void) {
        guard let rig else { completion(); return }
        rig.removeAnimation(forKey: "travel")

        guard role == .full else {
            fade(to: 0.0, duration: 0.40)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
                self?.stopPerpetualMotion()
                completion()
            }
            return
        }

        let current = rig.presentation()?.position.y ?? rig.position.y
        let pull = CABasicAnimation(keyPath: "position.y")
        pull.fromValue = current
        pull.toValue = hiddenY
        pull.duration = 0.45
        pull.timingFunction = CAMediaTimingFunction(name: .easeIn)
        pull.fillMode = .forwards
        pull.isRemovedOnCompletion = false

        rig.position.y = hiddenY
        rig.add(pull, forKey: "travel")

        fade(to: 0.0, duration: 0.40)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) { [weak self] in
            self?.stopPerpetualMotion()
            completion()
        }
    }

    private func fade(to opacity: Float, duration: CFTimeInterval) {
        guard let rig else { return }
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = rig.presentation()?.opacity ?? rig.opacity
        f.toValue = opacity
        f.duration = duration
        f.fillMode = .forwards
        f.isRemovedOnCompletion = false
        rig.opacity = opacity
        rig.add(f, forKey: "fade")
    }

    // MARK: - Perpetual motion

    private func startPerpetualMotion() {
        scrollFacets()
        startSolverLoop()
        spin(rays, seconds: settings.rotationSeconds, clockwise: false, key: "orbit")

        // Gentle pendulum, so it reads as hanging rather than pinned.
        if let rig, rig.animation(forKey: "sway") == nil {
            let sway = CABasicAnimation(keyPath: "transform.rotation.z")
            sway.fromValue = -0.018
            sway.toValue = 0.018
            sway.duration = 3.1
            sway.autoreverses = true
            sway.repeatCount = .infinity
            sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            rig.add(sway, forKey: "sway")
        }
    }

    private func stopPerpetualMotion() {
        solverTimer?.invalidate()
        solverTimer = nil
        [spots, rays, facets].forEach { $0?.removeAllAnimations() }
        rig?.removeAnimation(forKey: "sway")
    }

    // MARK: - The solver loop
    //
    // Recomputes the whole light field each frame. ~105 live spots out of 406 tiles;
    // three property writes each, with implicit animation off so Core Animation
    // doesn't try to interpolate between frames.

    private func startSolverLoop() {
        guard solverTimer == nil, !spotPool.isEmpty else { return }
        let hz = EnergyBudget.frameRate(settings.frameRate)
        let t = Timer(timeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
            self?.updateSpots()
        }
        RunLoop.main.add(t, forMode: .common)
        solverTimer = t
        updateSpots()
    }

    /// Derived from the shared media clock rather than accumulated per tick, so a
    /// dropped frame never drifts — and so two displays running their own timers
    /// stay in exact lockstep without any plumbing between them.
    private var theta: Float {
        let period = max(1.0, settings.rotationSeconds)
        let phase = CACurrentMediaTime().truncatingRemainder(dividingBy: period) / period
        return Float(phase * 2 * .pi)
    }

    private func updateSpots() {
        let spots = solver.solve(theta: theta,
                                 ballCentre: ballCentreOnScreen,
                                 screenSize: screenSize,
                                 pointsPerUnit: pointsPerUnit,
                                 limit: spotPool.count)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let unit = CARenderer.spotUnit
        for (i, layer) in spotPool.enumerated() {
            guard i < spots.count else {
                if !layer.isHidden { layer.isHidden = true }
                continue
            }
            let s = spots[i]
            if layer.isHidden { layer.isHidden = false }
            layer.position = s.offset
            layer.opacity = Float(s.intensity * settings.lightIntensity)
            var t = CATransform3DMakeRotation(s.angle, 0, 0, 1)
            t = CATransform3DScale(t, s.major / unit, s.minor / unit, 1)
            layer.transform = t
        }

        CATransaction.commit()
    }

    /// Slides the facet grid sideways and wraps, which reads as the sphere turning.
    private func scrollFacets() {
        guard let facets, facets.animation(forKey: "scroll") == nil else { return }
        let tileSpan = facets.bounds.width / 3
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = 0
        a.toValue = -tileSpan
        a.duration = settings.rotationSeconds
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        facets.add(a, forKey: "scroll")
    }

    private func spin(_ layer: CALayer?, seconds: Double, clockwise: Bool, key: String) {
        guard let layer, layer.animation(forKey: key) == nil else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = clockwise ? -Double.pi * 2 : Double.pi * 2
        a.duration = seconds
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: key)
    }
}
