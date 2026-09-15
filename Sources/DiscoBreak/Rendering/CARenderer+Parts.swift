import AppKit
import CoreImage
import QuartzCore

extension CARenderer {

    // MARK: - The ball
    //
    // A sphere faked in 2D: a circular mask, a facet grid that scrolls sideways
    // (which reads as rotation about a vertical axis — spinning the whole layer
    // would read as a wheel instead), edge shading, and a specular highlight.

    func makeBall(radius r: CGFloat) -> CALayer {
        let d = r * 2

        let ball = CALayer()
        ball.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        ball.cornerRadius = r
        ball.masksToBounds = true
        ball.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 1).cgColor

        // --- facet grid, 3 ball-widths wide so it can scroll seamlessly ---
        let tile: CGFloat = max(7, d / 13)
        let cols = Int((d * 3) / tile) + 2
        let rows = Int(d / tile) + 2

        let scroller = CALayer()
        scroller.name = "facets"
        scroller.bounds = CGRect(x: 0, y: 0, width: CGFloat(cols) * tile, height: CGFloat(rows) * tile)
        scroller.anchorPoint = CGPoint(x: 0, y: 0.5)
        scroller.position = CGPoint(x: 0, y: r)
        scroller.masksToBounds = false

        var generator = SystemRandomNumberGenerator()
        for c in 0..<cols {
            for row in 0..<rows {
                let f = CALayer()
                f.bounds = CGRect(x: 0, y: 0, width: tile - 1.2, height: tile - 1.2)
                f.position = CGPoint(x: CGFloat(c) * tile + tile / 2,
                                     y: CGFloat(row) * tile + tile / 2)
                f.cornerRadius = 1

                // Brighter near the vertical centre band, dimmer toward the poles.
                let yNorm = abs((CGFloat(row) / CGFloat(rows)) - 0.5) * 2   // 0 centre .. 1 pole
                let poleFalloff = 1.0 - yNorm * 0.55
                let jitter = CGFloat.random(in: 0.35...1.0, using: &generator)
                let w = 0.30 + 0.70 * jitter * poleFalloff

                f.backgroundColor = NSColor(calibratedRed: w * 0.94,
                                            green: w * 0.97,
                                            blue: w * 1.0,
                                            alpha: 1).cgColor
                scroller.addSublayer(f)
            }
        }
        ball.addSublayer(scroller)

        // --- spherical shading: dark at the rim, transparent in the middle ---
        let shade = CAGradientLayer()
        shade.type = .radial
        shade.frame = ball.bounds
        shade.colors = [
            NSColor(calibratedWhite: 0, alpha: 0.0).cgColor,
            NSColor(calibratedWhite: 0, alpha: 0.22).cgColor,
            NSColor(calibratedWhite: 0, alpha: 0.82).cgColor
        ]
        shade.locations = [0.0, 0.62, 1.0]
        shade.startPoint = CGPoint(x: 0.42, y: 0.60)
        shade.endPoint = CGPoint(x: 1.05, y: 1.20)
        ball.addSublayer(shade)

        // --- specular highlight, upper left ---
        let spec = CAGradientLayer()
        spec.type = .radial
        spec.bounds = CGRect(x: 0, y: 0, width: d * 0.62, height: d * 0.62)
        spec.position = CGPoint(x: d * 0.34, y: d * 0.68)
        spec.colors = [
            NSColor(calibratedWhite: 1, alpha: 0.85).cgColor,
            NSColor(calibratedWhite: 1, alpha: 0.18).cgColor,
            NSColor(calibratedWhite: 1, alpha: 0.0).cgColor
        ]
        spec.locations = [0.0, 0.40, 1.0]
        spec.startPoint = CGPoint(x: 0.5, y: 0.5)
        spec.endPoint = CGPoint(x: 1.0, y: 1.0)
        spec.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        ball.addSublayer(spec)

        // --- outer glow so it sits in the light instead of on top of it ---
        ball.shadowColor = NSColor(calibratedRed: 0.75, green: 0.85, blue: 1.0, alpha: 1).cgColor
        ball.shadowOpacity = 0.9
        ball.shadowRadius = r * 0.5
        ball.shadowOffset = .zero
        ball.masksToBounds = true

