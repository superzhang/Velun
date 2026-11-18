import Foundation
import Testing
import CMPV
@testable import Luma

private struct RemoteFixture: Decodable {
    let http: Int, ftp: Int, sftp: Int
    let username: String, password: String, token: String, knownHosts: String, file: String
    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(filePath: ProcessInfo.processInfo.environment["LUMA_REMOTE_FIXTURE_MANIFEST"]!)))
    }
    var credentials: SourceCredentials { SourceCredentials(username: username, password: password, token: token, knownHosts: knownHosts) }
    func source(_ kind: SourceKind) -> LibrarySource {
        let address: String = switch kind {
        case .ftp: "ftp://127.0.0.1:\(ftp)/"
        case .sftp: "sftp://127.0.0.1:\(sftp)/"
        case .webdav, .alist: "http://127.0.0.1:\(http)/dav/"
        case .dlna: "http://127.0.0.1:\(http)/dlna/device.xml"
        default: "http://127.0.0.1:\(http)/\(kind.rawValue)"
        }
        return LibrarySource(name: "Fixture", url: URL(string: address)!, connectionKind: kind)
    }
    func verifyRange(_ url: URL) async throws {
        var request = URLRequest(url: url); request.setValue("bytes=128-1151", forHTTPHeaderField: "Range"); request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(data == Data(try Data(contentsOf: URL(filePath: file))[128..<1152]))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_REMOTE_FIXTURE_MANIFEST"] != nil), arguments: [SourceKind.webdav, .alist, .ftp, .sftp])
func authenticatedRemoteScanAndSeeking(_ kind: SourceKind) async throws {
    let fixture = try RemoteFixture.load(), source = fixture.source(kind), credentials = fixture.credentials
    let remote = RemoteSources(credentialsProvider: { _ in credentials })
    do {
        let result = try await remote.scan(source, credentials: credentials)
        #expect(result.files.count == 1)
        let file = try #require(result.files.first)
        #expect(file.url.scheme == "luma-source")
        async let first = remote.playbackURL(source: source, path: file.relativePath)
        async let second = remote.playbackURL(source: source, path: file.relativePath)
        let urls = try await (first, second)
        #expect(urls.0 == urls.1)
        try await fixture.verifyRange(urls.0)
        await remote.stopAll()
        var request = URLRequest(url: urls.0); request.timeoutInterval = 0.5
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(for: request) }
    } catch { await remote.stopAll(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_REMOTE_FIXTURE_MANIFEST"] != nil), arguments: [SourceKind.plex, .jellyfin, .emby])
func mediaServerAuthenticationAndRawPlayback(_ kind: SourceKind) async throws {
    let fixture = try RemoteFixture.load(), source = fixture.source(kind)
    var credentials = fixture.credentials
    if kind != .plex { credentials.token = "" }
    let scan = try await MediaServerClient.scan(source, credentials: credentials)
    #expect(scan.result.files.count == 1)
    #expect(scan.credentials.token == fixture.token)
    let file = try #require(scan.result.files.first)
    #expect(file.displayTitle?.contains("S01E01") == true)
    let authenticated = scan.credentials
    let remote = RemoteSources(credentialsProvider: { _ in authenticated })
    do {
        let url = try await remote.playbackURL(source: source, path: #require(file.remotePath))
        try await fixture.verifyRange(url)
        await remote.stopAll()
    } catch { await remote.stopAll(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_REMOTE_FIXTURE_MANIFEST"] != nil))
func dlnaBrowseAndPlayback() async throws {
    let fixture = try RemoteFixture.load()
    let result = try await DLNAClient.scan(fixture.source(.dlna))
    #expect(result.files.count == 1)
    try await fixture.verifyRange(#require(result.files.first?.url))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_REMOTE_FIXTURE_MANIFEST"] != nil))
func remoteRejectsBadCredentialsAndHostKey() async throws {
    let fixture = try RemoteFixture.load(), remote = RemoteSources()
    let wrong = SourceCredentials(username: fixture.username, password: "wrong")
    await #expect(throws: (any Error).self) { _ = try await remote.scan(fixture.source(.webdav), credentials: wrong) }
    var host = fixture.credentials; host.knownHosts = "/dev/null"
    let badHost = host
    await #expect(throws: (any Error).self) { _ = try await remote.scan(fixture.source(.sftp), credentials: badHost) }
}

@Test func remoteAddressesAndPaths() {
    for kind in SourceKind.allCases { #expect(kind.validatedURL(kind.placeholder) != nil) }
    #expect(SourceKind.webdav.validatedURL("https://user:password@nas/dav") == nil)
    #expect(SourceKind.webdav.validatedURL("https://nas/dav?token=secret") == nil)
    #expect(!RemoteSources.safePath("../movie.mkv"))
    #expect(RemoteSources.virtualURL(source: UUID(), path: "剧集/第一集 #1.mkv").lastPathComponent == "第一集 #1.mkv")
}

@Test func stoppingRemoteStartupCancelsPendingConnection() async throws {
    let remote = RemoteSources(credentialsProvider: { _ in
        try await Task.sleep(for: .seconds(10)); return SourceCredentials()
    })
    let source = LibrarySource(name: "Cancelled", url: URL(string: "http://127.0.0.1:9/dav/")!, connectionKind: .webdav)
    let pending = Task { try await remote.playbackURL(source: source, path: "movie.mkv") }
    try await Task.sleep(for: .milliseconds(50))
    await remote.stopAll()
    await #expect(throws: CancellationError.self) { _ = try await pending.value }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_REMOTE_FIXTURE_MANIFEST"] != nil))
func decodesAndSeeksAuthenticatedServerMKV() async throws {
    let fixture = try RemoteFixture.load(), source = fixture.source(.plex), credentials = fixture.credentials
    let remote = RemoteSources(credentialsProvider: { _ in credentials })
    do {
        let url = try await remote.playbackURL(source: source, path: "library/parts/ep1/file.mkv")
        let handle = try #require(luma_create(1))
        defer { luma_destroy(handle) }
        #expect(luma_command(handle, "loadfile", url.absoluteString, "replace") >= 0)
        var loaded = false
        for _ in 0..<100 {
            var value = 0.0; var message: UnsafePointer<CChar>?
            while true {
                let event = luma_event(handle, &value, &message)
                if event == 0 { break }
                if event == 1 { loaded = true }
                if event == 2 { Issue.record("Remote decoder returned an error") }
            }
            if loaded { break }; try await Task.sleep(for: .milliseconds(100))
        }
        #expect(loaded)
        #expect(luma_command(handle, "seek", "5", "absolute+exact") >= 0)
        try await Task.sleep(for: .milliseconds(300))
        if let position = luma_get(handle, "time-pos") { #expect((Double(String(cString: position)) ?? 0) >= 5); luma_free(position) }
        else { Issue.record("Remote playback has no position") }
        await remote.stopAll()
    } catch { await remote.stopAll(); throw error }
}
