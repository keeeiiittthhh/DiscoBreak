import Foundation

/// Scales the show down when the machine can't afford to run it at full tilt.
///
/// Deliberately reads only `ProcessInfo` — no IOKit power-source plumbing, no
/// polling. Low Power Mode is the user telling the system to back off, and
/// thermal state is the system telling us the same thing. Both are free to read.
enum EnergyBudget {

    enum Level { case full, reduced, minimal }

    static var level: Level {
        let info = ProcessInfo.processInfo
        if info.thermalState == .critical { return .minimal }
        if info.isLowPowerModeEnabled || info.thermalState == .serious { return .reduced }
        return .full
    }

    /// Solver ticks per second. The ball still turns at the same speed — it just
    /// gets fewer waypoints.
    static func frameRate(_ requested: Double) -> Double {
        switch level {
        case .full:    return requested
        case .reduced: return min(requested, 20)
        case .minimal: return min(requested, 12)
        }
    }

    /// Live light spots. Secondary displays carry a thinner field: the ball isn't
    /// on them, so nobody is looking closely enough to count.
    static func spotCount(_ requested: Int, secondary: Bool) -> Int {
        var n = secondary ? Int(Double(requested) * 0.6) : requested
        switch level {
        case .full:    break
        case .reduced: n = n * 2 / 3
        case .minimal: n = n / 3
        }
        return max(12, n)
    }

    /// Latitude rings on the 3D ball. Every ring dropped removes a few dozen tile
    /// layers, so this is the cheapest dial on that ball by a distance.
    static func ballRings(_ requested: Double) -> Double {
        switch level {
        case .full:    return requested
        case .reduced: return max(9, requested * 0.7)
        case .minimal: return max(7, requested * 0.5)
        }
    }

    static var describedLevel: String {
        switch level {
        case .full:    return "full"
        case .reduced: return "reduced (low power or warm)"
        case .minimal: return "minimal (thermal throttle)"
        }
    }
}
