import Foundation
import Testing
@testable import Luma

@Test @MainActor func incrementalGroupsKeepWatchingStateFresh() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = Library(file: folder.appending(path: "library.json"))
    library.add([URL(filePath: "/tmp/Show.S01E01.mkv"), URL(filePath: "/tmp/Show.S01E02.mkv"), URL(filePath: "/tmp/Other.mp4")])
    let original = try #require(library.groupedItems.first { $0.isTV })
    let first = original.items[0].id; let second = original.items[1].id
    let structure = library.structureRevision
    library.update(second, position: 40, duration: 100)
    let updated = try #require(library.group(containing: second))
    #expect(updated.resume.id == second)
    #expect(updated.resume.position == 40)
    #expect(updated.lastPlayed > original.lastPlayed)
    #expect(updated.searchIndex == original.searchIndex)
    #expect(updated.subtitle == original.subtitle)
    #expect(library.structureRevision == structure)
    library.setWatched([first, second], to: true)
    #expect(library.group(containing: first)?.isWatched == true)
    library.favorite(first)
    #expect(library.group(containing: first)?.hasFavorite == true)
    library.setFavorite([first, second], to: false)
    #expect(library.group(containing: first)?.hasFavorite == false)
    library.reset(second)
    #expect(library.group(containing: second)?.resume.id == second)
    #expect(library.group(containing: second)?.isWatched == false)
    library.remove(second)
    #expect(library.group(containing: second) == nil)
    #expect(library.group(containing: first)?.items.count == 1)
}

@Test @MainActor func queryCacheInvalidatesForEveryRelevantChange() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = Library(file: folder.appending(path: "library.json"))
    let source = UUID()
    library.importSource(source, files: [ScannedFile(url: URL(filePath: "/Volumes/NAS/Cafe.mp4"), relativePath: "Cafe.mp4", localFile: false)])
    library.add([URL(filePath: "/tmp/Show.S01E01.mkv")])
    let filmID = library.items[0].id
    let info = MovieInfo(id: 11, kind: "movie", title: "Espresso", year: "2024", overview: "", poster: nil, originalTitle: "Coffee", rating: 8.1, genres: ["剧情"])
    library.applyMetadata(info, to: filmID)
    let cache = LibraryQueryCache()
    for _ in 0..<2 { #expect(cache.groups(in: library, destination: .all, search: "CAFE").count == 1) }
    #expect(cache.groups(in: library, destination: .all, search: "ESPRESSO").count == 1)
    #expect(cache.groups(in: library, destination: .movies, localOnly: true).isEmpty)
    #expect(cache.groups(in: library, destination: .all, sourceID: source).count == 1)
    #expect(cache.groups(in: library, destination: .genres, genre: "剧情").count == 1)
    #expect(cache.groups(in: library, destination: .genres, genre: "喜剧").isEmpty)
    #expect(cache.groups(in: library, destination: .favorites).isEmpty)
    library.favorite(filmID)
    #expect(cache.groups(in: library, destination: .favorites).first?.representative.id == filmID)
    #expect(cache.groups(in: library, destination: .unwatched).count == 2)
    library.update(filmID, position: 98, duration: 100)
    #expect(cache.groups(in: library, destination: .unwatched).count == 1)
    library.reset(filmID)
    #expect(cache.groups(in: library, destination: .unwatched).count == 2)
    library.applyMetadata(nil, to: filmID)
    #expect(cache.groups(in: library, destination: .all, search: "ESPRESSO").isEmpty)
    let other = Library(file: folder.appending(path: "other.json"))
    #expect(cache.groups(in: other, destination: .all).isEmpty)
}

@Test @MainActor func librarySourceInclusionFiltersMixedGroupsAndPersists() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sourceFile = folder.appending(path: "sources.json")
    let sourceRoot = folder.appending(path: "Shared")
    let sources = SourcesStore(file: sourceFile)
    let source = sources.add(name: "Shared", url: sourceRoot)
    let library = Library(file: folder.appending(path: "library.json"))
    library.importSource(source.id, files: [
        ScannedFile(url: sourceRoot.appending(path: "Show.S01E01.mkv"), relativePath: "Show.S01E01.mkv"),
        ScannedFile(url: sourceRoot.appending(path: "Movie.mkv"), relativePath: "Movie.mkv")
    ])
    let localEpisode = folder.appending(path: "Show.S01E02.mkv")
    library.add([localEpisode])
    let query = LibraryQueryCache()
    let initial = query.groups(in: library, destination: .libraryOverview)
    #expect(initial.count == 2)
    #expect(initial.first(where: \.isTV)?.items.count == 2)

    sources.setLibraryInclusion(false, for: source.id)
    let restored = SourcesStore(file: sourceFile)
    #expect(restored.excludedSourceIDs == [source.id])
    #expect(restored.librarySources.isEmpty)
    let visible = query.groups(in: library, destination: .libraryOverview, excludedSourceIDs: restored.excludedSourceIDs)
    #expect(visible.count == 1)
    #expect(visible.first?.items.map(\.url) == [localEpisode])
    #expect(query.groups(in: library, destination: .all, sourceID: source.id).count == 2)

    restored.setLibraryInclusion(true, for: source.id)
    #expect(SourcesStore(file: sourceFile).excludedSourceIDs.isEmpty)
    #expect(query.groups(in: library, destination: .libraryOverview, excludedSourceIDs: restored.excludedSourceIDs).count == 2)
}

@Test @MainActor func backgroundSaveCoalescesAndFlushesLatestState() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "library.json")
    let library = Library(file: file, backgroundSaving: true)
    library.add([URL(filePath: "/tmp/A.mkv")])
    let id = try #require(library.items.first?.id)
    for position in 1...20 { library.update(id, position: Double(position), duration: 100) }
    #expect(!FileManager.default.fileExists(atPath: file.path))
    await library.flush()
    #expect(library.error == nil)
    let restored = Library(file: file)
    #expect(restored.items.first?.id == id)
    #expect(restored.items.first?.position == 20)
    library.favorite(id)
    // Automatic persistence must work even when the app stays open.
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while Library(file: file).items.first?.favorite != true && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(Library(file: file).items.first?.favorite == true)
    await library.flush()
}

@Test func writerRejectsStaleSnapshots() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "library.json")
    let writer = LibraryWriter(file: file)
    var media = Media(url: URL(filePath: "/tmp/A.mkv"), title: "A")
    media.position = 20
    try await writer.write([media], revision: 2)
    media.position = 10
    try await writer.write([media], revision: 1)
    let restored = try JSONDecoder().decode(SavedLibrary.self, from: Data(contentsOf: file)).restored()
    #expect(restored.first?.position == 20)
}

@Test @MainActor func backgroundMigrationPreservesOriginalAndReadErrors() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "library.json")
    let media = Media(url: URL(filePath: "/tmp/A.mkv"), title: "A")
    let original = try JSONEncoder().encode([media])
    try original.write(to: file)
    let library = Library(file: file, backgroundSaving: true)
    library.update(media.id, position: 50, duration: 100)
    await library.flush()
    #expect(try Data(contentsOf: folder.appending(path: "library-v1-backup.json")) == original)
    #expect(Library(file: file).items.first?.position == 50)
    let corrupt = folder.appending(path: "corrupt.json")
    let invalid = Data("invalid json".utf8); try invalid.write(to: corrupt)
    let broken = Library(file: corrupt, backgroundSaving: true)
    broken.add([URL(filePath: "/tmp/B.mkv")]); await broken.flush()
    #expect(try Data(contentsOf: corrupt) == invalid)
}
