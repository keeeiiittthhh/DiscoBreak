import CoreGraphics
import Foundation

/// Which ball hangs on the chain. Both throw the same physics-driven light field;
/// they differ in how the sphere itself is drawn.
enum BallStyle: String, Codable, CaseIterable {
    /// Painted disc: one circle, a facet grid scrolling across it, edge shading.
    case classic = "Classic"
    /// Several hundred square mirrors arranged on a real sphere, turning in 3D.
    case mirror = "Mirror tiles"
}

/// What hangs on the chain, as the picker and the menu offer it.
///
/// The third ball is a renderer of its own rather than a third `BallStyle`: that
/// way `CARenderer`, which switches between the first two, never has to learn
/// about it, and the first two stay exactly as they were.
enum BallChoice: String, CaseIterable {
    case classic = "Classic"
    case mirror = "Mirror tiles"
    case hyperreal = "Hyperreal"
}

extension Settings {
    var ballChoice: BallChoice {
        get { hyperrealBall ? .hyperreal : (ballStyle == .mirror ? .mirror : .classic) }
        set {
            hyperrealBall = newValue == .hyperreal
            // Choosing the third ball leaves the remembered style alone, so
            // switching back lands on whichever of the other two was last used.
            switch newValue {
            case .classic:   ballStyle = .classic
            case .mirror:    ballStyle = .mirror
            case .hyperreal: break
            }
        }
    }
}

/// Tunables. Defaults are baked in; drop a JSON file at
/// ~/Library/Application Support/DiscoBreak/settings.json to override any subset.
struct Settings: Codable {

    // Geometry
    var ballStyle: BallStyle = .mirror
    /// The GPU ball. Overrides `ballStyle` while it is on.
    var hyperrealBall: Bool = false
    /// Opt-in: the GPU ball's mirrors reflect the camera instead of a studio.
    var ballCamera: Bool = false
    /// How much the GPU ball darkens the screen while it's down, 0...0.85, so the light reads.
    var dimBackground: Double = 0.45
    var ballDiameter: CGFloat = 116
    var dropDistance: CGFloat = 230      // ball centre, in points below the notch

    // Motion
    /// Real mirror ball motors run at 2-3 RPM. The MVP's 7s was 8.5 RPM and read as frantic.
    var rotationSeconds: Double = 25
    var frameRate: Double = 30
    var dropDamping: CGFloat = 13
    var dropStiffness: CGFloat = 110

    // Light rig
    var spotCount: Int = 140          // pool size; ~105 are live at any moment
    /// Ball-to-wall distance in ball radii. Tuned: 3.4 gives ~105 spots at 1.5x stretch.
    var wallDistance: Double = 3.4
    var rayCount: Int = 20
    var lightIntensity: CGFloat = 1.0

    // Music. Spotify is the only source: nothing plays from disk and nothing
    // ships in the bundle.
    var volume: Double = 0.75
    var spotifyPlaylist: String = ""
    var spotifyShuffle: Bool = true

    // Interaction
    var hotZonePadding: CGFloat = 8      // grow the notch rect so it's forgiving
    var exitDelay: TimeInterval = 0.4    // pointer must be out this long before retracting
    var pollHz: Double = 20
    /// Throw light onto every attached display, not just the notch one.
    var multiDisplay: Bool = true

    static let `default` = Settings()

    // Swift's synthesized Decodable init demands every key be present, which would
    // make a partial settings.json fail to decode and silently fall back to defaults.
    // Decode each field independently instead, so overriding one value is enough.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        ballStyle         = v(.ballStyle,         d.ballStyle)
        hyperrealBall     = v(.hyperrealBall,     d.hyperrealBall)
        ballCamera        = v(.ballCamera,        d.ballCamera)
        dimBackground     = v(.dimBackground,     d.dimBackground)
        ballDiameter      = v(.ballDiameter,      d.ballDiameter)
        dropDistance      = v(.dropDistance,      d.dropDistance)
        rotationSeconds   = v(.rotationSeconds,   d.rotationSeconds)
        frameRate         = v(.frameRate,         d.frameRate)
        wallDistance      = v(.wallDistance,      d.wallDistance)
        dropDamping       = v(.dropDamping,       d.dropDamping)
        dropStiffness     = v(.dropStiffness,     d.dropStiffness)
        spotCount         = v(.spotCount,         d.spotCount)
        rayCount          = v(.rayCount,          d.rayCount)
        lightIntensity    = v(.lightIntensity,    d.lightIntensity)
        volume            = v(.volume,            d.volume)
        spotifyPlaylist   = v(.spotifyPlaylist,   d.spotifyPlaylist)
        spotifyShuffle    = v(.spotifyShuffle,    d.spotifyShuffle)
        hotZonePadding    = v(.hotZonePadding,    d.hotZonePadding)
        exitDelay         = v(.exitDelay,         d.exitDelay)
        pollHz            = v(.pollHz,            d.pollHz)
        multiDisplay      = v(.multiDisplay,      d.multiDisplay)
    }

    static func load() -> Settings {
        guard let url = supportDirectory()?.appendingPathComponent("settings.json"),
              let data = try? Data(contentsOf: url) else { return .default }
        do {
            let decoded = try JSONDecoder().decode(Settings.self, from: data)
            NSLog("DiscoBreak settings: loaded %@", url.path)
            return decoded
        } catch {
            NSLog("DiscoBreak settings: %@ is not valid JSON (%@) — using defaults",
                  url.path, error.localizedDescription)
            return .default
        }
    }

    static func supportDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("DiscoBreak", isDirectory: true)
    }
}
