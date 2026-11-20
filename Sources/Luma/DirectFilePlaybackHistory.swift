import Foundation

@MainActor final class DirectFilePlaybackHistory {
    private struct Entry: Codable, Equatable {
        let position: Double
        let duration: Double
        let watched: Bool
    }

    private let file: URL
    private var entries: [URL: Entry] = [:]
    private var writable = true
    private var dirty = false

    init(file: URL = URL.applicationSupportDirectory.appending(path: "Luma/direct-file-history.json")) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            entries = try JSONDecoder().decode([URL: Entry].self, from: Data(contentsOf: file))
        } catch {
            writable = false
        }
    }

    func mediaRestoringProgress(_ media: Media) -> Media {
        guard let url = media.directPlaybackURL, let entry = entries[url] else { return media }
        var restored = media
        restored.position = entry.position
        restored.duration = entry.duration
        restored.watched = entry.watched
        return restored
    }

    func record(_ url: URL, position: Double, duration: Double, watched: Bool = false) {
        guard position.isFinite, duration.isFinite else { return }
        let entry = Entry(position: max(0, position), duration: max(0, duration), watched: watched)
        guard entries[url] != entry else { return }
        entries[url] = entry
        dirty = true
    }

    func finish(_ url: URL) {
        let entry = entries[url]
        record(url, position: entry?.position ?? 0, duration: entry?.duration ?? 0, watched: true)
    }

    func flush() {
        guard dirty, writable else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
            dirty = false
        } catch {
            // Keep the latest progress in memory so another close can retry the write.
        }
    }
}
