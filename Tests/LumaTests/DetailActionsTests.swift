import Foundation
import Testing
@testable import Luma

@Test func browsingLocalFilesShowsEmptyFoldersAndVideos() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appending(component: "空文件夹"), withIntermediateDirectories: true)
    try Data().write(to: root.appending(component: "电影.mp4"))
    try Data().write(to: root.appending(component: "说明.txt"))
    let entries = try await SavedSourceFileBrowser.localEntries(root)
    #expect(entries.map(\.name) == ["空文件夹", "电影.mp4"])
    #expect(entries.map(\.isDirectory) == [true, false])
}

@Test @MainActor func detailListsRatingAndWatchlistPersist() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "library.json")
    let library = Library(file: file)
    library.add([URL(filePath: "/tmp/Series.S01E01.mkv"), URL(filePath: "/tmp/Series.S01E02.mkv")])
    let ids = library.items.map(\.id)
    library.setWatchlist([ids[1]], value: true)
    #expect(library.group(containing: ids[0])?.resume.id == ids[1])
    library.setDetailInfo(ids, rating: 8, collection: " Weekend ")
    library.setPlaylist([ids[1]], name: " Queue ", included: true)
    let query = LibraryQueryCache()
    let playlist = query.groups(in: library, destination: .playlist("Queue"))
    #expect(playlist.count == 1)
    #expect(playlist.first?.items.map(\.id) == [ids[1]])
    let restored = Library(file: file)
    #expect(restored.items[1].watchlisted == true)
    #expect(restored.items[0].personalRating == 8)
    #expect(restored.collectionNames == ["Weekend"])
    #expect(restored.playlistNames == ["Queue"])
    restored.setPlaylist(ids, name: "Queue", included: false)
    restored.setDetailInfo(ids, rating: 0, collection: "")
    #expect(restored.playlistNames.isEmpty)
    #expect(restored.items[0].personalRating == nil)
    #expect(restored.collectionNames.isEmpty)
}

@Test @MainActor func detailQueueLoopsAndClearsOnExit() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let suite = "Luma.Queue.Tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
    let library = Library(file: folder.appending(path: "library.json"))
    library.add([URL(filePath: "/tmp/One.mkv"), URL(filePath: "/tmp/Two.mkv")])
    let playback = Playback(library: library, preferences: PlaybackPreferences(defaults: defaults))
    defer { playback.close() }
    playback.playQueue(library.items, shuffled: false, loop: true)
    #expect(playback.media?.id == library.items[0].id)
    #expect(playback.nextEpisode?.id == library.items[1].id)
    #expect(playback.previousEpisode?.id == library.items[1].id)
    playback.open(library.items[1])
    #expect(playback.nextEpisode?.id == library.items[0].id)
    #expect(playback.previousEpisode?.id == library.items[0].id)
    playback.close()
    #expect(playback.nextEpisode == nil)
    #expect(playback.previousEpisode == nil)
}

@Test func downloadingLocalCopyPreservesOriginal() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appending(path: "source.mkv"), destination = folder.appending(path: "copy.mkv")
    let bytes = Data("video fixture".utf8); try bytes.write(to: original)
    try await VideoCopy.save(original, to: destination)
    #expect(try Data(contentsOf: destination) == bytes)
    #expect(try Data(contentsOf: original) == bytes)
    try Data("old copy".utf8).write(to: destination)
    try await VideoCopy.save(original, to: destination)
    #expect(try Data(contentsOf: destination) == bytes)
}
