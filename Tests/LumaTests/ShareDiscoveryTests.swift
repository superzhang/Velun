import Foundation
import Testing
@testable import Luma

@Test func mountedBonjourAliasesMatchTheResolvedSMBEndpointOnly() throws {
    let volume = URL(filePath: "/Volumes/Video")
    let service = try #require(URL(string: "smb://Office.NAS._smb._tcp.local./Video"))
    var share = try #require(MountedShareScanner.discovered(volume: volume, remount: service, name: "Video"))
    #expect(service.host.flatMap(MountedShareScanner.smbServiceName) == "Office.NAS")
    let actual = try #require(URL(string: "smb://files.local:445/Video/Series"))
    #expect(MountedShareScanner.directory(for: actual, on: share) == nil)
    share.mountedSMBEndpoint = MountedSMBEndpoint(host: "files.local.", port: 445, addresses: ["192.0.2.25"])
    #expect(MountedShareScanner.directory(for: actual, on: share) == volume.appending(component: "Series"))
    let numeric = try #require(URL(string: "smb://192.0.2.25/Video"))
    #expect(MountedShareScanner.directory(for: numeric, on: share) == volume)
    for value in ["smb://Office.NAS.local/Video", "smb://files.local:1445/Video", "smb://files.local/Other"] {
        let url = try #require(URL(string: value))
        #expect(MountedShareScanner.directory(for: url, on: share) == nil)
    }
}

@Test func advertisedShareAddressesAndPaths() throws {
    let dav = try #require(DiscoveredShare.bonjour(type: "_webdavs._tcp.", name: "家庭 NAS", host: "NAS.local.", port: 5006, txt: ["path": Data("/dav/电影/".utf8)]))
    #expect(dav.kind == .webdav)
    #expect(dav.url.scheme == "https")
    #expect(dav.url.host == "NAS.local")
    #expect(dav.url.port == 5006)
    #expect(dav.url.path == "/dav/电影")
    #expect(DiscoveredShare.bonjour(type: "_http._tcp.", name: "Web", host: "nas.local", port: 80, txt: [:]) == nil)
    #expect(DiscoveredShare.bonjour(type: "_webdav._tcp.", name: "Bad", host: "nas.local", port: 80, txt: ["path": Data("//other.example/dav".utf8)]) == nil)
    #expect(DiscoveredShare.bonjour(type: "_smb._tcp.", name: "NAS", host: "nas.local", port: 445, txt: [:])?.url.scheme == "smb")
}

@Test func discoveryDeduplicatesEndpointsWithoutCombiningProtocols() throws {
    let plain = DiscoveredShare(name: "NAS", kind: .webdav, url: URL(string: "http://NAS.local:80/")!)
    let mounted = DiscoveredShare(name: "DAV", kind: .webdav, url: URL(string: "http://nas.local")!, mountedURL: URL(filePath: "/Volumes/DAV"))
    let smb = DiscoveredShare(name: "NAS", kind: .smb, url: URL(string: "smb://nas.local/")!)
    let merged = DiscoveredShare.merged([plain, mounted, smb, plain])
    #expect(merged.count == 2)
    #expect(merged.first { $0.kind == .webdav }?.mountedURL == mounted.mountedURL)
    let sanitized = try #require(MountedShareScanner.discovered(volume: URL(filePath: "/Volumes/Video"), remount: URL(string: "smb://user:password@nas.local/Video?secret=1")!, name: "Video"))
    #expect(sanitized.url.user == nil && sanitized.url.password == nil && sanitized.url.query == nil)
    #expect(sanitized.mountedURL?.path == "/Volumes/Video")
    #expect(MountedShareScanner.discovered(volume: URL(filePath: "/"), remount: URL(filePath: "/"), name: "Disk") == nil)
}

