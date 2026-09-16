import AppKit

/// Owns the overlay window, the renderer and the audio, and runs the state machine:
///
///     idle → dropping → playing → retracting → idle
///
/// Re-entering the notch during `retracting` snaps straight back to `playing`,
/// so a hesitant pointer never restarts the show or pops the audio.
final class ShowController {

    private enum State { case idle, dropping, playing, retracting }

    /// One overlay window per display. The notch screen carries the ball; every
    /// other screen carries the light field only.
    private struct Stage {
        let window: OverlayWindow
        let renderer: DiscoRenderer
        let isPrimary: Bool
    }

    private var settings: Settings
    /// Nil until a playlist is set. With no local fallback left, no playlist
    /// simply means a silent show.
    private var audio: SpotifyMusicSource?

    private var stages: [Stage] = []
    private var state: State = .idle
    private var teardownWork: DispatchWorkItem?

    init(settings: Settings) {
        self.settings = settings
        self.audio = Self.makeAudio(settings)
    }

    private static func makeAudio(_ settings: Settings) -> SpotifyMusicSource? {
        guard !settings.spotifyPlaylist.isEmpty else { return nil }
        return SpotifyMusicSource(playlistURL: settings.spotifyPlaylist,
                                  shuffle: settings.spotifyShuffle,
                                  volume: settings.volume)
    }

    /// Applied live from the settings window. Rebuilding is cheap — a few hundred
    /// layers — so there is no need for per-property plumbing.
    func apply(_ newSettings: Settings) {
        settings = newSettings
        hardReset()
        audio = Self.makeAudio(newSettings)
    }

    var nowPlaying: String? { audio?.nowPlaying }

    // MARK: - Input

    func pointerEnteredNotch() {
        teardownWork?.cancel()
        teardownWork = nil

        switch state {
        case .playing, .dropping:
            return
        case .idle, .retracting:
            ensureStages()
            state = .dropping
            stages.forEach { $0.renderer.drop() }
            audio?.start()
            // The spring is still settling, but the show is live from here on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.state == .dropping else { return }
                self.state = .playing
            }
        }
    }

    func pointerLeftNotch() {
        guard state == .dropping || state == .playing else { return }
        state = .retracting
        audio?.stop()

        // Secondary stages fade on their own clock; the primary one owns the
        // state change, so a two-display setup settles exactly like a one-display one.
        for stage in stages {
            stage.renderer.retract { [weak self] in
                guard stage.isPrimary, let self, self.state == .retracting else { return }
                self.state = .idle
                self.scheduleTeardown()
            }
        }
    }

    // MARK: - Window lifecycle
    //
    // The window is built on first hover and released 60s after the last one, so
    // an idle DiscoBreak costs one 20Hz timer and nothing else.

    private func ensureStages() {
        guard stages.isEmpty else { return }
        guard let notchScreen = NotchDetector.notchScreen() else { return }

        let screens = settings.multiDisplay ? NSScreen.screens : [notchScreen]

        for screen in screens {
            let isPrimary = screen == notchScreen
            let renderer = CARenderer(settings: settings, role: isPrimary ? .full : .lightsOnly)
            let window = OverlayWindow(screen: screen)

            // On the notch screen the light source is the notch. Elsewhere it hangs
            // off the top-centre of that screen, which is where a ceiling ball would be.
            let centreX = isPrimary
                ? NotchDetector.hotZone(for: screen, padding: 0).midX - screen.frame.minX
                : screen.frame.width / 2

            renderer.attach(to: window.hostLayer,
                            screenFrame: CGRect(origin: .zero, size: screen.frame.size),
                            notchCenterX: centreX)
            window.orderFrontRegardless()
            stages.append(Stage(window: window, renderer: renderer, isPrimary: isPrimary))
        }

        // Defensive: something must own the state machine even if no screen matched.
        if !stages.contains(where: { $0.isPrimary }), let first = stages.first {
            stages[0] = Stage(window: first.window, renderer: first.renderer, isPrimary: true)
        }
    }

    private func scheduleTeardown() {
        teardownWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .idle else { return }
            self.teardownStages()
        }
        teardownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private func teardownStages() {
        for stage in stages {
            stage.renderer.detach()
            stage.window.orderOut(nil)
        }
        stages.removeAll()
    }

    /// Used when the machine sleeps or the display configuration changes.
    /// Dropping every stage is what makes plugging in a monitor Just Work: the
    /// next hover rebuilds against the new screen list.
    func hardReset() {
        teardownWork?.cancel()
        audio?.stop()
        teardownStages()
        state = .idle
    }
}
