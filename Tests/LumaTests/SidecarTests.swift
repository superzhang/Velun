import AppKit
import Foundation
import Testing
@testable import Luma

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
    library.importSource(source, files: [video], complete: true)
    let first = try #require(library.items.first)
    library.setWatched([first.id], to: true)
    let before = library.structureRevision
    library.importSource(source, files: [], complete: false)
    #expect(library.items.first?.sourceMissing == nil)
    #expect(library.structureRevision == before)
    library.importSource(source, files: [], complete: true)
    #expect(Library(file: storage).items.first?.sourceMissing == true)
    let newMount = ScannedFile(url: folder.appending(path: "another mount/Movie #1.mkv"), relativePath: video.relativePath, localFile: false)
    library.importSource(source, files: [newMount], complete: true)
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
