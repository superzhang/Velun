import Foundation
import Testing
@testable import Luma

@Test func finderResolvesMountedSMBAndReportsMissingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    let directory = root.appending(component: "影视 100%")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = directory.appending(component: "影片 #1.mkv")
    try Data().write(to: file)
    let source = LibrarySource(name: "Fixture", url: URL(string: "smb://finder-fixture.invalid/Movies")!, connectionKind: .smb, directSMB: true)
    let relativePath = "影视 100%/影片 #1.mkv"
    var media = Media(url: RemoteSources.virtualURL(source: source.id, path: relativePath), title: "Fixture")
    media.relativePath = relativePath
    let mount: @Sendable (URL) async throws -> URL = { _ in root }

    #expect(FinderLocation.isAvailable(for: media, source: source))
    #expect(try await FinderLocation.resolve(media, source: source, mount: mount) == file)
    media.url = root.appending(component: "old-mount").appending(component: "影片 #1.mkv")
    #expect(try await FinderLocation.resolve(media, source: source, mount: mount) == file)
    media.url = file
    #expect(try await FinderLocation.resolve(media, source: nil) == file)
    try FileManager.default.removeItem(at: file)
    await #expect(throws: NSError.self) {
        _ = try await FinderLocation.resolve(media, source: source, mount: mount)
    }
}

@Test func smbAcceptsDiscoveredServerAndRejectsCredentialsInURL() throws {
    #expect(SMBClient.endpoint("fixture-nas.local")?.host == "fixture-nas.local")
    #expect(SMBClient.endpoint("smb://nas.local:14455/")?.port == 14455)
    #expect(SMBClient.endpoint("smb://nas.local/剧集")?.lastPathComponent == "剧集")
    for value in ["smb://user:secret@nas/Movies", "smb://nas/../Movies", "smb://nas/%2e%2e/Movies", "smb://nas/Movies?token=secret", "smb://nas:99999", "smb://", "https://nas"] {
        #expect(SMBClient.endpoint(value) == nil)
    }
    // Saved sources from earlier versions retain their system-mount behavior.
    let legacy = LibrarySource(name: "Legacy", url: URL(string: "smb://nas/Movies")!, connectionKind: .smb)
    let data = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(LibrarySource.self, from: data)
    #expect(!decoded.isRemote)
    var direct = decoded; direct.directSMB = true
    #expect(direct.isRemote)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_SMB_FIXTURE"] != nil))
@MainActor func smbAuthenticatesBrowsesScansAndSeeks() async throws {
    let root = URL(string: "smb://127.0.0.1:14455")!
    let credentials = SourceCredentials(username: "luma-test", password: "fixture-only")
    let shares = try await SMBClient.browse(root, credentials: credentials)
    let share = try #require(shares.first { $0.name.lowercased() == "movies" })
    let directories = try await SMBClient.browse(share.url, credentials: credentials)
    let folder = try #require(directories.first { $0.name == "剧集" && $0.isDirectory })
    let directFiles = try await SMBClient.browse(folder.url, credentials: credentials)
    let directFile = try #require(directFiles.first { $0.name == "Fixture.S01E01.mp4" && !$0.isDirectory })
    let source = LibrarySource(name: "Fixture", url: share.url, connectionKind: .smb, directSMB: true)
    let remote = RemoteSources(credentialsProvider: { _ in credentials })
    do {
        let browser = LibrarySource(name: "Fixture NAS", url: root, connectionKind: .smb, directSMB: true, smbBrowseOnly: true)
        let directPlayback = try await remote.browsedSMBURL(directFile.url, connection: browser)
        let downloadsFolder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: downloadsFolder) }
        let downloads = OfflineDownloads(directory: downloadsFolder)
        downloads.start(name: directFile.name, key: directFile.url) { directPlayback }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while let item = downloads.items.first, case .transferring = item.state, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let downloaded = try #require(OfflineDownloads(directory: downloadsFolder).items.first)
        let copy = try #require({
            if case .ready(let copy) = downloaded.state { return copy }
            return nil
        }())
        #expect(try Data(contentsOf: copy) == Data(contentsOf: URL(filePath: ProcessInfo.processInfo.environment["LUMA_SMB_FIXTURE"]!)))
        let scan = try await remote.scan(source, credentials: credentials)
        let file = try #require(scan.files.first)
        #expect(scan.files.count == 1)
        #expect(file.relativePath == "剧集/Fixture.S01E01.mp4")
        let playback = try await remote.playbackURL(source: source, path: file.relativePath)
        var request = URLRequest(url: playback); request.setValue("bytes=128-1151", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        let original = try Data(contentsOf: URL(filePath: ProcessInfo.processInfo.environment["LUMA_SMB_FIXTURE"]!))
        #expect(data == original[128..<1152])
        await remote.stopAll()
        await #expect(throws: (any Error).self) {
            _ = try await SMBClient.browse(root, credentials: SourceCredentials(username: "luma-test", password: "wrong"))
        }
    } catch { await remote.stopAll(); throw error }
}

