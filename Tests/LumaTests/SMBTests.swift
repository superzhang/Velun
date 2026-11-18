import Foundation
import Testing
@testable import Luma

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
func smbAuthenticatesBrowsesScansAndSeeks() async throws {
    let root = URL(string: "smb://127.0.0.1:14455")!
    let credentials = SourceCredentials(username: "luma-test", password: "fixture-only")
    let shares = try await SMBClient.browse(root, credentials: credentials)
    let share = try #require(shares.first { $0.name.lowercased() == "movies" })
    let directories = try await SMBClient.browse(share.url, credentials: credentials)
    #expect(directories.contains { $0.name == "剧集" })
    let source = LibrarySource(name: "Fixture", url: share.url, connectionKind: .smb, directSMB: true)
    let remote = RemoteSources(credentialsProvider: { _ in credentials })
    do {
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
