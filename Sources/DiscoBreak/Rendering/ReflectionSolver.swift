import CoreGraphics
import Foundation
import simd

/// One beam from one mirror tile, landing on the screen.
struct LightSpot {
    var offset: CGPoint     // from the ball centre, in points
    var major: CGFloat      // ellipse long axis, points
    var minor: CGFloat      // ellipse short axis, points
    var angle: CGFloat      // ellipse rotation, radians
    var intensity: CGFloat  // 0...1
    var tint: Int           // index into the palette
}

/// Works out where a mirror ball actually throws its light.
///
/// The model is the real one: a sphere tiled with flat mirrors, a spotlight off to
/// one side, and the screen standing in for the wall. For each tile we reflect the
/// light about the tile's normal and intersect that ray with the wall.
///
/// This is what the MVP was missing. Its spots each orbited on a private random
/// clock; these all sweep together because they share one rotation, and they
/// stretch into ellipses near the edges because the beams hit the wall at an angle.
struct ReflectionSolver {

    /// Tile normals on a unit sphere, laid out in latitude rows like a real ball.
    private(set) var tiles: [SIMD3<Float>] = []
    private(set) var tints: [Int] = []

    /// Distance from the ball to the wall, in ball radii.
    var wallDistance: Float = 3.4
    /// Direction from the ball toward the spotlight.
    var lightDirection = simd_normalize(SIMD3<Float>(0.30, 0.52, 1.0))
    /// Angular size of one tile — sets how fast a spot grows with distance.
    var tileSpread: Float = 0.085
    /// How hard intensity falls off with distance.
    var falloff: Float = 0.10

    init(rows: Int = 18) {
        var t: [SIMD3<Float>] = []
        var c: [Int] = []
        var rng = SystemRandomNumberGenerator()
        for r in 0..<rows {
            let phi = Float.pi * (Float(r) + 0.5) / Float(rows)
            let ringRadius = sin(phi)
            let count = max(4, Int((2 * Float.pi * ringRadius) / (Float.pi / Float(rows))))
            for i in 0..<count {
                let theta = 2 * Float.pi * Float(i) / Float(count)
                t.append(SIMD3(ringRadius * cos(theta), cos(phi), ringRadius * sin(theta)))
                // Mostly white with occasional coloured tiles, like real glass.
                c.append(Int.random(in: 0..<10, using: &rng) < 4 ? Int.random(in: 0..<4, using: &rng) : 4)
            }
        }
        tiles = t
        tints = c
    }

    var tileCount: Int { tiles.count }

    /// Spots visible on `screenSize` for a ball centred at `ballCentre`, at rotation `theta`.
    /// `pointsPerUnit` converts world units (ball radii) to screen points.
    func solve(theta: Float,
               ballCentre: CGPoint,
               screenSize: CGSize,
               pointsPerUnit: CGFloat,
               limit: Int) -> [LightSpot] {

        let c = cos(theta), s = sin(theta)
        let L = lightDirection
        var out: [LightSpot] = []
        out.reserveCapacity(limit)

        // Screen bounds relative to the ball centre, in world units.
        let halfW = Float(screenSize.width / pointsPerUnit)
        let halfH = Float(screenSize.height / pointsPerUnit)
        let leftX = Float(-ballCentre.x / pointsPerUnit) - 0.5
        let rightX = leftX + halfW + 1
        let botY = Float(-ballCentre.y / pointsPerUnit) - 0.5
        let topY = botY + halfH + 1

        for (i, n0) in tiles.enumerated() {
            // Spin the tile about the vertical axis.
            let n = SIMD3<Float>(n0.x * c + n0.z * s, n0.y, -n0.x * s + n0.z * c)

            let facing = simd_dot(n, L)
            guard facing > 0.02 else { continue }          // tile is turned away from the lamp

            // Mirror the light about the tile normal.
            let r = 2 * facing * n - L
            guard r.z < -0.03 else { continue }            // not heading toward the wall

            // Ray starts on the ball's surface and runs to the wall plane.
            let origin = n                                  // unit sphere: surface point == normal
            let t = (-wallDistance - origin.z) / r.z
            guard t > 0 else { continue }

            let hx = origin.x + r.x * t
            let hy = origin.y + r.y * t
            guard hx > leftX, hx < rightX, hy > botY, hy < topY else { continue }

            let travel = t
            // A beam widens as it goes, and smears out where it meets the wall obliquely.
            let minor = tileSpread * travel
            let incidence = max(0.16, abs(r.z))            // 1 = head on, 0 = grazing
            let major = minor / incidence

            let intensity = facing / (1 + falloff * travel * travel)

            out.append(LightSpot(
                offset: CGPoint(x: CGFloat(hx) * pointsPerUnit, y: CGFloat(hy) * pointsPerUnit),
                major: CGFloat(major) * pointsPerUnit,
                minor: CGFloat(minor) * pointsPerUnit,
                angle: CGFloat(atan2(r.y, r.x)),
                intensity: CGFloat(min(1, intensity)),
                tint: tints[i]
            ))
            if out.count >= limit { break }
        }
        return out
    }
}