@Test func jellyfinDiscoveryValidatesAdvertisedAddress() throws {
    let response = Data(#"{"Address":"http://192.0.2.10:8096/jellyfin","Name":"fixture-nas","Id":"fixture"}"#.utf8)
    let server = try #require(DiscoveredShare.jellyfin(response))
    #expect(server.name == "fixture-nas")
    #expect(server.kind == .jellyfin)
    #expect(server.url.path == "/jellyfin")
    #expect(DiscoveredShare.jellyfin(Data(#"{"Address":"file:///etc/passwd"}"#.utf8)) == nil)
}

@Test func nfsDiscoveryRejectsUnrelatedRPCResponses() {
    func packet(_ words: [UInt32]) -> Data { words.reduce(into: Data()) { output, word in var value = word.bigEndian; withUnsafeBytes(of: &value) { output.append(contentsOf: $0) } } }
    #expect(NFSDiscovery.acceptsReply(packet([0x80000018, 0x4c554d41, 1, 0, 0, 0, 0])))
    #expect(NFSDiscovery.acceptsReply(packet([0x80000020, 0x4c554d41, 1, 0, 0, 0, 2, 3, 4])))
    #expect(!NFSDiscovery.acceptsReply(packet([0x80000018, 0x12345678, 1, 0, 0, 0, 0])))
    #expect(!NFSDiscovery.acceptsReply(packet([0x80000018, 0x4c554d41, 1, 0, 0, 0, 1])))
    #expect(!NFSDiscovery.acceptsReply(Data([0, 1, 2])))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_BONJOUR_FIXTURE"] == "1")) @MainActor
func bonjourPublishesResolvesAndRemovesLiveService() async throws {
    let name = "Luma-Test-" + UUID().uuidString
    let service = NetService(domain: "local.", type: "_webdav._tcp.", name: name, port: 33999)
    service.setTXTRecord(NetService.data(fromTXTRecord: ["path": Data("/dav/".utf8)]))
    service.publish()
    let discovery = LocalShareDiscovery(); discovery.start()
    defer { discovery.stop(); service.stop() }
    var found = false
    for _ in 0..<60 {
        if discovery.shares.contains(where: { $0.name == name && $0.url.port == 33999 && $0.url.path == "/dav" }) { found = true; break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(found)
    service.stop()
    for _ in 0..<30 {
        if !discovery.shares.contains(where: { $0.name == name }) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(!discovery.shares.contains(where: { $0.name == name }))
    discovery.stop()
    let previous = discovery.shares
    try await Task.sleep(for: .milliseconds(200))
    #expect(discovery.shares == previous)
}

@Test func mountedFoldersDoNotDuplicateAnAdvertisedServer() {
    let server = DiscoveredShare(name: "NAS", kind: .smb, url: URL(string: "smb://nas.local:445/")!, alternateHosts: ["192.0.2.10"])
    let folder = DiscoveredShare(name: "Movies", kind: .smb, url: URL(string: "smb://192.0.2.10/Movies")!, mountedURL: URL(filePath: "/Volumes/Movies"))
    let another = DiscoveredShare(name: "Shows", kind: .smb, url: URL(string: "smb://nas.local/Shows")!, mountedURL: URL(filePath: "/Volumes/Shows"))
    #expect(DiscoveredShare.merged([folder, server, another]).count == 1)
    #expect(DiscoveredShare.merged([folder]).first == folder)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_LOCAL_DISCOVERY_HOST"] != nil))
func detectsJellyfinOnAnAdvertisedNAS() async throws {
    let host = try #require(ProcessInfo.processInfo.environment["LUMA_LOCAL_DISCOVERY_HOST"])
    let server = try #require(await JellyfinDiscovery.probe(host: host))
    #expect(server.kind == .jellyfin)
    #expect(server.url.host == host)
    #expect(await NFSDiscovery.probe(host: host))
}

@Test func jellyfinBroadcastAndPublicInfoShareIdentity() throws {
    let udp = try #require(DiscoveredShare.jellyfin(Data(#"{"Address":"http://192.0.2.10:8096","Name":"NAS","Id":"server-id"}"#.utf8)))
    let bonjourHost = DiscoveredShare(name: "NAS", kind: .jellyfin, url: URL(string: "http://nas.local:8096/")!, serverID: "server-id")
    #expect(DiscoveredShare.merged([udp, bonjourHost]).count == 1)
}
