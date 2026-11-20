import Foundation
import Testing
@testable import Luma

@Test @MainActor func performerWorksMatchPersonAndTitleIDsWithinVisibleLibrary() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = Library(file: folder.appending(component: "library.json"))
    let localURLs = ["Featured.mkv", "Series.S01E01.mkv", "Series.S01E02.mkv", "Namesake.mkv"].map { folder.appending(component: $0) }
    library.add(localURLs)
    let remote = UUID()
    let retired = UUID()
    for (source, name) in [(remote, "Remote.mkv"), (retired, "Retired.mkv")] {
        library.importSource(source, files: [
            ScannedFile(url: RemoteSources.virtualURL(source: source, path: name), relativePath: name)
        ])
    }
    let performer = CastMember(id: 7, name: "Alex", character: "", photo: nil)
    let namesake = CastMember(id: 8, name: performer.name, character: "", photo: nil)
    func apply(title: String, kind: String, id: Int, cast: [CastMember]? = nil, to items: [Media]) {
        library.applyMetadata(MovieInfo(id: id, kind: kind, title: title, year: "2026", overview: "", poster: nil, cast: cast), to: items.map(\.id))
    }
    apply(title: "Featured", kind: "movie", id: 1, cast: [performer], to: library.items.filter { $0.url == localURLs[0] })
    apply(title: "Series", kind: "tv", id: 2, to: library.items.filter { localURLs[1...2].contains($0.url) })
    apply(title: "Namesake", kind: "movie", id: 2, cast: [namesake], to: library.items.filter { $0.url == localURLs[3] })
    apply(title: "Remote", kind: "movie", id: 3, to: library.items.filter { $0.sourceID == remote })
    apply(title: "Retired", kind: "movie", id: 4, to: library.items.filter { $0.sourceID == retired })

    let client = TMDBClient { request in
        #expect(request.url?.path == "/3/person/7/combined_credits")
        let data = Data(#"{"cast":[{"id":2,"media_type":"tv"},{"id":2,"media_type":"tv"},{"id":3,"media_type":"movie"},{"id":4,"media_type":"movie"},{"id":5,"media_type":"movie"}],"crew":[{"id":2,"media_type":"movie"}]}"#.utf8)
        return (data, 200)
    }
    let credits = try await client.castCredits(personID: performer.id, token: "fixture")
    let destination = Destination.performer(performer.id, performer.name)
    let query = LibraryQueryCache()
    #expect(query.groups(in: library, destination: destination, excludedSourceIDs: [retired]).map(\.title) == ["Featured"])
    let works = query.groups(in: library, destination: destination, sort: "name", excludedSourceIDs: [retired], castCredits: credits)
    #expect(works.map(\.title) == ["Featured", "Remote", "Series"])
    #expect(works.last?.episodes.count == 2)
    #expect(query.groups(in: library, destination: destination, localOnly: true, sort: "name", excludedSourceIDs: [retired], castCredits: credits).map(\.title) == ["Featured", "Series"])
}

@Test @MainActor func numberedEpisodesShareOneCardAndKeepAvailableVersions() throws {
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = SourcesStore(file: folder.appending(component: "sources.json"))
    let source = sources.add(name: "Current", url: folder.appending(component: "Current"))
    let oldSource = UUID()
    let library = Library(file: folder.appending(component: "library.json"))
    let names = ["Show.S01E10.1080p.mkv", "Show.S01E10.2160p.mkv", "Show.S01E11.mkv", "Show.S02E10.mkv"]
    library.importSource(source.id, files: names.map {
        ScannedFile(url: source.url.appending(component: $0), relativePath: $0)
    })
    library.importSource(oldSource, files: [
        ScannedFile(url: RemoteSources.virtualURL(source: oldSource, path: names[0]), relativePath: names[0])
    ])
    let info = MovieInfo(id: 100, kind: "tv", title: "Show", year: "2026", overview: "", poster: nil)
    library.applyMetadata(info, to: library.items.map(\.id))
    let active = library.items.filter { $0.sourceID == source.id }
    let original = try #require(active.first { $0.sourcePath == names[0] })
    let alternate = try #require(active.first { $0.sourcePath == names[1] })
    library.update(alternate.id, position: 30, duration: 120)
    let removed = sources.removedSourceIDs(in: library.referencedSourceIDs)
    #expect(removed == [oldSource])
    let visible = LibraryQueryCache().groups(in: library, destination: .shows, excludedSourceIDs: removed)
    let show = try #require(visible.first)
    #expect(show.subtitle == "2 季 · 3 集")
    let tenth = try #require(show.episodes.first)
    #expect(tenth.files.count == 2)
    #expect(tenth.preferredFile().id == alternate.id)
    #expect(tenth.preferredFile(favoring: original.id).id == original.id)
    #expect(show.playbackItems(favoring: alternate.id).map(\.sourcePath) == Array(names.dropFirst()))

    let playback = Playback(library: library, sources: sources)
    playback.media = alternate
    #expect(playback.selectableEpisodes.map { EpisodeCode($0).episode } == [10, 11, 10])
    #expect(playback.nextEpisode?.sourcePath == names[2])
    #expect(library.items.count == 5)

    library.setEpisodeWatched(original.id, to: true)
    let watchedShow = try #require(library.group(containing: original.id))
    #expect(watchedShow.episodes.first?.files.allSatisfy(\.isWatched) == true)
    #expect(watchedShow.resume.sourcePath == names[2])
    library.setEpisodeWatched(alternate.id, to: false)
    #expect(library.group(containing: original.id)?.episodes.first?.isWatched == false)
    #expect(library.group(containing: original.id)?.episodes.first?.files.allSatisfy { $0.position == 0 } == true)
}

