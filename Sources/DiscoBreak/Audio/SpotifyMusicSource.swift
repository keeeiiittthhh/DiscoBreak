import AppKit
import Foundation

/// Drives Spotify.app over AppleScript.
///
/// Every call runs on a background queue — NSAppleScript blocks its thread, and a
/// blocked main thread would stutter the animation mid-drop.
///
/// Triggers a one-time Automation permission prompt the first time it runs, which
/// is why Spotify is opt-in rather than the default.
final class SpotifyMusicSource: MusicSource {

    private let queue = DispatchQueue(label: "life.keithjoseph.DiscoBreak.spotify")
    private let playlistURI: String?
    private let shuffle: Bool

    private var priorTrack: String?
    private var priorPosition: Double = 0
    private var wasPlaying = false

    private(set) var nowPlaying: String?

    init(playlistURL: String, shuffle: Bool = true) {
        self.playlistURI = Self.parsePlaylistURI(from: playlistURL)
        self.shuffle = shuffle
        if playlistURI == nil && !playlistURL.isEmpty {
            NSLog("DiscoBreak: could not parse a playlist id out of %@", playlistURL)
        }
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
    }

    /// Accepts any of:
    ///   https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc
    ///   spotify:playlist:37i9dQZF1DXcBWIGoYBM5M
    ///   37i9dQZF1DXcBWIGoYBM5M
    static func parsePlaylistURI(from raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if s.hasPrefix("spotify:playlist:") { return s }

        if let r = s.range(of: "playlist/") {
            let tail = s[r.upperBound...]
            let id = tail.prefix { $0.isLetter || $0.isNumber }
            if id.count >= 10 { return "spotify:playlist:\(id)" }
        }
        // A bare id.
        if s.count >= 16, s.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return "spotify:playlist:\(s)"
        }
        return nil
    }

    // MARK: - MusicSource

    func start(fadeIn: TimeInterval) {
        guard let uri = playlistURI else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.rememberCurrentPlayback()

            // Ramp from silence so the handover from the local stinger is inaudible.
            _ = Self.run("tell application \"Spotify\" to set sound volume to 0")
            if self.shuffle {
                _ = Self.run("tell application \"Spotify\" to set shuffling to true")
            }

            // `play track` takes a context URI in current Spotify builds. If that
            // ever stops working, opening the URI and hitting play does the same job.
            let played = Self.run("tell application \"Spotify\" to play track \"\(uri)\"")
            if played == nil {
                NSWorkspace.shared.open(URL(string: uri)!)
                Thread.sleep(forTimeInterval: 0.6)
                _ = Self.run("tell application \"Spotify\" to play")
            }
            if self.shuffle {
                _ = Self.run("tell application \"Spotify\" to set shuffling to true")
            }

            self.rampVolume(to: 90, over: fadeIn)
            self.refreshNowPlaying()
        }
    }

    func stop(fadeOut: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.rampVolume(to: 0, over: fadeOut)
            _ = Self.run("tell application \"Spotify\" to pause")
            self.restorePriorPlayback()
            DispatchQueue.main.async { self.nowPlaying = nil }
        }
    }

    // MARK: - Politeness
    //
    // Never leave someone's music in a state they didn't choose.

    private func rememberCurrentPlayback() {
        guard let state = Self.run("tell application \"Spotify\" to return player state as text") else { return }
        wasPlaying = state.contains("playing")
        guard wasPlaying else { return }
        priorTrack = Self.run("tell application \"Spotify\" to return spotify url of current track")
        priorPosition = Double(Self.run("tell application \"Spotify\" to return player position as text") ?? "") ?? 0
    }

    private func restorePriorPlayback() {
        guard wasPlaying, let track = priorTrack else { return }
        _ = Self.run("tell application \"Spotify\" to play track \"\(track)\"")
        _ = Self.run("tell application \"Spotify\" to set player position to \(priorPosition)")
        _ = Self.run("tell application \"Spotify\" to pause")
        _ = Self.run("tell application \"Spotify\" to set sound volume to 90")
        wasPlaying = false
        priorTrack = nil
    }

    private func refreshNowPlaying() {
        let name = Self.run("tell application \"Spotify\" to return name of current track")
        let artist = Self.run("tell application \"Spotify\" to return artist of current track")
        let text = [name, artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        DispatchQueue.main.async { [weak self] in self?.nowPlaying = text.isEmpty ? nil : text }
    }

    /// Spotify's volume is an integer 0-100, so a fade is a short series of steps.
    private func rampVolume(to target: Int, over seconds: TimeInterval) {
        let steps = max(1, Int(seconds / 0.05))
        let current = Int(Self.run("tell application \"Spotify\" to return sound volume as text") ?? "") ?? 0
        for i in 1...steps {
            let v = current + (target - current) * i / steps
            _ = Self.run("tell application \"Spotify\" to set sound volume to \(v)")
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    @discardableResult
    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("DiscoBreak spotify: %@", error.description)
            return nil
        }
        return result.stringValue
    }
}
