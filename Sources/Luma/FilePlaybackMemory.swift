import Foundation

enum RememberedSubtitle<Track: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    case off
    case track(Track)
}

struct EnhancedTrackReference: Codable, Equatable, Sendable {
    var id: String?
    var language: String?
    var title: String?
    var codec: String?
    var externalName: String?
    var localSubtitleURL: URL?

    func matchingID(in tracks: [MPVTrack]) -> String? {
        if let localSubtitleURL {
            guard localSubtitleURL.isFileURL else { return nil }
            return tracks.first { $0.externalURL?.standardizedFileURL == localSubtitleURL.standardizedFileURL }?.id
        }
        if let externalName {
            let matches = tracks.filter { $0.reference.externalName == externalName }
            return matches.count == 1 ? matches[0].id : nil
        }
        let matches = tracks.filter {
            $0.externalURL == nil && $0.reference.language == language
                && $0.reference.title == title && $0.reference.codec == codec
        }
        return matches.count == 1 ? matches[0].id : matches.first { $0.id == id }?.id
    }
}

struct EnhancedPlaybackMemory: Codable, Equatable, Sendable {
    var audio: EnhancedTrackReference?
    var subtitles: RememberedSubtitle<EnhancedTrackReference>?
    var subtitleDelay: Double?
}

struct FilePlaybackMemory: Codable, Equatable, Sendable {
    var nativeAudio: Data?
    var nativeSubtitles: RememberedSubtitle<Data>?
    var enhanced: EnhancedPlaybackMemory?
}
