import Foundation
import Observation

@MainActor @Observable final class OfflineDownloads {
    static let shared = OfflineDownloads()

    struct Item: Identifiable {
        enum State {
            case transferring(Double?)
            case ready(URL)
            case failed(String)
        }
        let id: UUID
        let name: String
        var state: State
    }

    private(set) var items: [Item] = []
    var transferringCount: Int {
        items.lazy.filter { if case .transferring = $0.state { true } else { false } }.count
    }
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeKeys: Set<URL> = []
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Luma/Downloads")) {
        self.directory = directory
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        let restored = folders.compactMap { folder -> (Item, Date)? in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: .skipsHiddenFiles),
                  let file = files.first(where: { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) else { return nil }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (Item(id: id, name: file.lastPathComponent, state: .ready(file)), modified)
        }
        items = restored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func supports(_ url: URL) -> Bool {
        ["http", "https", "smb", "luma-source"].contains(url.scheme?.lowercased() ?? "")
            && !["m3u8", "mpd"].contains(url.pathExtension.lowercased())
    }

    func start(name: String, key: URL, resolve: @escaping @MainActor () async throws -> URL) {
        guard Self.supports(key), activeKeys.insert(key).inserted else { return }
        let filename = key.lastPathComponent.components(separatedBy: CharacterSet(charactersIn: "/\\\0")).joined(separator: "_")
        let id = UUID()
        let folder = directory.appending(component: id.uuidString, directoryHint: .isDirectory)
        let destination = folder.appending(component: filename.isEmpty || filename.hasPrefix(".") ? "网络视频" : filename)
        items.insert(Item(id: id, name: name, state: .transferring(nil)), at: 0)
        tasks[id] = Task {
            defer { tasks[id] = nil; activeKeys.remove(key) }
            do {
                let source = try await resolve()
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let progress = DownloadProgress { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, let index = self.items.firstIndex(where: { $0.id == id }),
                              case .transferring = self.items[index].state else { return }
                        self.items[index].state = .transferring(fraction)
                    }
                }
                try await VideoCopy.save(source, to: destination, delegate: progress)
                setState(.ready(destination), for: id)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                if Task.isCancelled { items.removeAll { $0.id == id } }
                else { setState(.failed(error.localizedDescription), for: id) }
            }
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func remove(_ item: Item) throws {
        if case .ready(let file) = item.state, FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.trashItem(at: file.deletingLastPathComponent(), resultingItemURL: nil)
        }
        items.removeAll { $0.id == item.id }
    }

    private func setState(_ state: Item.State, for id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].state = state }
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    private let update: @Sendable (Double) -> Void

    init(update: @escaping @Sendable (Double) -> Void) { self.update = update }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        update(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }
}
