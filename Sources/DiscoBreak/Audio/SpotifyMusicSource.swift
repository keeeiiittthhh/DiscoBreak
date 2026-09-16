import AppKit
import Foundation

/// Drives Spotify.app over AppleScript.
///
/// Every call runs on a background queue — NSAppleScript blocks its thread, and a
/// blocked main thread would stutter the animation mid-drop.
///
/// Triggers a one-time Automation permission prompt the first time it runs. The
/// app declares `NSAppleEventsUsageDescription`; without that key macOS refuses
/// the events silently, with no prompt ever shown.
final class SpotifyMusicSource {

    private let queue = DispatchQueue(label: "life.keithjoseph.DiscoBreak.spotify")
    private let playlistURI: String?
    private let shuffle: Bool
    private let volume: Int

    private var priorTrack: String?
    private var priorPosition: Double = 0
    private var priorVolume = 90
    private var wasPlaying = false

    private(set) var nowPlaying: String?

    init(playlistURL: String, shuffle: Bool = true, volume: Double = 0.75) {
        self.playlistURI = Self.parsePlaylistURI(from: playlistURL)
        self.shuffle = shuffle
        self.volume = max(0, min(100, Int(volume * 100)))
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

    func start() {
        guard let uri = playlistURI else {
            NSLog("DiscoBreak spotify: no playlist set — running silent")
            return
        }
        queue.async { [weak self] in
            guard let self, Self.wakeQuietly() else { return }
            self.rememberCurrentPlayback()

            // Straight in at full volume. There is no local stinger to hand over
            // from any more, so anything done before the music starts is just more
            // silence — and every one of these lines costs a round trip.
            Self.perform("tell application \"Spotify\" to set sound volume to \(self.volume)")
            if self.shuffle {
                Self.perform("tell application \"Spotify\" to set shuffling to true")
            }

            // `play track` takes a context URI in current Spotify builds. If that
            // ever stops working, handing the URI to Spotify and hitting play does
            // the same job.
            if !Self.perform("tell application \"Spotify\" to play track \"\(uri)\"") {
                NSLog("DiscoBreak spotify: play track refused — handing the link over instead")
                Self.openInSpotify(uri)
                Thread.sleep(forTimeInterval: 0.6)
                Self.perform("tell application \"Spotify\" to play")
            }
            if self.shuffle {
                Self.perform("tell application \"Spotify\" to set shuffling to true")
            }

            self.refreshNowPlaying()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.fadeOut()
            Self.perform("tell application \"Spotify\" to pause")
            self.restorePriorPlayback()
            DispatchQueue.main.async { self.nowPlaying = nil }
        }
    }

    /// Four steps, not forty. Every step is an AppleScript round trip, and a fade
    /// that outlasts the ball's retract is worse than a clean cut.
    private func fadeOut() {
        for i in stride(from: 3, through: 0, by: -1) {
            Self.perform("tell application \"Spotify\" to set sound volume to \(volume * i / 4)")
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - Politeness
    //
    // Never leave someone's music in a state they didn't choose.

    private func rememberCurrentPlayback() {
        priorVolume = Int(Self.run("tell application \"Spotify\" to return sound volume as text") ?? "") ?? volume
        guard let state = Self.run("tell application \"Spotify\" to return player state as text") else { return }
        wasPlaying = state.contains("playing")
        guard wasPlaying else { return }
        priorTrack = Self.run("tell application \"Spotify\" to return spotify url of current track")
        priorPosition = Double(Self.run("tell application \"Spotify\" to return player position as text") ?? "") ?? 0
    }

    private func restorePriorPlayback() {
        // The volume goes back whether or not anything was playing — we changed it
        // either way, and leaving it moved is the rudest thing this app could do.
        Self.perform("tell application \"Spotify\" to set sound volume to \(priorVolume)")
        guard wasPlaying, let track = priorTrack else { return }
        Self.perform("tell application \"Spotify\" to play track \"\(track)\"")
        Self.perform("tell application \"Spotify\" to set player position to \(priorPosition)")
        Self.perform("tell application \"Spotify\" to pause")
        wasPlaying = false
        priorTrack = nil
    }

    private func refreshNowPlaying() {
        let name = Self.run("tell application \"Spotify\" to return name of current track")
        let artist = Self.run("tell application \"Spotify\" to return artist of current track")
        let text = [name, artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        DispatchQueue.main.async { [weak self] in self?.nowPlaying = text.isEmpty ? nil : text }
    }

    // MARK: - Staying out of sight
    //
    // The whole gag is that nothing happens except a ball dropping. A window
    // appearing, or Spotify jumping to the front, breaks it — so every route into
    // Spotify here is a quiet one.

    private static let bundleID = "com.spotify.client"

    /// `tell application "Spotify"` starts Spotify if it isn't running, and a cold
    /// launch puts its window in front: exactly the "something opened" moment this
    /// is meant to avoid. So when it isn't running, start it hidden and wait —
    /// this runs on a background queue, so blocking here costs nothing on screen.
    private static func wakeQuietly() -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            return true
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSLog("DiscoBreak spotify: not installed — running silent")
            return false
        }
        let ready = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: app, configuration: quietly()) { _, _ in
            ready.signal()
        }
        guard ready.wait(timeout: .now() + 8) == .success else { return false }
        // The process exists a beat before it will answer Apple events.
        Thread.sleep(forTimeInterval: 1.2)
        return true
    }

    /// Hands the URI to Spotify itself rather than to whatever app happens to own
    /// the `spotify:` scheme. On a Mac where that is the browser, the default
    /// handler opens the web player, which then takes playback off the desktop app
    /// — the playlist stops rather than starts, in a window nobody asked for.
    private static func openInSpotify(_ uri: String) {
        guard let url = URL(string: uri),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: quietly())
    }

    private static func quietly() -> NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false        // don't come to the front
        config.hides = true             // and don't show a window on first launch
        config.addsToRecentItems = false
        return config
    }

    // MARK: - AppleScript

    /// Value and success are two different questions, and conflating them is what
    /// stopped playlists starting: `play track` succeeds and returns nothing, which
    /// is indistinguishable from a failure if all you look at is the value. Most of
    /// Spotify's commands return nothing.
    private static func execute(_ source: String) -> (ok: Bool, value: String?) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return (false, nil) }
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("DiscoBreak spotify: %@", error.description)
            return (false, nil)
        }
        return (true, result.stringValue)
    }

    /// For commands that answer something.
    private static func run(_ source: String) -> String? { execute(source).value }

    /// For commands that just do something.
    @discardableResult
    private static func perform(_ source: String) -> Bool { execute(source).ok }
}
