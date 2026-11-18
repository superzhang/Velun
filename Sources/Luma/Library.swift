import Foundation
import Observation

struct Media: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var url: URL
    var title: String
    var added = Date()
    var position: Double = 0
    var duration: Double = 0
    var favorite = false
    var watchlisted: Bool?
    var personalRating: Int?
    var playlists: [String]?
    var collectionName: String?
    var matchState: String?
    var matchCheckedAt: Date?
    var watched: Bool?
    var metadata: MovieInfo?
    var sourceID: UUID?
    var localFile: Bool?
    var relativePath: String?
    var remotePath: String?
    var lastPlayed: Date?
    var isLocalFile: Bool { url.isFileURL && (localFile ?? (sourceID == nil)) }
    var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    var isWatched: Bool { watched == true || progress >= 0.95 }
    var isContinuing: Bool { position > 3 && !isWatched }
    var format: String { url.pathExtension.isEmpty ? "STREAM" : url.pathExtension.uppercased() }
    static func streamURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct SavedLibrary: Codable, Sendable {
    let version: Int
    let items: [Media]
    let metadata: [String: MovieInfo]
    let links: [String: String]
    init(items: [Media]) {
        version = 2
        var records: [Media] = []; var catalog: [String: MovieInfo] = [:]; var references: [String: String] = [:]
        for var item in items {
            if let info = item.metadata { let key = "\(info.kind):\(info.id)"; catalog[key] = info; references[item.id.uuidString] = key; item.metadata = nil }
            records.append(item)
        }
        self.items = records; metadata = catalog; links = references
    }
    func restored() throws -> [Media] {
        guard version == 2, links.values.allSatisfy({ metadata[$0] != nil }) else { throw CocoaError(.coderReadCorrupt) }
        return items.map { original in
            var item = original
            if let key = links[item.id.uuidString] { item.metadata = metadata[key] }
            return item
        }
    }
}

