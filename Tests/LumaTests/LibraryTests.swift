import Foundation
import Testing
@testable import Luma

@Test func validatesStreamAddresses() {
    #expect(Media.streamURL(" https://example.com/movie.mp4 ") != nil)
    #expect(Media.streamURL("http://localhost:8080/live.m3u8") != nil)
    for value in ["file:///tmp/a.mp4", "https://", "hello", "ftp://host/a", "https://user:secret@example.com/a"] {
        #expect(Media.streamURL(value) == nil)
    }
}
@Test @MainActor func persistsLibraryAndProgress() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "library.json")
    let library = Library(file: file)
    let url = URL(filePath: "/tmp/Film.mp4")
    library.add([url, url])
    #expect(library.items.count == 1)
    let id = try #require(library.items.first?.id)
    library.update(id, position: 30, duration: 100)
    library.favorite(id)
    let restored = Library(file: file)
    #expect(restored.items.first?.isContinuing == true)
    #expect(restored.items.first?.favorite == true)
    #expect(restored.items.first?.progress == 0.3)
    restored.update(id, position: .nan, duration: 100)
    #expect(restored.items.first?.position == 30)
    restored.reset(id)
    #expect(restored.items.first?.isContinuing == false)
    restored.remove(id)
    #expect(Library(file: file).items.isEmpty)
}
@Test @MainActor func protectsCorruptLibrary() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let original = Data("invalid json".utf8)
    try original.write(to: file)
    let library = Library(file: file)
    #expect(library.error != nil)
    library.add([URL(filePath: "/tmp/a.mp4")])
    #expect(try Data(contentsOf: file) == original)
}

@Test @MainActor func relinksMovedFileAndKeepsIdentityAndPersonalState() throws {
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let database = folder.appending(component: "library.json")
    let source = UUID()
    let library = Library(file: database)
    let original = ScannedFile(url: RemoteSources.virtualURL(source: source, path: "旧位置/影片.mkv"), relativePath: "旧位置/影片.mkv")
    let poster = RemoteSources.virtualURL(source: source, path: "新位置/poster.jpg")
    let moved = ScannedFile(url: RemoteSources.virtualURL(source: source, path: "新位置/影片.mkv"), relativePath: "新位置/影片.mkv", sidecars: MediaSidecars(poster: poster))
    library.importSource(source, files: [original], complete: true)
    let originalID = try #require(library.items.first?.id)
    library.update(originalID, position: 45, duration: 120)
    library.setFavorite([originalID], to: true)
    library.setPlaylist([originalID], name: "周末", included: true)
    library.setDetailInfo([originalID], rating: 8, collection: "电影系列")
    library.importSource(source, files: [moved], complete: true)
    let lost = try #require(library.items.first { $0.id == originalID })
    let replacement = try #require(library.replacements(for: lost).first)
    try library.relinkMissing(originalID, to: replacement.id)
    let restored = Library(file: database)
    restored.importSource(source, files: [moved], complete: true)

    let item = try #require(restored.items.first)
    #expect(restored.items.count == 1)
    #expect(item.id == originalID)
    #expect(item.url == moved.url)
    #expect(item.relativePath == moved.relativePath)
    #expect(item.sidecars?.poster == poster)
    #expect(item.sourceMissing == nil)
    #expect(item.position == 45)
    #expect(item.favorite)
    #expect(item.playlists == ["周末"])
    #expect(item.personalRating == 8)
    #expect(item.collectionName == "电影系列")
}

@Test @MainActor func missingFileChangesIgnoreRestoredRecordsAndProtectReplacementHistory() throws {
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = UUID()
    let library = Library(file: folder.appending(component: "library.json"))
    let old = ScannedFile(url: folder.appending(component: "Old.mkv"), relativePath: "Old.mkv")
    let existing = ScannedFile(url: folder.appending(component: "New.mkv"), relativePath: "New.mkv")
    library.importSource(source, files: [old, existing], complete: true)
    let oldID = try #require(library.items.first { $0.url == old.url }?.id)
    let existingID = try #require(library.items.first { $0.url == existing.url }?.id)
    library.importSource(source, files: [existing], complete: true)
    let missing = try #require(library.items.first { $0.id == oldID })
    #expect(library.replacements(for: missing).map(\.id) == [existingID])

    library.update(existingID, position: 25, duration: 60)
    #expect(library.replacements(for: missing).isEmpty)
    #expect(throws: (any Error).self) { try library.relinkMissing(oldID, to: existingID) }
    #expect(library.items.first { $0.id == existingID }?.position == 25)

    library.importSource(source, files: [old, existing], complete: true)
    #expect(library.removeMissing([oldID]) == 0)
    #expect(library.items.count == 2)
    library.importSource(source, files: [existing], complete: true)
    #expect(library.removeMissing([oldID, existingID]) == 1)
    #expect(library.items.map(\.id) == [existingID])
}
