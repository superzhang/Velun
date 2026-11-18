import Foundation
import Testing
@testable import Luma

@Test func parseReleaseNames() {
    let movie = MediaName("Dune.Part.Two.2024.2160p.WEB-DL.H265")
    #expect(movie.title == "Dune Part Two")
    #expect(movie.year == "2024")
    #expect(!movie.isTV)
    let tv = MediaName("Breaking.Bad.S01E02.1080p.BluRay")
    #expect(tv.title == "Breaking Bad")
    #expect(tv.isTV)
    #expect(MediaName("庆余年.第2季.1080p").title == "庆余年")
}
@Test func validateSMBSources() {
    #expect(LibrarySource.smbURL("smb://nas.local/Movies/电影") != nil)
    #expect(LibrarySource.smbURL("smb://192.168.1.2/share") != nil)
    for input in ["smb://nas.local", "smb://user:password@nas.local/share", "https://nas/share", "smb://nas/share/../private", "smb://nas/share?password=secret"] {
        #expect(LibrarySource.smbURL(input) == nil)
    }
}
@Test func scanNestedLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let nested = root.appending(path: "Series/Season 1")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for filename in ["Episode.S01E01.mkv", "readme.txt", ".hidden.mp4"] { try Data().write(to: nested.appending(path: filename)) }
    try FileManager.default.createSymbolicLink(at: nested.appending(path: "link.mp4"), withDestinationURL: nested.appending(path: "Episode.S01E01.mkv"))
    let scanned = try await SourceWorker.scan(root)
    #expect(scanned.files.count == 1)
    #expect(scanned.files.first?.relativePath == "Series/Season 1/Episode.S01E01.mkv")
}
@Test @MainActor func sourceRescanPreservesIdentity() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = Library(file: folder.appending(path: "library.json"))
    let source = UUID()
    library.importSource(source, files: [ScannedFile(url: URL(filePath: "/Volumes/Movies/A.mp4"), relativePath: "A.mp4")])
    let id = try #require(library.items.first?.id)
    library.update(id, position: 50, duration: 100)
    let info = MovieInfo(id: 1, kind: "movie", title: "测试电影", year: "2024", overview: "测试简介", poster: nil)
    library.applyMetadata(info, to: id)
    library.importSource(source, files: [ScannedFile(url: URL(filePath: "/Volumes/Movies-1/A.mp4"), relativePath: "A.mp4")])
    #expect(library.items.count == 1)
    #expect(library.items.first?.id == id)
    #expect(library.items.first?.position == 50)
    #expect(library.items.first?.metadata == info)
    #expect(library.items.first?.url.path == "/Volumes/Movies-1/A.mp4")
    #expect(Library(file: folder.appending(path: "library.json")).items.first?.metadata == info)
}
@Test func legacyLibraryDecodes() throws {
    let old = #"[{"id":"E496E75F-E6B9-468B-B0D7-EE03C0FC471B","url":"file:///tmp/A.mp4","title":"A","added":0,"position":5,"duration":100,"favorite":false}]"#
    let items = try JSONDecoder().decode([Media].self, from: Data(old.utf8))
    #expect(items.first?.position == 5)
    #expect(items.first?.metadata == nil)
}
@Test func tmdbSearchRequestAndResponse() async throws {
    let client = TMDBClient { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.url?.host == "api.themoviedb.org")
        if request.url?.path == "/3/configuration" {
            return (Data(#"{"images":{"secure_base_url":"https://image.tmdb.org/t/p/","poster_sizes":["w500","original"]}}"#.utf8), 200)
        }
        #expect(request.url?.path == "/3/search/tv")
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.contains(URLQueryItem(name: "query", value: "庆余年")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "first_air_date_year", value: "2019")) == true)
        return (Data(#"{"results":[{"id":123,"name":"庆余年","first_air_date":"2019-11-26","overview":"简介","poster_path":"/poster.jpg"}]}"#.utf8), 200)
    }
    let results = try await client.search(title: "庆余年", year: "2019", isTV: true, token: "test-token")
    #expect(results.first?.title == "庆余年")
    #expect(results.first?.poster?.absoluteString == "https://image.tmdb.org/t/p/w500/poster.jpg")
}
@Test func tmdbRejectsAuthenticationAndRateLimits() async {
    for status in [401, 429] {
        let client = TMDBClient { _ in (Data(), status) }
        do { _ = try await client.search(title: "Film", year: nil, isTV: false, token: "test"); Issue.record("Expected request to fail") }
        catch { #expect(error.localizedDescription.contains(status == 401 ? "令牌" : "频繁")) }
    }
}

@Test func automaticMatchingRejectsAmbiguity() {
    let film = MovieInfo(id: 1, kind: "movie", title: "沙丘2", year: "2024", overview: "", poster: nil, originalTitle: "Dune Part Two")
    let wrong = MovieInfo(id: 2, kind: "movie", title: "Other", year: "2024", overview: "", poster: nil)
    let name = MediaName("Dune.Part.Two.2024.1080p")
    #expect(MovieInfo.automaticMatch([wrong, film], name: name)?.id == 1)
    #expect(MovieInfo.automaticMatch([film, film], name: name) == nil)
    #expect(MovieInfo.automaticMatch([wrong], name: name) == nil)
    #expect(MovieInfo.automaticMatch([film], name: MediaName("Dune.Part.Two.2023")) == nil)
}

@Test @MainActor func groupsEpisodesAndAppliesMetadataInBatch() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "library.json")
    let library = Library(file: file)
    library.add([URL(filePath: "/tmp/Show.S02E01.mkv"), URL(filePath: "/tmp/Show.S01E02.mkv"), URL(filePath: "/tmp/Show.S01E01.mkv"), URL(filePath: "/tmp/Film.2024.mp4")])
    #expect(library.groupedItems.count == 2)
    let group = try #require(library.groupedItems.first(where: { $0.isTV }))
    #expect(group.items.count == 3)
    #expect(group.items.first?.url.lastPathComponent == "Show.S01E01.mkv")
    #expect(group.subtitle == "2 季 · 3 集")
    let info = MovieInfo(id: 123, kind: "tv", title: "测试剧集", year: "2024", overview: "", poster: nil)
    library.applyMetadata(info, to: group.items.map(\.id))
    #expect(library.groupedItems.first(where: { $0.isTV })?.title == "测试剧集")
    library.setWatched(group.items.map(\.id), to: true)
    #expect(library.groupedItems.first(where: { $0.isTV })?.isWatched == true)
    library.setWatched(group.items.map(\.id), to: false)
    #expect(library.groupedItems.first(where: { $0.isTV })?.isWatched == false)
    #expect(Library(file: file).groupedItems.first(where: { $0.isTV })?.title == "测试剧集")
}
@Test func enrichesTMDBDetails() async throws {
    let client = TMDBClient { request in
        #expect(request.url?.path == "/3/movie/123")
        return (Data(#"{"runtime":123,"genres":[{"name":"剧情"}],"credits":{"cast":[{"id":9,"name":"Actor","character":"Role","profile_path":"/actor.jpg"}]}}"#.utf8), 200)
    }
    let original = MovieInfo(id: 123, kind: "movie", title: "Film", year: "2024", overview: "", poster: nil)
    let info = try await client.details(original, token: "test")
    #expect(info.runtime == 123)
    #expect(info.genres == ["剧情"])
    #expect(info.cast?.first?.photo?.absoluteString == "https://image.tmdb.org/t/p/w185/actor.jpg")
    #expect(info.detailsLoaded == true)
}

@Test func parsesChineseNamesWithoutSeparators() {
    let episode = MediaName("顶楼S01E14")
    #expect(episode.isTV)
    #expect(episode.title == "顶楼")
    let title = MediaName("鲨鱼：风暴2025.S01E01")
    #expect(title.title == "鲨鱼：风暴")
    #expect(title.year == "2025")
    #expect(MediaName("2001.A.Space.Odyssey.1968.1080p").title == "2001 A Space Odyssey")
}

@Test func findsNextEpisodeAcrossSeasons() {
    let first = Media(url: URL(filePath: "/tmp/Show.S01E01.mkv"), title: "1")
    let second = Media(url: URL(filePath: "/tmp/Show.S01E02.mkv"), title: "2")
    let nextSeason = Media(url: URL(filePath: "/tmp/Show.S02E01.mkv"), title: "3")
    let groups = MediaGroup.make([nextSeason, second, first])
    #expect(Playback.nextEpisode(after: first.id, groups: groups)?.id == second.id)
    #expect(Playback.nextEpisode(after: second.id, groups: groups)?.id == nextSeason.id)
    #expect(Playback.nextEpisode(after: nextSeason.id, groups: groups) == nil)
}

@Test func handlesReleaseTagsAndBilingualTitles() {
    let name = MediaName("驾驶.Drive.2024.1080p")
    #expect(name.searchTitles == ["驾驶 Drive", "驾驶"])
    #expect(MediaName("鲨鱼：起点 韩语中字 2021 1080P").title == "鲨鱼：起点")
    #expect(MediaName("韩语老师.2020").title == "韩语老师")
    let movie = MovieInfo(id: 3, kind: "movie", title: "驾驶", year: "2024", overview: "", poster: nil, originalTitle: "Drive")
    #expect(MovieInfo.automaticMatch([movie], name: name)?.id == 3)
    #expect(EpisodeCode("剧名.第二季.第十二集.mkv") == EpisodeCode("Show.S02E12.mkv"))
}
@Test @MainActor func storesMetadataOnceAndPreservesReviewCheckpoints() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "library.json")
    let library = Library(file: file)
    library.add([URL(filePath: "/tmp/Show.S01E01.mkv"), URL(filePath: "/tmp/Show.S01E02.mkv"), URL(filePath: "/tmp/Other.mp4")])
    let ids = library.items.prefix(2).map(\.id)
    let info = MovieInfo(id: 1, kind: "tv", title: "Shared metadata", year: "2024", overview: "same", poster: nil)
    library.applyMatchBatch([MatchOutcome(ids: ids, info: info), MatchOutcome(ids: [library.items[2].id], info: nil)])
    let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect((raw["metadata"] as? [String: Any])?.count == 1)
    let restored = Library(file: file)
    #expect(restored.items[0].metadata == info)
    #expect(restored.items[1].metadata == info)
    #expect(restored.items[2].matchState == "needs-review")
    #expect(restored.items[2].matchCheckedAt != nil)
    // Automatic results must not replace an existing manual match.
    restored.applyMatchBatch([MatchOutcome(ids: ids, info: nil)])
    #expect(restored.items[0].metadata == info)
}
@Test func cachesSeasonEpisodeDetails() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let client = TMDBClient { request in
        #expect(request.url?.path == "/3/tv/99/season/2")
        return (Data(#"{"episodes":[{"id":10,"episode_number":1,"name":"第一集标题","overview":"单集简介","still_path":"/still.jpg","runtime":45}]}"#.utf8), 200)
    }
    let first = try await client.season(series: 99, number: 2, token: "test", cacheDirectory: folder)
    #expect(first.first?.name == "第一集标题")
    #expect(first.first?.still?.absoluteString == "https://image.tmdb.org/t/p/w500/still.jpg")
    let offline = TMDBClient { _ in throw URLError(.notConnectedToInternet) }
    #expect(try await offline.season(series: 99, number: 2, token: "", cacheDirectory: folder) == first)
}

@Test @MainActor func migrationBacksUpLegacyBytes() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "library.json")
    let item = Media(url: URL(filePath: "/tmp/Show.S01E01.mkv"), title: "Show")
    let bytes = try JSONEncoder().encode([item])
    try bytes.write(to: file)
    let library = Library(file: file)
    library.setFavorite([item.id], to: true)
    #expect(try Data(contentsOf: folder.appending(path: "library-v1-backup.json")) == bytes)
    #expect(Library(file: file).items.first?.favorite == true)
}
@Test func explicitMovieMatchOverridesFilenameHeuristic() {
    var media = Media(url: URL(filePath: "/tmp/Film.S01E01.mp4"), title: "Film")
    media.metadata = MovieInfo(id: 9, kind: "movie", title: "Film", year: "2024", overview: "", poster: nil)
    #expect(MediaGroup.make([media]).first?.isTV == false)
}