@Test @MainActor func retiredPlaybackHistoryRecoversOnlyUnambiguousUntouchedFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(component: "library.json")
    let library = Library(file: file)
    let retired = UUID()
    let current = UUID()
    let other = UUID()
    let names = ["resume.mkv", "watched.mkv", "overridden.mkv", "ambiguous.mkv"]
    func files(_ source: UUID, _ paths: [String]) -> [ScannedFile] {
        paths.map { ScannedFile(url: RemoteSources.virtualURL(source: source, path: $0), relativePath: $0) }
    }
    library.importSource(retired, files: files(retired, names))
    library.importSource(current, files: files(current, names))
    library.importSource(other, files: files(other, [names[3]]))
    let info = MovieInfo(id: 11, kind: "movie", title: "Fixture", year: "2025", overview: "", poster: nil)
    library.applyMetadata(info, to: library.items.map(\.id))
    let old = library.items.filter { $0.sourceID == retired }
    let active = library.items.filter { $0.sourceID == current }
    library.update(old[0].id, position: 80, duration: 160)
    library.setWatched([old[1].id, old[2].id, old[3].id], to: true)
    library.setWatched([active[2].id], to: false)
    library.recoverRetiredPlaybackHistory(from: [retired])

    let saved = Library(file: file)
    let restored = saved.items.filter { $0.sourceID == current }
    #expect(restored[0].position == 80)
    #expect(restored[1].isWatched)
    #expect(!restored[2].isWatched)
    #expect(!restored[3].isWatched)
    #expect(saved.items.count == 9)
    saved.reset(restored[0].id)
    saved.recoverRetiredPlaybackHistory(from: [retired])
    #expect(saved.items.first { $0.id == restored[0].id }?.position == 0)
}

@Test @MainActor func directSMBPlaybackRestoresAfterBridgeAddressChanges() throws {
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(component: "direct-history.json")
    let smb = try #require(URL(string: "smb://NAS.local:445/Share/Fixture.mkv"))
    let sameSMB = try #require(URL(string: "smb://nas.local/Share/Fixture.mkv"))
    let key = SMBClient.playbackHistoryURL(smb)
    #expect(key == SMBClient.playbackHistoryURL(sameSMB))
    let history = DirectFilePlaybackHistory(file: file)
    history.record(key, position: 48, duration: 160)
    history.flush()
    let reloaded = DirectFilePlaybackHistory(file: file)
    let bridge = try #require(URL(string: "http://127.0.0.1:20500/Fixture.mkv"))
    let media = Media(url: bridge, title: "Fixture", directPlaybackURL: SMBClient.playbackHistoryURL(sameSMB))
    let library = Library(file: folder.appending(component: "library.json"))
    let playback = Playback(library: library, directHistory: reloaded)
    defer { playback.close() }
    playback.open(media)
    #expect(playback.media?.position == 48)
    #expect(playback.media?.url == bridge)
    #expect(library.items.isEmpty)
    playback.finished()
    #expect(DirectFilePlaybackHistory(file: file).mediaRestoringProgress(media).isWatched)
}

@Test func unnumberedEpisodesRemainSeparate() {
    let files = ["Special A.mkv", "Special B.mkv"].map { Media(url: URL(filePath: "/tmp/\($0)"), title: $0) }
    #expect(EpisodeSlot.make(files).map { $0.preferredFile().id } == files.map(\.id))
}

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

    let unindexed = Media(url: folder.appending(component: "Unindexed.mkv"), title: "Unindexed")
    playback.playQueue([library.items[0], unindexed], shuffled: false, loop: false)
    #expect(playback.nextEpisode == unindexed)
    playback.open(unindexed)
    #expect(playback.previousEpisode?.id == library.items[0].id)
    #expect(playback.nextEpisode == nil)
    #expect(!library.items.contains { $0.id == unindexed.id })
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