@MainActor @Observable final class Library {
    private(set) var items: [Media] = []
    private(set) var revision = 0
    private(set) var structureRevision = 0
    @ObservationIgnored private var groupMembership: [UUID: Int] = [:]
    @ObservationIgnored private var itemIndex: [UUID: Int] = [:]
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private let backgroundSaving: Bool
    @ObservationIgnored private let writer: LibraryWriter
    @ObservationIgnored private var groupCache: [MediaGroup]?
    var groupedItems: [MediaGroup] {
        let snapshot = items
        if let groupCache { return groupCache }
        let groups = MediaGroup.make(snapshot)
        groupCache = groups
        groupMembership = [:]
        for (index, group) in groups.enumerated() { for item in group.items { groupMembership[item.id] = index } }
        return groups
    }
    var error: String?
    private let file: URL
    private var needsMigrationBackup = false
    private var loadFailed = false
    init(file: URL? = nil, backgroundSaving: Bool = false) {
        let path = file ?? URL.applicationSupportDirectory.appending(path: "Luma/library.json")
        self.file = path
        self.backgroundSaving = backgroundSaving
        writer = LibraryWriter(file: path)
        do {
            if FileManager.default.fileExists(atPath: self.file.path) {
                let data = try Data(contentsOf: self.file)
                if let legacy = try? JSONDecoder().decode([Media].self, from: data) { items = legacy; needsMigrationBackup = true }
                else { items = try JSONDecoder().decode(SavedLibrary.self, from: data).restored() }
            }
        } catch { loadFailed = true; self.error = "媒体库读取失败，原文件已保留：\(error.localizedDescription)" }
        rebuildItemIndex()
    }
    private func rebuildItemIndex() { itemIndex = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) }) }
    private func refreshGroup(for id: UUID) {
        guard let index = groupMembership[id], let previous = groupCache?[index] else { return }
        let updated = previous.items.compactMap { itemIndex[$0.id].map { items[$0] } }
        groupCache?[index] = MediaGroup(id: previous.id, items: updated, template: previous)
    }
    func group(containing id: UUID) -> MediaGroup? {
        _ = groupedItems
        return groupMembership[id].map { groupCache![$0] }
    }
    private func refreshGroups(for ids: Set<UUID>) {
        let indices = Set(ids.compactMap { groupMembership[$0] })
        for index in indices { if let id = groupCache?[index].representative.id { refreshGroup(for: id) } }
    }
    var playlistNames: [String] { Array(Set(items.flatMap { $0.playlists ?? [] })).sorted() }
    var collectionNames: [String] { Array(Set(items.compactMap(\.collectionName))).sorted() }
    func setWatchlist(_ ids: [UUID], value: Bool) {
        let selected = Set(ids)
        for i in items.indices where selected.contains(items[i].id) { items[i].watchlisted = value; if value { items[i].lastPlayed = Date() } }
        refreshGroups(for: selected); save(invalidateGroups: false)
    }
    func setDetailInfo(_ ids: [UUID], rating: Int? = nil, collection: String? = nil) {
        let selected = Set(ids)
        for i in items.indices where selected.contains(items[i].id) {
            if let rating { items[i].personalRating = (1...10).contains(rating) ? rating : nil }
            if let collection { let name = collection.trimmingCharacters(in: .whitespacesAndNewlines); items[i].collectionName = name.isEmpty ? nil : name }
        }
        refreshGroups(for: selected); save(invalidateGroups: false)
    }
    func setPlaylist(_ ids: [UUID], name: String, included: Bool) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }
        let selected = Set(ids)
        for i in items.indices where selected.contains(items[i].id) {
            var names = Set(items[i].playlists ?? [])
            if included { names.insert(name) } else { names.remove(name) }
            items[i].playlists = names.sorted()
        }
        refreshGroups(for: selected); save(invalidateGroups: false)
    }
    func add(_ urls: [URL]) {
        var existing = Set(items.map(\.url))
        for url in urls where existing.insert(url).inserted {
            items.append(Media(url: url, title: url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")))
        }
        rebuildItemIndex(); structureRevision += 1
        save()
    }
    func applyMetadata(_ metadata: MovieInfo?, to id: UUID) { applyMetadata(metadata, to: [id]) }
    func applyMetadata(_ metadata: MovieInfo?, to ids: [UUID]) {
        let selected = Set(ids)
        for i in items.indices where selected.contains(items[i].id) { items[i].metadata = metadata; items[i].matchState = metadata == nil ? nil : "matched"; items[i].matchCheckedAt = metadata == nil ? nil : Date() }
        save()
    }
    func applyMatchBatch(_ results: [MatchOutcome]) {
        var byID: [UUID: MatchOutcome] = [:]
        for result in results { for id in result.ids { byID[id] = result } }
        for i in items.indices {
            guard let result = byID[items[i].id], items[i].metadata == nil else { continue }
            items[i].metadata = result.info
            items[i].matchState = result.info == nil ? "needs-review" : "matched"
            items[i].matchCheckedAt = Date()
        }
        save()
    }
    func updateSourceLocality(_ locality: [UUID: Bool]) {
        var changed = false
        for i in items.indices {
            guard let id = items[i].sourceID, let local = locality[id], items[i].localFile != local else { continue }
            items[i].localFile = local; changed = true
        }
        if changed { save() }
    }
    func importSource(_ source: UUID, files: [ScannedFile]) {
        let fallbackLocal = files.first(where: { $0.url.isFileURL && $0.localFile == nil }).map { SourceWorker.localVolume($0.url) } ?? false
        var byPath: [String: Int] = [:]
        var byURL: [URL: Int] = [:]
        for (i, item) in items.enumerated() {
            byURL[item.url] = i
            if item.sourceID == source, let relative = item.relativePath { byPath[relative] = i }
        }
        for file in files {
            if let i = byPath[file.relativePath] ?? byURL[file.url] {
                items[i].url = file.url; items[i].sourceID = source; items[i].relativePath = file.relativePath; items[i].remotePath = file.remotePath; items[i].localFile = file.localFile ?? fallbackLocal
            } else {
                var item = Media(url: file.url, title: file.url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".", with: " "))
                item.sourceID = source; item.relativePath = file.relativePath; item.remotePath = file.remotePath; item.localFile = file.localFile ?? fallbackLocal
                if let title = file.displayTitle { item.title = title }
                byPath[file.relativePath] = items.count; byURL[file.url] = items.count; items.append(item)
            }
        }
        rebuildItemIndex(); structureRevision += 1
        save()
    }
    func setWatched(_ ids: [UUID], to value: Bool) {
        let selected = Set(ids)
        for i in items.indices where selected.contains(items[i].id) {
            items[i].watched = value
            if !value { items[i].position = 0 }
        }
        refreshGroups(for: selected); save(invalidateGroups: false)
    }
    func update(_ id: UUID, position: Double, duration: Double) {
        guard let index = itemIndex[id], position.isFinite, duration.isFinite else { return }
        items[index].position = max(0, position)
        if duration > 0 && position / duration < 0.95 { items[index].watched = false }
        items[index].duration = max(0, duration)
        items[index].lastPlayed = Date()
        refreshGroup(for: id)
        save(invalidateGroups: false)
    }
    func setFavorite(_ ids: [UUID], to value: Bool) {
        let selected = Set(ids)
        for i in items.indices where selected.contains(items[i].id) { items[i].favorite = value }
        refreshGroups(for: selected); save(invalidateGroups: false)
    }
    func favorite(_ id: UUID) {
        guard let i = itemIndex[id] else { return }
        items[i].favorite.toggle(); refreshGroup(for: id); save(invalidateGroups: false)
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; rebuildItemIndex(); structureRevision += 1; save() }
    func reset(_ id: UUID) {
        guard let i = itemIndex[id] else { return }
        items[i].position = 0; items[i].watched = false; items[i].lastPlayed = nil; refreshGroup(for: id); save(invalidateGroups: false)
    }
    private func save(invalidateGroups: Bool = true) {
        revision += 1
        if invalidateGroups { groupCache = nil; groupMembership = [:] }
        // Never overwrite an unreadable library implicitly.
        guard !loadFailed else { return }
        if backgroundSaving {
            // Coalesce bursts without postponing writes indefinitely during matching.
            guard pendingSave == nil else { return }
            pendingSave = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
                guard let self else { return }
                self.pendingSave = nil
                await self.persistLatest()
            }
        } else {
            do { try LibraryFile.write(items, to: file, migrationBackup: needsMigrationBackup); needsMigrationBackup = false; error = nil }
            catch { self.error = "保存失败：\(error.localizedDescription)" }
        }
    }
    private func persistLatest() async {
        guard !loadFailed else { return }
        let snapshot = items; let version = revision; let migration = needsMigrationBackup
        do {
            try await writer.write(snapshot, revision: version, migrationBackup: migration)
            needsMigrationBackup = false
            if version == revision { error = nil }
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
    func flush() async {
        pendingSave?.cancel(); pendingSave = nil
        guard backgroundSaving else { return }
        // Include changes received while an earlier snapshot was being written.
        var savedRevision: Int
        repeat {
            savedRevision = revision
            await persistLatest()
        } while savedRevision != revision && error == nil
    }
}

// Encoding, metadata normalization and atomic disk replacement run on this actor,
// never on the UI actor in the application. Revisions reject stale snapshots.
actor LibraryWriter {
    private let file: URL
    private var savedRevision = -1
    init(file: URL) { self.file = file }
    func write(_ items: [Media], revision: Int, migrationBackup: Bool = false) throws {
        guard revision > savedRevision else { return }
        try LibraryFile.write(items, to: file, migrationBackup: migrationBackup)
        savedRevision = revision
    }
}

private enum LibraryFile {
    static func write(_ items: [Media], to file: URL, migrationBackup: Bool) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if migrationBackup {
            let backup = file.deletingLastPathComponent().appending(path: "library-v1-backup.json")
            if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: file, to: backup) }
        }
        try JSONEncoder().encode(SavedLibrary(items: items)).write(to: file, options: .atomic)
    }
}
