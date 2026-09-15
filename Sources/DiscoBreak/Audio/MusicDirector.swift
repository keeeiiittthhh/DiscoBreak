import Foundation

/// Chooses the music source and hides Spotify's latency.
///
/// AppleScript round-trips take 200-600ms and vary run to run. On a five-second gag
/// that is fatal — the ball drops in silence and the music arrives late, differently
/// every time.
///
/// The fix is perceptual: the local track starts instantly (0ms) as a stinger while
/// the Spotify call is still in flight, then fades out as Spotify comes up underneath
/// it. The seam is inaudible no matter how slow the round trip happens to be.
final class MusicDirector {

    private let settings: Settings
    private let local: LocalMusicSource
    private var spotify: SpotifyMusicSource?
    private var handoff: DispatchWorkItem?

    init(settings: Settings) {
        self.settings = settings
        self.local = LocalMusicSource(settings: settings)
        if settings.musicMode == .spotify, !settings.spotifyPlaylist.isEmpty {
            spotify = SpotifyMusicSource(playlistURL: settings.spotifyPlaylist,
                                         shuffle: settings.spotifyShuffle)
        }
    }

    var nowPlaying: String? { spotify?.nowPlaying ?? local.nowPlaying }

    func start() {
        handoff?.cancel()

        guard let spotify else {
            local.start(fadeIn: 0.4)
            return
        }

        // Both at once: local covers the gap, Spotify takes over.
        local.start(fadeIn: 0.05)
        spotify.start(fadeIn: settings.spotifyHandoffSeconds)

        let work = DispatchWorkItem { [weak self] in
            self?.local.stop(fadeOut: 0.8)
        }
        handoff = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.spotifyHandoffSeconds, execute: work)
    }

    func stop() {
        handoff?.cancel()
        handoff = nil
        local.stop(fadeOut: 0.6)
        spotify?.stop(fadeOut: 0.5)
    }
}
