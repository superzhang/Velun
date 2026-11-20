import Foundation
import Testing
@testable import Luma

@Test func nfoRescanReusesVersionsAndRetriesUnreadableFiles() async throws {
    let folder = URL.temporaryDirectory.appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let local = folder.appending(component: "movie.nfo")
    let remote = URL(string: "https://fixture.invalid/movie.nfo")!
    let video = ScannedFile(url: folder.appending(component: "movie.mkv"), relativePath: "movie.mkv",
                            nfo: NFOCandidates(video: remote))
    let firstVersion = MediaFileVersion(size: 42, modified: "2026-01-01")
    let secondVersion = MediaFileVersion(size: 42, modified: "2026-01-02")
    try Data("<movie><title>First</title></movie>".utf8).write(to: local)
    let initial = try await NFOReader.enrich([video], previous: .init(), versions: [remote: firstVersion]) { _ in local }
    let repeated = try await NFOReader.enrich([video], previous: initial.cache, versions: [remote: firstVersion]) { _ in
        Issue.record("Unchanged file was read again")
        throw URLError(.timedOut)
    }
    #expect(repeated.files.first?.localMetadata?.work?.title == "First")

    let failed = try await NFOReader.enrich([video], previous: repeated.cache, versions: [remote: secondVersion]) { _ in
        throw URLError(.timedOut)
    }
    #expect(failed.files.first?.nfoReadFailed == true)
    try Data("<movie><title>Later</title></movie>".utf8).write(to: local)
    let retried = try await NFOReader.enrich([video], previous: failed.cache, versions: [remote: secondVersion]) { _ in local }
    #expect(retried.files.first?.localMetadata?.work?.title == "Later")
    let unversioned = try await NFOReader.enrich([video], previous: retried.cache, versions: [:]) { _ in
        throw URLError(.timedOut)
    }
    #expect(unversioned.files.first?.nfoReadFailed == true)
}

@Test func nfoParsesMetadataAndRejectsCustomEntities() throws {
    let xml = """
    <movie>
      <title>飞行 &amp; 回家</title><originaltitle>Home</originaltitle>
      <plot><![CDATA[家庭 <团聚>]]></plot><premiered>2025-10-10</premiered>
      <runtime>105</runtime><genre>剧情</genre><genre>冒险</genre>
      <actor><name>A</name><title>Ignore this</title></actor>
      <uniqueid type="tmdb">234</uniqueid><uniqueid type="imdb">tt1234567</uniqueid>
    </movie>
    """
    let record = try #require(NFOReader.parse(Data(xml.utf8)))
    #expect(record.title == "飞行 & 回家")
    #expect(record.overview == "家庭 <团聚>")
    #expect(record.releaseDate == "2025-10-10")
    #expect(record.runtime == 105)
    #expect(record.genres == ["剧情", "冒险"])
    #expect(record.imdbID == "tt1234567")
    #expect(NFOReader.parse(Data("<movie><title>Incomplete".utf8)) == nil)
    let external = """
    <!DOCTYPE movie [<!ENTITY secret SYSTEM "file:///etc/hosts">]>
    <movie><title>&secret;</title></movie>
    """
    #expect(NFOReader.parse(Data(external.utf8)) == nil)
}

@Test @MainActor func scanUsesShowAndEpisodeNFOAndKeepsWatchStateOnUpdate() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let show = root.appending(component: "影视 #1")
    let season = show.appending(component: "Season 02")
    try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
    let showNFO = show.appending(component: "tvshow.nfo")
    try Data("<tvshow><title>本地剧集</title><genre>悬疑</genre><plot>总简介</plot></tvshow>".utf8).write(to: showNFO)
    for (filename, episode) in [("A", 4), ("B", 2)] {
        try Data().write(to: season.appending(component: filename + ".mkv"))
        try Data("<episodedetails><title>第\(episode)集标题</title><season>2</season><episode>\(episode)</episode></episodedetails>".utf8)
            .write(to: season.appending(component: filename + ".nfo"))
    }
    let scan = try await SourceWorker.scan(root)
    #expect(scan.files.count == 2)
    let db = root.appending(component: "library.json")
    let source = UUID()
    let library = Library(file: db)
    library.importSource(source, files: scan.files, complete: true)
    let group = try #require(library.groupedItems.first)
    #expect(library.groupedItems.count == 1)
    #expect(group.title == "本地剧集")
    #expect(group.genres == ["悬疑"])
    #expect(group.isTV)
    #expect(group.searchIndex.contains("第2集标题"))
    #expect(group.items.map { EpisodeCode($0).episode } == [2, 4])
    let media = try #require(group.items.first)
    library.setWatched([media.id], to: true)

    let listed = try SourceWorker.scanDirectory(root)
    let unreadable = try await NFOReader.enrich(listed.files) { _ in throw URLError(.timedOut) }
    library.importSource(source, files: unreadable, complete: true)
    #expect(library.groupedItems.first?.title == "本地剧集")

    try Data("<tvshow><title>更新后的剧名</title></tvshow>".utf8).write(to: showNFO)
    let updated = try await SourceWorker.scan(root, previous: try #require(scan.nfoCache))
    library.importSource(source, files: updated.files, complete: true)
    let restored = Library(file: db)
    #expect(restored.groupedItems.first?.title == "更新后的剧名")
    #expect(restored.groupedItems.first?.items.first?.id == media.id)
    #expect(restored.groupedItems.first?.items.first?.isWatched == true)
}

@Test func movieNFOAppliesOnlyToSingleVideoFolders() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let video = root.appending(component: "00.mkv")
    try Data().write(to: video)
    try Data("<movie><title>通用电影</title></movie>".utf8).write(to: root.appending(component: "movie.nfo"))
    let single = try await SidecarIndex.localFiles(for: [video])
    #expect(single.first?.localMetadata?.work?.title == "通用电影")
    try Data().write(to: root.appending(component: "01.mkv"))
    let multiple = try await SidecarIndex.localFiles(for: [video])
    #expect(multiple.first?.localMetadata == nil)
    try Data("<movie><title>同名电影</title></movie>".utf8).write(to: root.appending(component: "00.nfo"))
    let exact = try await SidecarIndex.localFiles(for: [video])
    #expect(exact.first?.localMetadata?.work?.title == "同名电影")
}