@Test @MainActor func savedSMBBrowserAndFavoritesPersistIndependently() throws {
    let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceFile = directory.appending(component: "sources.json")
    let store = SourcesStore(file: sourceFile)
    let url = try #require(SMBClient.endpoint("smb://NAS.test:445/影视 100%"))
    let browser = store.addSMBBrowser(name: "Fixture NAS", url: url, id: UUID())
    #expect(browser.url == SMBClient.endpoint("smb://nas.test"))
    #expect(store.sources.isEmpty)

    let library = Library(file: directory.appending(component: "library.json"))
    let metadata = MetadataStore()
    let favoriteID = UUID()
    store.busy = true
    store.addSMBFavorite(at: url, id: favoriteID, credentialOwnerID: browser.id, library: library, metadata: metadata)
    #expect(store.smbBrowserSources.map(\.id) == [browser.id])
    #expect(store.sources.map(\.id) == [favoriteID])
    #expect(store.smbFolder(at: url.appending(path: "", directoryHint: .isDirectory))?.id == favoriteID)
    let updated = store.update(browser, name: "Renamed NAS", url: browser.url, kind: .smb, directSMB: true)
    #expect(store.sources.first?.connectionRevision == updated.connectionRevision)
    #expect(store.sources.first?.credentialID == browser.id)

    store.setSMBFolderFavorite(false, for: favoriteID, library: library, metadata: metadata)
    let restored = SourcesStore(file: sourceFile)
    #expect(restored.smbBrowserSources.map(\.name) == ["Renamed NAS"])
    #expect(restored.sources.isEmpty)
    #expect(restored.excludedSourceIDs.contains(favoriteID))
    #expect(restored.smbFolder(at: url)?.credentialID == browser.id)

    restored.busy = true
    restored.setSMBFolderFavorite(true, for: favoriteID, library: library, metadata: metadata)
    #expect(SourcesStore(file: sourceFile).sources.map(\.id) == [favoriteID])
    _ = restored.add(name: "Local files", url: directory)
    #expect(restored.sources.count == 2)
    #expect(restored.starredSMBFolders.map(\.id) == [favoriteID])
}

@Test @MainActor func automaticRefreshRecordsUnmountedSourceWithoutMarkingItsFilesMissing() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = Library(file: folder.appending(component: "library.json"))
    let store = SourcesStore(file: folder.appending(component: "sources.json"))
    let source = store.add(name: "Offline", url: URL(string: "smb://velun-fixture.invalid/Movies")!, kind: .smb)
    let mediaURL = folder.appending(component: "Movie.mkv")
    library.importSource(source.id, files: [ScannedFile(url: mediaURL, relativePath: mediaURL.lastPathComponent)], complete: true)
    let suiteName = "Velun-Test-\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let metadata = MetadataStore(defaults: preferences)
    metadata.autoMatch = false

    #expect(store.refreshNetwork(library: library, metadata: metadata))
    try await awaitSourceScan(store)
    #expect(store.scanIssues[source.id] == .notMounted)
    #expect(store.networkIssueCount == 1)
    #expect(library.items.count == 1)
    #expect(library.items.first?.sourceMissing == nil)
    #expect(store.sources.first?.lastScan == nil)

    let updated = store.update(source, name: source.name, url: folder.appending(component: "recovered"), kind: .smb)
    #expect(store.scanIssues[source.id] == nil)
    store.scan(updated, library: library, metadata: metadata)
    try await awaitSourceScan(store)
    #expect(store.scanIssues[source.id] != nil)
    #expect(library.items.first?.sourceMissing == nil)

    try FileManager.default.createDirectory(at: updated.url, withIntermediateDirectories: true)
    try Data().write(to: updated.url.appending(component: "Movie.mkv"))
    store.scan(updated, library: library, metadata: metadata)
    try await awaitSourceScan(store)
    #expect(store.scanIssues[source.id] == nil)
    #expect(store.sources.first?.lastScan != nil)
    #expect(library.items.first?.url.lastPathComponent == "Movie.mkv")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VELUN_ACCEPT_MOUNTED_SMB"] == "1")) @MainActor
func automaticallyScansExistingSMBMountReadOnly() async throws {
    let shares = await MountedShareScanner.scan().filter { $0.kind == .smb }
    try #require(!shares.isEmpty)
    let selected = try #require(await smallMountedSMBDirectory(shares))
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let library = Library(file: folder.appending(component: "library.json"))
    let store = SourcesStore(file: folder.appending(component: "sources.json"))
    let source = store.add(name: "SMB acceptance", url: selected, kind: .smb)
    let suiteName = "Velun-Test-\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let metadata = MetadataStore(defaults: preferences)
    metadata.autoMatch = false

    #expect(store.refreshNetwork(library: library, metadata: metadata))
    try await awaitSourceScan(store)
    #expect(store.scanIssues[source.id] == nil)
    #expect(store.sources.first?.lastScan != nil)
    #expect(library.items.allSatisfy { !$0.isLocalFile })
}

@MainActor private func awaitSourceScan(_ store: SourcesStore) async throws {
    let clock = ContinuousClock()
    let timeout = clock.now + .seconds(10)
    while store.busy, clock.now < timeout { try await Task.sleep(for: .milliseconds(20)) }
    if store.busy { store.cancel() }
    try #require(!store.busy)
}

@concurrent private func smallMountedSMBDirectory(_ shares: [DiscoveredShare]) async -> URL? {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
    var folders = shares.compactMap { share in share.mountedURL.map { (local: $0, remote: share.url) } }
    for _ in 0..<30 {
        guard !folders.isEmpty else { break }
        let folder = folders.removeFirst()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder.local, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
        let directories = files.filter { file in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        if files.count <= 100 && directories.isEmpty { return folder.remote }
        folders += directories.prefix(12).map { ($0, folder.remote.appending(component: $0.lastPathComponent)) }
    }
    return nil
}
