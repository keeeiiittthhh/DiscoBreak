import AppKit
import CoreImage
import QuartzCore

/// The second ball: real square mirrors placed on a sphere in 3D, instead of the
/// classic ball's painted disc with a facet grid scrolling across it.
///
/// Geometry follows Bojan's "CSS 3D Disco Ball"
/// (https://codepen.io/bojan-c/pen/VxbLmX): walk latitude rings from pole to pole,
/// fit as many square tiles as each ring's circumference allows, lay each one flat
/// against the sphere, and hide the ones that end up facing away.
///
/// Core Animation does here what `transform-style: preserve-3d` does there — a
/// `CATransformLayer` keeps its sublayers in one 3D space, so the whole ball turns
/// on a single hardware animation with no per-frame CPU work at all. The tiles
/// really do go round the back; the silhouette really does squash them.
enum MirrorBall3D {

    /// The layer that carries the rotation. `CARenderer` looks it up by name.
    static let spinnerName = "spinner"

    static func make(radius r: CGFloat) -> CALayer {
        let d = r * 2

        let wrapper = CALayer()
        wrapper.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        wrapper.masksToBounds = false
        // A little perspective, so tiles on the far side of the sphere sit back
        // rather than reading as a flat pattern.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / (d * 4)
        wrapper.sublayerTransform = perspective

        wrapper.addSublayer(glow(radius: r))
        wrapper.addSublayer(core(radius: r))

        let spinner = CATransformLayer()
        spinner.name = spinnerName
        spinner.bounds = wrapper.bounds
        spinner.position = CGPoint(x: r, y: r)
        for tile in tiles(radius: r) { spinner.addSublayer(tile) }
        wrapper.addSublayer(spinner)

        return wrapper
    }

    // MARK: - Tiles

    private static func tiles(radius r: CGFloat) -> [CALayer] {
        let size = max(4, r * 0.13)          // same tile-to-ball ratio as the reference
        let rings = EnergyBudget.ballRings(20)
        let fuzzy = 0.001
        let step = (Double.pi - fuzzy) / Double(rings)

        var out: [CALayer] = []
        var rng = SystemRandomNumberGenerator()

        var lat = fuzzy
        while lat < .pi {
            // Latitude runs down the vertical axis, so the rings stack like the
            // bands on a real ball. (The reference pen builds its rings around the
            // axis pointing at the viewer and tips the whole sphere 90 degrees
            // afterwards; doing it here instead means the spin is a plain turn
            // about y, matching the axis the reflection solver already uses.)
            let y = r * CGFloat(cos(lat))
            // Deliberately under-filled: a ring packed to its exact circumference
            // looks crowded, and the gaps let the dark core read as grout.
            let ringRadius = 0.8 * r * CGFloat(sin(lat))
            let fits = max(1, Int((2 * .pi * ringRadius) / size))
            let angleStep = (2 * Double.pi - fuzzy) / Double(fits)
            // Tiles around the equator catch the lamp most, so they run brighter.
            let equator = lat > 1.3 && lat < 1.9

            var lon = angleStep / 2 + fuzzy
            while lon < 2 * .pi {
                let x = r * CGFloat(cos(lon) * sin(lat))
                let z = r * CGFloat(sin(lon) * sin(lat))

                let f = CALayer()
                f.bounds = CGRect(x: 0, y: 0, width: size - 0.7, height: size - 0.7)
                f.position = CGPoint(x: r, y: r)
                f.isDoubleSided = false      // the back of the ball culls itself
                f.backgroundColor = mirror(bright: equator, &rng)

                // Move out to the sphere, then turn the tile flat against it:
                // these two angles are exactly the pair that takes a tile's own
                // facing direction onto the outward normal at this point.
                var m = CATransform3DMakeTranslation(x, y, z)
                m = CATransform3DRotate(m, CGFloat(Double.pi / 2 - lon), 0, 1, 0)
                m = CATransform3DRotate(m, CGFloat(lat - Double.pi / 2), 1, 0, 0)
                f.transform = m

                out.append(f)
                lon += angleStep
            }
            lat += step
        }
        return out
    }

    private static func mirror(bright: Bool, _ rng: inout SystemRandomNumberGenerator) -> CGColor {
        let w = bright
            ? CGFloat.random(in: 0.51...1.00, using: &rng)
            : CGFloat.random(in: 0.43...0.75, using: &rng)
        // The same cool cast the classic ball uses, so the two match the light field.
        return NSColor(calibratedRed: w * 0.94, green: w * 0.97, blue: w, alpha: 1).cgColor
    }

    // MARK: - Body and glow

    /// Sits behind the tiles so the gaps read as a dark sphere rather than holes.
    private static func core(radius r: CGFloat) -> CALayer {
        let body = CAGradientLayer()
        body.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        body.position = CGPoint(x: r, y: r)
        body.cornerRadius = r
        body.masksToBounds = true
        body.colors = [
            NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.19, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.08, alpha: 1).cgColor
        ]
        body.startPoint = CGPoint(x: 0.3, y: 1.0)
        body.endPoint = CGPoint(x: 0.7, y: 0.0)
        return body
    }

    /// The halo the reference pen gets from a blurred white circle — cheaper here
    /// as a radial gradient, and additive so it lifts whatever is behind it.
    private static func glow(radius r: CGFloat) -> CALayer {
        let halo = CAGradientLayer()
        halo.type = .radial
        halo.bounds = CGRect(x: 0, y: 0, width: r * 3.4, height: r * 3.4)
        halo.position = CGPoint(x: r, y: r)
        halo.colors = [
            NSColor(calibratedRed: 0.78, green: 0.88, blue: 1.0, alpha: 0.30).cgColor,
            NSColor(calibratedRed: 0.62, green: 0.78, blue: 1.0, alpha: 0.10).cgColor,
            NSColor(calibratedWhite: 1, alpha: 0.0).cgColor
        ]
        halo.locations = [0.0, 0.30, 0.62]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1.0, y: 1.0)
        halo.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        return halo
    }

    // MARK: - Twinkle
    //
    // Individual mirrors catching the lamp. One opacity animation per tile, each
    // with its own length and a random head start so they never pulse in unison.
    // Added when the show starts and removed when it ends, so nothing animates
    // while the ball is parked in the notch.

    static func startTwinkle(on spinner: CALayer) {
        guard EnergyBudget.level == .full else { return }
        guard let tiles = spinner.sublayers,
              spinner.value(forKey: twinklingKey) == nil else { return }
        spinner.setValue(true, forKey: twinklingKey)

        var rng = SystemRandomNumberGenerator()
        // One mirror in six, not all of them. Real ones don't all flare at once,
        // and this is the difference between eighty animations and five hundred.
        for tile in tiles where Double.random(in: 0...1, using: &rng) < 0.17 {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0
            a.toValue = Double.random(in: 0.30...0.65, using: &rng)
            a.duration = Double.random(in: 1.3...2.6, using: &rng)
            a.timeOffset = Double.random(in: 0...2.6, using: &rng)
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            tile.add(a, forKey: "twinkle")
        }
    }

    static func stopTwinkle(on spinner: CALayer) {
        spinner.sublayers?.forEach { $0.removeAllAnimations() }
        spinner.setValue(nil, forKey: twinklingKey)
    }

    /// Which tiles twinkle is decided at random each time, so "is the first tile
    /// animating?" is no longer a safe way to ask whether this already ran.
    private static let twinklingKey = "DiscoBreakTwinkling"
}