@Test @MainActor func currentBuildReopensPreReleaseLibraryAndSources() throws {
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let libraryFile = folder.appending(component: "library.json")
    let sourcesFile = folder.appending(component: "sources.json")
    let source = UUID()
    let item = UUID()
    // Use the persisted v2 layout from the public 0.19.3 build.
    let oldLibrary = """
    {"version":2,"items":[{"id":"\(item)","url":"file:///Volumes/Videos/Film.mkv","title":"Film","added":100,"position":42,"duration":120,"favorite":true,"playlists":["周末"],"relativePath":"Film.mkv","sourceID":"\(source)"}],"metadata":{"movie:12":{"id":12,"kind":"movie","title":"手动匹配","year":"2024","overview":"片库资料"}},"links":{"\(item)":"movie:12"}}
    """
    let oldSources = """
    [{"id":"\(source)","name":"NAS","url":"smb://nas.local/Videos","connectionKind":"smb","lastScan":100}]
    """
    try Data(oldLibrary.utf8).write(to: libraryFile)
    try Data(oldSources.utf8).write(to: sourcesFile)

    let library = Library(file: libraryFile)
    let store = SourcesStore(file: sourcesFile)
    #expect(library.error == nil)
    #expect(store.error == nil)
    #expect(store.sources.first?.id == source)
    #expect(store.sources.first?.lastScan == Date(timeIntervalSinceReferenceDate: 100))
    #expect(library.items.first?.position == 42)
    #expect(library.items.first?.favorite == true)
    #expect(library.items.first?.playlists == ["周末"])
    #expect(library.items.first?.metadata?.title == "手动匹配")
    #expect(library.items.first?.sourceID == source)

    library.update(item, position: 50, duration: 120)
    let reopened = Library(file: libraryFile)
    #expect(reopened.items.first?.position == 50)
    #expect(reopened.items.first?.metadata?.id == 12)
    #expect(reopened.items.first?.sourceID == source)
}
