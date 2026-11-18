import Foundation
import Testing
@testable import Luma

@Test @MainActor func episodePickerSelectsOnlyCurrentShowAndUsesSavedProgress() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "LumaEpisodes-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = Library(file: directory.appending(path: "library.json"))
    library.add(["Selected.Show.S02E01", "Other.Show.S01E01", "Selected.Show.S01E02", "Selected.Show.S01E01"]
        .map { URL(filePath: "/tmp/\($0).mp4") })
    let first = try #require(library.items.first { $0.url.lastPathComponent == "Selected.Show.S01E01.mp4" })
    let other = try #require(library.items.first { $0.url.lastPathComponent == "Other.Show.S01E01.mp4" })
    let secondSeason = try #require(library.items.first { $0.url.lastPathComponent == "Selected.Show.S02E01.mp4" })
    let playback = Playback(library: library)
    defer { playback.close() }
    library.update(secondSeason.id, position: 125, duration: 600)
    playback.open(first)
    #expect(playback.selectableEpisodes.map { $0.url.lastPathComponent } == [
        "Selected.Show.S01E01.mp4", "Selected.Show.S01E02.mp4", "Selected.Show.S02E01.mp4"
    ])
    playback.selectEpisode(other.id)
    #expect(playback.media?.id == first.id)
    playback.selectEpisode(secondSeason.id)
    #expect(playback.media?.id == secondSeason.id)
    #expect(playback.media?.position == 125)
}

@Test func emptyPasswordRemainsBlank() async throws {
    let (config, _) = try await RcloneTool.configuration(kind: .smb, url: URL(string: "smb://fixture")!, credentials: SourceCredentials(username: "guest", password: ""))
    let password = config.components(separatedBy: "\n").first { $0.hasPrefix("pass = ") }!.dropFirst(7)
    let base64 = String(password).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
    #expect(Data(base64Encoded: padded)?.count == 16) // IV only: zero plaintext bytes.
}

@Test(arguments: [false, true]) @MainActor func enhancedSwitchPreservesExplicitQueue(_ shuffled: Bool) throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "LumaReview-\(UUID())")
    let suite = "Luma.Review.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
    let library = Library(file: dir.appending(path: "library.json"))
    library.add([URL(filePath: "/tmp/Review.One.mp4"), URL(filePath: "/tmp/Review.Two.mp4")])
    let playback = Playback(library: library, preferences: PlaybackPreferences(defaults: defaults))
    defer { playback.close() }
    playback.playQueue(library.items, shuffled: shuffled, loop: true)
    let current = try #require(playback.media?.id), next = try #require(playback.nextEpisode?.id)
    playback.useEnhancedPlayer()
    #expect(playback.mpv != nil)
    #expect(playback.media?.id == current)
    #expect(playback.nextEpisode?.id == next)
    #expect(playback.previousEpisode?.id == next)
}

@Test(arguments: [false, true]) @MainActor func persistenceRecoversAfterTransientFailure(_ background: Bool) async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "LumaReview-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let parent = dir.appending(path: "blocked"), file = parent.appending(path: "library.json")
    let library = Library(file: file, backgroundSaving: background)
    try Data("temporary obstruction".utf8).write(to: parent)
    library.add([URL(filePath: "/tmp/Review.One.mp4")])
    await library.flush()
    #expect(library.error != nil)
    try FileManager.default.removeItem(at: parent)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    library.add([URL(filePath: "/tmp/Review.Two.mp4")])
    await library.flush()
    #expect(library.items.count == 2)
    #expect(library.error == nil)
    #expect(Library(file: file).items.count == 2)
}

@Test func threeEpisodeConfirmationRejectsRecapAndAmbiguousCandidates() async throws {
    var seed: UInt32 = 12345
    func random() -> AutoSkip.Print { seed = seed &* 1664525 &+ 1013904223; return AutoSkip.Print(bits: seed, audible: true) }
    let recap = (0..<550).map { _ in random() }, opening = (0..<430).map { _ in random() }
    let a = (0..<80).map { _ in random() } + recap + (0..<200).map { _ in random() } + opening
    let b = (0..<110).map { _ in random() } + recap + (0..<240).map { _ in random() } + opening
    let c = (0..<300).map { _ in random() } + opening + (0..<100).map { _ in random() }
    let pair = try await AutoSkip.commonCandidates(a, b)
    let third = try await AutoSkip.commonCandidates(a, c)
    #expect(pair.count >= 2)
    let match = try #require(AutoSkip.consistentCandidate(pair, third, maximum: 180))
    #expect(match.lowerBound > 50)
    #expect(AutoSkip.consistentCandidate(pair, pair, maximum: 180) == nil)
    #expect(AutoSkip.consistentCandidate(pair, [], maximum: 180) == nil)
}

