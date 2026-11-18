import Foundation
import Observation
import Darwin

struct DiscoveredShare: Identifiable, Sendable, Equatable {
    let name: String
    let kind: SourceKind
    let url: URL
    var mountedURL: URL? = nil
    var alternateHosts: [String] = []
    var serverID: String? = nil
    var id: String {
        if let serverID, !serverID.isEmpty { return kind.rawValue + ":server:" + serverID }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.host = parts.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let defaults = ["http": 80, "https": 443, "smb": 445, "nfs": 2049]
        if parts.port == defaults[parts.scheme ?? ""] { parts.port = nil }
        if parts.path == "/" { parts.path = "" }
        return kind.rawValue + ":" + (parts.string ?? url.absoluteString)
    }
    static let serviceTypes = ["_smb._tcp.", "_nfs._tcp.", "_webdav._tcp.", "_webdavs._tcp.", "_webdav-ssl._tcp.", "_jellyfin._tcp."]
    static func bonjour(type: String, name: String, host: String, port: Int, txt: [String: Data]) -> Self? {
        guard (1...65535).contains(port), !host.isEmpty else { return nil }
        let kind: SourceKind
        let scheme: String
        switch type.lowercased() {
        case "_smb._tcp.": kind = .smb; scheme = "smb"
        case "_nfs._tcp.": kind = .nfs; scheme = "nfs"
        case "_webdav._tcp.": kind = .webdav; scheme = "http"
        case "_webdavs._tcp.", "_webdav-ssl._tcp.": kind = .webdav; scheme = "https"
        case "_jellyfin._tcp.": kind = .jellyfin; scheme = "http"
        default: return nil
        }
        var components = URLComponents(); components.scheme = scheme
        components.host = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")); components.port = port
        let advertisedPath = txt["path"].flatMap { String(data: $0, encoding: .utf8) } ?? "/"
        guard advertisedPath.hasPrefix("/"), !advertisedPath.hasPrefix("//"), !advertisedPath.contains("?"), !advertisedPath.contains("#"), !advertisedPath.split(separator: "/").contains("..") else { return nil }
        components.path = advertisedPath
        guard let url = components.url, url.host != nil else { return nil }
        return Self(name: name.isEmpty ? host : name, kind: kind, url: url)
    }
    static func jellyfin(_ data: Data) -> Self? {
        struct Reply: Decodable { let Address: String; let Name: String?; let Id: String? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let url = SourceKind.jellyfin.validatedURL(reply.Address) else { return nil }
        return Self(name: reply.Name.flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? "Jellyfin", kind: .jellyfin, url: url, serverID: reply.Id)
    }
    private static func hostKey(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .replacingOccurrences(of: "._smb._tcp.local", with: "")
            .replacingOccurrences(of: ".local", with: "")
    }
    static func merged(_ shares: [Self]) -> [Self] {
        let advertised = shares.filter { $0.mountedURL == nil }
        var unique: [String: Self] = [:]
        for share in shares {
            if share.mountedURL != nil, advertised.contains(where: { server in
                server.kind == share.kind && server.id != share.id &&
                ([server.url.host ?? "", server.name] + server.alternateHosts).contains { hostKey($0) == hostKey(share.url.host ?? "") }
            }) { continue }
            if unique[share.id] == nil || share.mountedURL != nil { unique[share.id] = share }
        }
        return unique.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
    static func numericHosts(_ addresses: [Data]) -> [String] {
        addresses.compactMap { data in
            guard data.count >= MemoryLayout<sockaddr>.size else { return nil }
            return data.withUnsafeBytes { bytes -> String? in
                guard let address = bytes.bindMemory(to: sockaddr.self).baseAddress else { return nil }
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(data.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: hostname)
            }
        }
    }

}

@MainActor @Observable final class LocalShareDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private var entries: [String: DiscoveredShare] = [:]
    var shares: [DiscoveredShare] { DiscoveredShare.merged(Array(entries.values)) }
    private(set) var searching = false
    private(set) var warning: String?
    @ObservationIgnored private var browsers: [NetServiceBrowser] = []
    @ObservationIgnored private var services: [String: NetService] = [:]
    @ObservationIgnored private var serviceKeys: [ObjectIdentifier: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var mountedTask: Task<Void, Never>?
    @ObservationIgnored private var nfsTasks: [String: Task<Void, Never>] = [:]

    func start() {
        stop(); entries = [:]; warning = nil; searching = true
        let generation = self.generation
        for type in DiscoveredShare.serviceTypes {
            let browser = NetServiceBrowser(); browser.delegate = self
            browsers.append(browser); browser.searchForServices(ofType: type, inDomain: "local.")
        }
        mountedTask = Task {
            let volumes = await MountedShareScanner.scan()
            guard self.generation == generation, !Task.isCancelled else { return }
            for share in volumes { entries["mounted:" + share.id] = share }
        }
        task = Task {
            async let jellyfin = try? JellyfinDiscovery.discover()
            async let dlna = try? DLNAClient.discover()
            async let settling: Void = Task.sleep(for: .seconds(5))
            let servers = await jellyfin ?? []
            guard self.generation == generation, !Task.isCancelled else { return }
            for share in servers { entries["jellyfin:" + share.id] = share }
            let devices = await dlna ?? []
            guard self.generation == generation, !Task.isCancelled else { return }
            for url in devices {
                let share = DiscoveredShare(name: url.host ?? "DLNA", kind: .dlna, url: url)
                entries["dlna:" + share.id] = share
            }
            _ = try? await settling
            guard self.generation == generation, !Task.isCancelled else { return }
            searching = false; task = nil
        }
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; mountedTask?.cancel(); mountedTask = nil
        for browser in browsers { browser.delegate = nil; browser.stop() }; browsers = []
        for service in services.values { service.delegate = nil; service.stop() }; services = [:]; serviceKeys = [:]
        for task in nfsTasks.values { task.cancel() }; nfsTasks = [:]
        searching = false
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browsers.contains(where: { $0 === browser }) else { return }
        let key = service.domain + service.type + service.name
        if let old = services[key] { serviceKeys[ObjectIdentifier(old)] = nil; old.stop() }; services[key] = service; serviceKeys[ObjectIdentifier(service)] = key
        service.delegate = self; service.resolve(withTimeout: 4)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let key = serviceKeys[ObjectIdentifier(sender)], services[key] === sender, let host = sender.hostName else { return }
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        if var share = DiscoveredShare.bonjour(type: sender.type, name: sender.name, host: host, port: sender.port, txt: txt) {
            share.alternateHosts = DiscoveredShare.numericHosts(sender.addresses ?? [])
            entries[key] = share
            if [.smb, .webdav].contains(share.kind), let host = share.url.host, nfsTasks[host] == nil, nfsTasks.count < 64 {
                let generation = self.generation
                nfsTasks[host] = Task {
                    async let nfs = NFSDiscovery.probe(host: host)
                    async let jellyfin = JellyfinDiscovery.probe(host: host)
                    if let server = await jellyfin, self.generation == generation, !Task.isCancelled { entries["jellyfin:" + server.id] = server }
                    let found = await nfs
                    guard found, self.generation == generation, !Task.isCancelled else { return }
                    var components = URLComponents(); components.scheme = "nfs"; components.host = host; components.path = "/"
                    if let url = components.url { entries["nfs:" + host] = DiscoveredShare(name: share.name, kind: .nfs, url: url) }
                }
            }
        }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browsers.contains(where: { $0 === browser }) else { return }
        let key = service.domain + service.type + service.name
        if let old = services.removeValue(forKey: key) { serviceKeys[ObjectIdentifier(old)] = nil; old.stop() }
        entries[key] = nil
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browsers.contains(where: { $0 === browser }) else { return }
        warning = "无法浏览局域网共享，请检查网络连接及系统设置中的 Velun 本地网络权限。"
    }
}

enum MountedShareScanner {
    @concurrent static func scan() async -> [DiscoveredShare] {
        let keys: Set<URLResourceKey> = [.volumeURLForRemountingKey, .volumeNameKey, .volumeIsLocalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { volume in
            guard let values = try? volume.resourceValues(forKeys: keys), let remount = values.volumeURLForRemounting,
                  let share = discovered(volume: volume, remount: remount, name: values.volumeName ?? volume.lastPathComponent) else { return nil }
            return share
        }
    }
    static func discovered(volume: URL, remount: URL, name: String) -> DiscoveredShare? {
        let kind: SourceKind
        switch remount.scheme?.lowercased() {
        case "smb", "cifs": kind = .smb
        case "nfs": kind = .nfs
        case "http", "https", "webdav", "webdavs": kind = .webdav
        default: return nil
        }
        guard var parts = URLComponents(url: remount, resolvingAgainstBaseURL: false), parts.host != nil else { return nil }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        if parts.scheme == "cifs" { parts.scheme = "smb" }
        if parts.scheme == "webdav" { parts.scheme = "http" }
        if parts.scheme == "webdavs" { parts.scheme = "https" }
        guard let clean = parts.url else { return nil }
        return DiscoveredShare(name: name, kind: kind, url: clean, mountedURL: volume)
    }
}

enum JellyfinDiscovery {
    @concurrent static func probe(host: String, port: Int = 8096) async -> DiscoveredShare? {
        var components = URLComponents(); components.scheme = "http"; components.host = host; components.port = port; components.path = "/System/Info/Public"
        guard let url = components.url else { return nil }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 1.5; config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config, delegate: DiscoveryRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= 32_768 else { return nil }
            var data = Data()
            for try await byte in bytes { if data.count >= 32_768 { return nil }; data.append(byte) }
            struct Info: Decodable { let ProductName: String; let ServerName: String; let Id: String? }
            let info = try JSONDecoder().decode(Info.self, from: data)
            guard info.ProductName.lowercased().contains("jellyfin") else { return nil }
            components.path = "/"
            guard let base = components.url else { return nil }
            return DiscoveredShare(name: info.ServerName, kind: .jellyfin, url: base, serverID: info.Id)
        } catch { return nil }
    }
    @concurrent static func discover(address: String = "255.255.255.255", port: UInt16 = 7359) async throws -> [DiscoveredShare] {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw SourceWorker.failure("无法创建服务器发现连接。") }
        defer { Darwin.close(descriptor) }
        var broadcast: Int32 = 1; _ = setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET); target.sin_port = port.bigEndian; target.sin_addr.s_addr = inet_addr(address)
        let message = Data("who is JellyfinServer?".utf8)
        let sent = message.withUnsafeBytes { bytes in withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        guard sent >= 0 else { throw SourceWorker.failure("无法发送服务器发现请求。") }
        let deadline = ContinuousClock.now + .seconds(2)
        var found: [DiscoveredShare] = [], buffer = [UInt8](repeating: 0, count: 16_384)
        while ContinuousClock.now < deadline && found.count < 128 {
            try Task.checkCancellation()
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count > 0, let share = DiscoveredShare.jellyfin(Data(buffer.prefix(count))) { found.append(share) }
        }
        return DiscoveredShare.merged(found)
    }
}

private final class DiscoveryRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
