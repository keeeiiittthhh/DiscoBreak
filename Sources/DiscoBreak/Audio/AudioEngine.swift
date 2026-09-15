import AVFoundation
import Foundation

/// Looping music with volume ramps.
///
/// Track resolution, in order:
///   1. any audio file in ~/Library/Application Support/DiscoBreak/   ← your own copy,
///      whatever it happens to be called. A file named loop.* wins if several are present.
///   2. the loop bundled in DiscoBreak.app/Contents/Resources
///   3. nothing — the show runs silent
final class LocalMusicSource: MusicSource {

    private var player: AVAudioPlayer?
    private var rampTimer: Timer?
    private let targetVolume: Float
    private let startOffset: TimeInterval

    init(settings: Settings = .default) {
        targetVolume = Float(settings.volume)
        startOffset = settings.trackStartSeconds
        guard let url = Self.resolveTrack() else {
            NSLog("DiscoBreak: no audio track found, running silent")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            player = p
            trackName = url.deletingPathExtension().lastPathComponent
            NSLog("DiscoBreak audio: %@", url.path)
        } catch {
            NSLog("DiscoBreak: could not load %@ — %@", url.path, error.localizedDescription)
        }
    }

    private static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac"]

    static func resolveTrack() -> URL? {
        // 1. Whatever the user dropped in the support folder — any name, any format.
        if let dir = Settings.supportDirectory(),
           let files = try? FileManager.default.contentsOfDirectory(
               at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {

            let audio = files.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            // An explicit loop.* is the tiebreaker; otherwise take the first alphabetically
            // so the choice is stable across launches.
            if let preferred = audio.first(where: { $0.deletingPathExtension().lastPathComponent == "loop" }) {
                return preferred
            }
            if let first = audio.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
                return first
            }
        }

        // 2. The bundled royalty-free loop.
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        if let files = try? FileManager.default.contentsOfDirectory(
            at: resources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            if let first = files.filter({ audioExtensions.contains($0.pathExtension.lowercased()) })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
                return first
            }
        }
        return nil
    }

    var nowPlaying: String? {
        guard let player, player.isPlaying else { return nil }
        return trackName
    }

    private var trackName: String?

    func start(fadeIn: TimeInterval = 0.4) {
        guard let player else { return }
        if !player.isPlaying {
            // Jump straight to the good bit. A five-second hover that starts at 0:00
            // never reaches the hook.
            player.currentTime = min(startOffset, max(0, player.duration - 1))
            player.play()
        }
        ramp(to: targetVolume, over: fadeIn)
    }

    func stop(fadeOut: TimeInterval = 0.6) {
        guard let player else { return }
        ramp(to: 0, over: fadeOut) { [weak player] in
            player?.pause()
        }
    }

    private func ramp(to target: Float, over seconds: TimeInterval, then: (() -> Void)? = nil) {
        rampTimer?.invalidate()
        guard let player else { then?(); return }

        let steps = max(1, Int(seconds * 60))
        let start = player.volume
        let delta = (target - start) / Float(steps)
        var step = 0

        let t = Timer(timeInterval: seconds / Double(steps), repeats: true) { timer in
            step += 1
            player.volume = start + delta * Float(step)
            if step >= steps {
                player.volume = target
                timer.invalidate()
                then?()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        rampTimer = t
    }
}
