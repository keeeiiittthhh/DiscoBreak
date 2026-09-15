import Foundation

enum MusicMode: String, Codable, CaseIterable {
    case local = "Local file"
    case spotify = "Spotify playlist"
}

protocol MusicSource: AnyObject {
    func start(fadeIn: TimeInterval)
    func stop(fadeOut: TimeInterval)
    var nowPlaying: String? { get }
}
