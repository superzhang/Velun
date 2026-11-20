import AppKit
import Foundation
import Testing
@testable import Luma

@Test func fileGridOnlyUsesArtworkForAnUnambiguousFolderOrVideo() throws {
    let source = UUID()
    let otherSource = UUID()
    let online = try #require(URL(string: "https://image.tmdb.org/t/p/w500/fixture.jpg"))
    let local = URL(filePath: "/tmp/FixturePoster.jpg")
    let show = MovieInfo(id: 10, kind: "tv", title: "示例剧集", year: "2026", overview: "", poster: online)
    let film = MovieInfo(id: 11, kind: "movie", title: "示例电影", year: "2025", overview: "", poster: online)
    func media(_ path: String, sourceID: UUID = source, info: MovieInfo, poster: URL? = nil) -> Media {
        Media(url: RemoteSources.virtualURL(source: sourceID, path: path), title: path, metadata: info,
              sourceID: sourceID, relativePath: path, sidecars: poster.map { MediaSidecars(poster: $0) })
    }
    let items = [
        media("大陆/单剧目录/示例剧集.S02E01.mkv", info: show, poster: local),
        media("大陆/单剧目录/示例剧集.S02E02.mkv", info: show),
        media("大陆/分类目录/示例剧集.S02E01.mkv", info: show),
        media("大陆/分类目录/示例电影.mkv", info: film),
        media("大陆/影片.mkv", info: film),
        media("大陆/同名空目录/示例电影.mkv", sourceID: otherSource, info: film)
    ]
    let index = FileDirectoryArtwork.index(groups: MediaGroup.make(items), directories: [source: ["大陆"]])
    let series = try #require(index["单剧目录"])
    #expect(series.title == "示例剧集")
    #expect(series.subtitle == "第 2 季")
    #expect(series.poster == local)
    #expect(series.fallback == online)
    #expect(index["影片.mkv"]?.title == "示例电影")
    #expect(index["分类目录"] == nil)
    #expect(index["同名空目录"] == nil)
}

@Test func episodeCanUsePosterInParentSeriesFolder() throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let season = root.appending(component: "Season 01")
    try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
    try Data().write(to: root.appending(component: "tvshow.nfo"))
    let poster = root.appending(component: "poster.jpg")
    let marker = Data("series artwork fixture".utf8)
    try marker.write(to: poster)
    try Data().write(to: season.appending(component: "Fixture.S01E01.mkv"))
    let scan = try SourceWorker.scanDirectory(root)
    let artwork = try #require(scan.files.first?.sidecars?.poster)
    #expect(artwork.lastPathComponent == "poster.jpg")
    #expect(try Data(contentsOf: artwork) == marker)
}

@Test func folderWithItsOwnSeriesNFODoesNotInheritAnotherShowsPoster() throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let child = root.appending(component: "Different Show")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try Data().write(to: root.appending(component: "tvshow.nfo"))
    try Data().write(to: root.appending(component: "poster.jpg"))
    try Data().write(to: child.appending(component: "tvshow.nfo"))
    try Data().write(to: child.appending(component: "Fixture.S01E01.mkv"))
    let video = try #require(SourceWorker.scanDirectory(root).files.first)
    #expect(video.nfo?.show?.deletingLastPathComponent().lastPathComponent == child.lastPathComponent)
    #expect(video.sidecars?.poster == nil)
}

@Test func scanFindsArtworkAndSubtitlesInTheSameDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let season = root.appending(component: "第 1 季")
    try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
    for name in ["剧集 #1.mkv", "剧集 #1.zh-Hans.forced.srt", "剧集 #1.en.ass", "剧集 #1-poster.PNG",
                 "poster.jpg", "fanart.jpg", "剧集 #10.srt", "剧集 #1.extra.srt", "剧集 #1.fr.idx", "剧集 #1.fr.sub"] {
        try Data().write(to: season.appending(component: name))
    }
    try Data().write(to: root.appending(component: "剧集 #1.ja.srt"))
    let scan = try SourceWorker.scanDirectory(root)
    let file = try #require(scan.files.first)
    #expect(scan.files.count == 1)
    #expect(file.relativePath == "第 1 季/剧集 #1.mkv")
    #expect(file.sidecars?.poster?.lastPathComponent == "剧集 #1-poster.PNG")
    #expect(file.sidecars?.backdrop?.lastPathComponent == "fanart.jpg")
    let prioritized = SidecarIndex.prioritizedSubtitles(file.sidecars?.subtitles ?? [], for: file.url, language: .chinese)
    #expect(prioritized.first?.lastPathComponent == "剧集 #1.zh-Hans.forced.srt")
    #expect(Set(file.sidecars?.subtitles.map(\.lastPathComponent) ?? []) == ["剧集 #1.zh-Hans.forced.srt", "剧集 #1.en.ass", "剧集 #1.fr.idx"])
}