        // The shadow needs an unmasked parent to be visible outside the circle.
        let wrapper = CALayer()
        wrapper.bounds = ball.bounds
        wrapper.masksToBounds = false
        wrapper.addSublayer(ball)
        ball.position = CGPoint(x: r, y: r)
        return wrapper
    }

    // MARK: - Light spots
    //
    // A fixed pool of elliptical blobs. Positions, sizes and angles are recomputed
    // every frame by ReflectionSolver, so the whole field sweeps together as the
    // ball turns instead of each blob orbiting on its own clock.
    //
    // Each layer keeps a 100x100 radial gradient and is stretched into an ellipse
    // with a transform — one cheap property to set per frame instead of resizing.

    static let spotUnit: CGFloat = 100

    func makeSpots(count: Int) -> (container: CALayer, pool: [CALayer]) {
        let container = CALayer()
        container.bounds = .zero
        container.masksToBounds = false

        var generator = SystemRandomNumberGenerator()
        var pool: [CALayer] = []
        pool.reserveCapacity(count)

        for _ in 0..<count {
            let spot = CAGradientLayer()
            spot.type = .radial
            spot.bounds = CGRect(x: 0, y: 0, width: Self.spotUnit, height: Self.spotUnit)
            spot.startPoint = CGPoint(x: 0.5, y: 0.5)
            spot.endPoint = CGPoint(x: 1.0, y: 1.0)
            spot.compositingFilter = CIFilter(name: "CIAdditionCompositing")
            spot.isHidden = true

            // Tint is fixed per pool slot. On a real ball the colour comes from the
            // lamp, not the tile, and a stable tint stops the field from flickering
            // as tiles rotate in and out of view.
            let colour = Self.palette.randomElement(using: &generator)!
            spot.colors = [
                colour.withAlphaComponent(0.95).cgColor,
                colour.withAlphaComponent(0.34).cgColor,
                colour.withAlphaComponent(0.0).cgColor
            ]
            spot.locations = [0.0, 0.30, 1.0]

            container.addSublayer(spot)
            pool.append(spot)
        }
        return (container, pool)
    }

    // MARK: - Ray burst

    func makeRayBurst(radius r: CGFloat) -> CALayer {
        let replicator = CAReplicatorLayer()
        replicator.bounds = .zero
        replicator.masksToBounds = false
        replicator.instanceCount = settings.rayCount
        replicator.preservesDepth = false

        let step = (CGFloat.pi * 2) / CGFloat(settings.rayCount)
        replicator.instanceTransform = CATransform3DMakeRotation(step, 0, 0, 1)

        let length = r * 9
        let ray = CAGradientLayer()
        ray.bounds = CGRect(x: 0, y: 0, width: r * 0.52, height: length)
        ray.anchorPoint = CGPoint(x: 0.5, y: 0.0)
        ray.position = .zero
        ray.colors = [
            NSColor(calibratedRed: 0.80, green: 0.90, blue: 1.0, alpha: 0.40).cgColor,
            NSColor(calibratedRed: 0.65, green: 0.80, blue: 1.0, alpha: 0.08).cgColor,
            NSColor(calibratedWhite: 1, alpha: 0.0).cgColor
        ]
        ray.locations = [0.0, 0.35, 1.0]
        ray.startPoint = CGPoint(x: 0.5, y: 0.0)
        ray.endPoint = CGPoint(x: 0.5, y: 1.0)
        ray.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        replicator.addSublayer(ray)

        return replicator
    }

    static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.42, green: 0.85, blue: 1.00, alpha: 1),   // cyan
        NSColor(calibratedRed: 1.00, green: 0.38, blue: 0.86, alpha: 1),   // magenta
        NSColor(calibratedRed: 0.62, green: 0.48, blue: 1.00, alpha: 1),   // violet
        NSColor(calibratedRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),   // white
        NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.00, alpha: 1)    // blue
    ]
}