private struct RegressionFixture: Decodable {
    let http: Int
    let username: String
    let password: String
    let token: String
    static func load() throws -> Self {
        let file = URL(filePath: ProcessInfo.processInfo.environment["LUMA_REMOTE_FIXTURE_MANIFEST"]!)
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_REMOTE_FIXTURE_MANIFEST"] != nil))
func expiredTokenReauthenticatesOnce() async throws {
    let fixture = try RegressionFixture.load()
    let source = LibrarySource(name: "Review", url: URL(string: "http://127.0.0.1:\(fixture.http)/jellyfin")!, connectionKind: .jellyfin)
    let stale = SourceCredentials(username: fixture.username, password: fixture.password, token: "expired-token")
    let refreshed = try await MediaServerClient.scan(source, credentials: stale)
    #expect(refreshed.credentials.token == fixture.token)
    let wrong = SourceCredentials(username: fixture.username, password: "wrong", token: "expired-token")
    await #expect(throws: (any Error).self) { _ = try await MediaServerClient.scan(source, credentials: wrong) }
    let fresh = try await MediaServerClient.scan(source, credentials: SourceCredentials(username: fixture.username, password: fixture.password))
    #expect(fresh.credentials.token == fixture.token)
    #expect(fresh.result.files.count == 1)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_REMOTE_FIXTURE_MANIFEST"] != nil)) @MainActor
func rescanKeepsPlayingBridgeAndConnectionRevisionsCoexist() async throws {
    let fixture = try RegressionFixture.load()
    let dir = FileManager.default.temporaryDirectory.appending(path: "LumaReview-\(UUID())")
    let suite = "Luma.Review.Scan.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
    defaults.set(false, forKey: "tmdb.autoMatch")
    let library = Library(file: dir.appending(path: "library.json"))
    let metadata = MetadataStore(defaults: defaults)
    let sources = SourcesStore(file: dir.appending(path: "sources.json"))
    let source = sources.add(name: "Review", url: URL(string: "http://127.0.0.1:\(fixture.http)/dav/")!, kind: .webdav)
    try SourceSecrets.save(SourceCredentials(username: fixture.username, password: fixture.password), id: source.id)
    defer { SourceSecrets.remove(source.id) }
    do {
        let before = try await RemoteSources.shared.playbackURL(source: source, path: "Fixture.S01E01.mkv")
        var request = URLRequest(url: before); request.setValue("bytes=0-15", forHTTPHeaderField: "Range"); request.timeoutInterval = 2
        let (body, _) = try await URLSession.shared.data(for: request)
        #expect(body.count == 16)
        sources.scan(source, library: library, metadata: metadata)
        for _ in 0..<500 { if !sources.busy { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(!sources.busy)
        #expect(sources.error == nil)
        let (after, _) = try await URLSession.shared.data(for: request)
        #expect(after == body)
        #expect(try await RemoteSources.shared.playbackURL(source: source, path: "Fixture.S01E01.mkv") == before)
        var changed = source; changed.connectionRevision = UUID()
        let replacement = try await RemoteSources.shared.playbackURL(source: changed, path: "Fixture.S01E01.mkv")
        #expect(replacement != before)
        let (oldBody, _) = try await URLSession.shared.data(for: request)
        #expect(oldBody == body)
        request.url = replacement
        let (newBody, _) = try await URLSession.shared.data(for: request)
        #expect(newBody == body)
        await RemoteSources.shared.stop(source.id)
    } catch { await RemoteSources.shared.stop(source.id); throw error }
}

@Test @MainActor func localFolderAppearsInLocalFilter() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "LumaReview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let library = Library(file: dir.appending(path: "library.json"))
    let sourceID = UUID()
    library.importSource(sourceID, files: [ScannedFile(url: dir.appending(path: "Movies/Local.Movie.mp4"), relativePath: "Local.Movie.mp4")])
    #expect(library.items.first?.url.isFileURL == true)
    let cache = LibraryQueryCache()
    #expect(cache.groups(in: library, destination: .all).count == 1)
    #expect(cache.groups(in: library, destination: .all, localOnly: true).count == 1)
}

@Test func editedLoginInvalidatesDerivedSession() {
    let old = SourceCredentials(username: "a", password: "one", token: "cached", userID: "old-user")
    var changed = old; changed.password = "two"
    #expect(changed.edited(from: old).token.isEmpty)
    #expect(changed.edited(from: old).userID.isEmpty)
    changed.token = "explicit"
    #expect(changed.edited(from: old).token == "explicit")
    #expect(changed.edited(from: old).userID.isEmpty)
    #expect(old.edited(from: old).token == "cached")
    #expect(old.edited(from: old, endpointChanged: true).token.isEmpty)
}

@Test @MainActor func legacyLocalSourcesMigrateWithoutIncludingMountedNetworkSources() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "LumaRegression-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let library = Library(file: dir.appending(path: "library.json"))
    let local = UUID(), network = UUID()
    library.importSource(local, files: [ScannedFile(url: dir.appending(path: "Local.mp4"), relativePath: "Local.mp4", localFile: false)])
    library.importSource(network, files: [ScannedFile(url: URL(filePath: "/Volumes/NAS/Network.mp4"), relativePath: "Network.mp4", localFile: false)])
    let ids = library.items.map(\.id)
    library.updateSourceLocality([local: true, network: false])
    #expect(library.items.map(\.id) == ids)
    #expect(LibraryQueryCache().groups(in: library, destination: .all, localOnly: true).count == 1)
    #expect(Library(file: dir.appending(path: "library.json")).items.first?.localFile == true)
}

@Test func skipCacheInvalidatesWhenSourceConnectionChanges() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "LumaCacheRegression-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "sources.json")
    var source = LibrarySource(name: "NAS", url: URL(string: "smb://fixture/Movies")!, connectionKind: .smb, directSMB: true)
    var media = Media(url: RemoteSources.virtualURL(source: source.id, path: "Show.S01E01.mkv"), title: "Show")
    media.sourceID = source.id
    try JSONEncoder().encode([source]).write(to: file)
    let first = await AutoSkipCache.key(media: media, reference: media, confirmation: media, duration: 1200, sourcesFile: file)
    source.connectionRevision = UUID()
    try JSONEncoder().encode([source]).write(to: file)
    let changed = await AutoSkipCache.key(media: media, reference: media, confirmation: media, duration: 1200, sourcesFile: file)
    #expect(first != changed)
}