@Test @MainActor func fullRescanMarksMissingAndRestoresExistingWatchState() throws {
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let storage = folder.appending(component: "library.json")
    let library = Library(file: storage)
    let source = UUID()
    let video = ScannedFile(url: folder.appending(component: "Movie #1.mkv"), relativePath: "Movie #1.mkv", localFile: false)
    #expect(library.importSource(source, files: [video], complete: true).added == 1)
    let first = try #require(library.items.first)
    library.setWatched([first.id], to: true)
    let before = library.structureRevision
    #expect(!library.importSource(source, files: [video], complete: true).hasChanges)
    #expect(!library.importSource(source, files: [], complete: false).hasChanges)
    #expect(library.items.first?.sourceMissing == nil)
    #expect(library.structureRevision == before)
    #expect(library.importSource(source, files: [], complete: true).missing == 1)
    #expect(!library.importSource(source, files: [], complete: true).hasChanges)
    #expect(Library(file: storage).items.first?.sourceMissing == true)
    let newMount = ScannedFile(url: folder.appending(path: "another mount/Movie #1.mkv"), relativePath: video.relativePath, localFile: false)
    #expect(library.importSource(source, files: [newMount], complete: true).updated == 1)
    #expect(library.items.count == 1)
    #expect(library.items.first?.id == first.id)
    #expect(library.items.first?.sourceMissing == nil)
    #expect(library.items.first?.isWatched == true)
    #expect(library.items.first?.url == newMount.url)
}

@Test func virtualSidecarsKeepTheirDirectoryAndSpecialCharacters() throws {
    let id = UUID()
    let video = RemoteSources.virtualURL(source: id, path: "剧集 #1/第 2 集 %20.mkv")
    let poster = RemoteSources.virtualURL(source: id, path: "剧集 #1/poster.jpg")
    let subtitle = RemoteSources.virtualURL(source: id, path: "剧集 #1/第 2 集 %20.zh.srt")
    #expect(video.deletingLastPathComponent() == poster.deletingLastPathComponent())
    #expect(subtitle.pathComponents.dropFirst().joined(separator: "/") == "剧集 #1/第 2 集 %20.zh.srt")
    var index = SidecarIndex()
    index.insert(poster)
    index.insert(subtitle)
    #expect(index.sidecars(for: video) == MediaSidecars(poster: poster, subtitles: [subtitle]))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_DAV_SIDECAR_FIXTURE"] != nil))
func webDAVScanFindsSiblingFilesAndBridgeServesSubtitle() async throws {
    let address = try #require(ProcessInfo.processInfo.environment["LUMA_DAV_SIDECAR_FIXTURE"])
    let url = try #require(URL(string: address))
    let credentials = SourceCredentials(username: "velun-fixture", password: "loopback-only")
    let source = LibrarySource(name: "WebDAV Fixture", url: url, connectionKind: .webdav)
    let remote = RemoteSources(credentialsProvider: { _ in credentials })
    do {
        let scan = try await remote.scan(source, credentials: credentials)
        let video = try #require(scan.files.first)
        #expect(scan.files.count == 1)
        #expect(video.sidecars?.poster?.lastPathComponent == "poster.jpg")
        #expect(video.sidecars?.backdrop?.lastPathComponent == "fanart.jpg")
        #expect(video.localMetadata?.work?.title == "WebDAV 本地片名")
        let subtitle = try #require(video.sidecars?.subtitles.first)
        #expect(subtitle.lastPathComponent == "测试 #1.zh.srt")
        let playback = try await remote.playbackURL(source: source, path: subtitle.pathComponents.dropFirst().joined(separator: "/"))
        let (data, response) = try await URLSession.shared.data(from: playback)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("WebDAV external subtitle fixture"))
        await remote.stopAll()
    } catch {
        await remote.stopAll()
        throw error
    }
}

@Test @MainActor func localPosterLoadsWithoutTMDB() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let video = folder.appending(component: "孤立电影.mkv")
    let poster = folder.appending(component: "poster.png")
    let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aFioAAAAASUVORK5CYII="))
    try Data().write(to: video)
    try data.write(to: poster)
    let match = try #require(try SourceWorker.scanDirectory(folder).files.first?.sidecars?.poster)
    let loaded = try await PosterCache.shared.data(for: match)
    #expect(loaded == data)
    #expect(NSImage(data: loaded)?.isValid == true)
}
