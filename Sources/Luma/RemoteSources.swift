import Foundation
import Security
import Darwin

enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case smb, nfs, webdav, alist, ftp, ftps, ftpes, sftp, dlna, plex, jellyfin, emby
    var id: String { rawValue }
    var title: String { switch self {
    case .smb: "SMB"; case .nfs: "NFS"; case .webdav: "WebDAV"; case .alist: "Alist / OpenList（WebDAV）"
    case .ftp: "FTP"; case .ftps: "FTPS（隐式 TLS）"; case .ftpes: "FTPES（显式 TLS）"; case .sftp: "SFTP"
    case .dlna: "UPnP / DLNA"; case .plex: "Plex"; case .jellyfin: "Jellyfin"; case .emby: "Emby"
    } }
    var mounted: Bool { self == .smb || self == .nfs }
    var mediaServer: Bool { [.plex, .jellyfin, .emby].contains(self) }
    var placeholder: String { switch self {
    case .smb: "smb://nas.local/Movies"; case .nfs: "nfs://nas.local/export/Movies"
    case .ftp, .ftpes: "ftp://nas.local/Movies"; case .ftps: "ftps://nas.local/Movies"; case .sftp: "sftp://nas.local/Movies"
    case .alist: "https://alist.example.com/dav/"; case .dlna: "http://nas.local:8200/rootDesc.xml"
    case .plex: "http://nas.local:32400"; case .jellyfin, .emby: "http://nas.local:8096"
    default: "https://nas.local/webdav/"
    } }
    func validatedURL(_ text: String) -> URL? {
        if self == .smb { return SMBClient.endpoint(text) }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, (self == .dlna || url.query == nil), url.fragment == nil,
              !url.pathComponents.contains("..") else { return nil }
        let allowed: [String] = switch self {
        case .smb: ["smb"]; case .nfs: ["nfs"]; case .ftp, .ftpes: ["ftp"]; case .ftps: ["ftps"]; case .sftp: ["sftp"]
        default: ["http", "https"]
        }
        guard allowed.contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

struct SourceCredentials: Codable, Sendable {
    var username = ""
    var password = ""
    var token = ""
    var userID = ""
    var knownHosts = ""
    func edited(from previous: Self?, endpointChanged: Bool = false) -> Self {
        guard let previous else { return self }
        var result = self
        let changedLogin = endpointChanged || username != previous.username || password != previous.password
        if changedLogin && token == previous.token { result.token = "" }
        if changedLogin || token != previous.token { result.userID = "" }
        return result
    }
}

enum SourceSecrets {
    static func save(_ credentials: SourceCredentials, id: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.luma.sources", kSecAttrAccount as String: id.uuidString]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var values = query; values[kSecValueData as String] = data; values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(values as CFDictionary, nil)
            guard added == errSecSuccess else { throw SourceWorker.failure("无法保存来源凭据（\(added)）。") }
        } else if status != errSecSuccess { throw SourceWorker.failure("无法更新来源凭据（\(status)）。") }
    }
    @concurrent static func read(_ id: UUID) async throws -> SourceCredentials {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.luma.sources", kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return SourceCredentials() }
        guard status == errSecSuccess, let data = result as? Data else { throw SourceWorker.failure("来源凭据暂不可用（\(status)），请解锁钥匙串或重新添加来源。") }
        return try JSONDecoder().decode(SourceCredentials.self, from: data)
    }
    static func remove(_ id: UUID) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.luma.sources", kSecAttrAccount as String: id.uuidString] as CFDictionary)
    }
}

enum RcloneTool {
    static var executable: URL {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/rclone")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : URL(filePath: "/opt/homebrew/bin/rclone")
    }
    @concurrent static func run(_ arguments: [String], input: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let pipe = Pipe(); process.standardInput = pipe
        return try await withTaskCancellationHandler {
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            try Task.checkCancellation()
            if let input { try pipe.fileHandleForWriting.write(contentsOf: input) }
            try pipe.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw SourceWorker.failure("远程连接失败（\(process.terminationStatus)），请检查地址、登录凭据和服务器协议。") }
            return data
        } onCancel: { if process.isRunning { process.terminate() } }
    }
    static func configuration(kind: SourceKind, url: URL, credentials: SourceCredentials) async throws -> (String, String) {
        guard ![credentials.username, credentials.password, credentials.token, credentials.knownHosts].contains(where: { $0.contains("\n") || $0.contains("\r") }) else { throw SourceWorker.failure("配置字段不能包含换行。") }
        let obscured = try await run(["obscure", "-"], input: Data(credentials.password.utf8))
        let pass = String(decoding: obscured, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var config = "[luma]\n"
        switch kind {
        case .smb:
            let parts = credentials.username.split(separator: "\\", maxSplits: 1, omittingEmptySubsequences: false)
            let user = parts.last.map(String.init) ?? ""
            let domain = parts.count == 2 ? String(parts[0]) : "WORKGROUP"
            config += "type = smb\nhost = \(url.host!)\nport = \(url.port ?? 445)\nuser = \(user.isEmpty ? "guest" : user)\npass = \(pass)\ndomain = \(domain)\nhide_special_share = true\n"
            return (config, "luma:" + url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        case .webdav, .alist:
            config += "type = webdav\nurl = \(url.absoluteString)\nvendor = other\nuser = \(credentials.username)\npass = \(pass)\n"
            return (config, "luma:")
        case .ftp, .ftps, .ftpes:
            config += "type = ftp\nhost = \(url.host!)\nport = \(url.port ?? (kind == .ftps ? 990 : 21))\nuser = \(credentials.username.isEmpty ? "anonymous" : credentials.username)\npass = \(pass)\ntls = \(kind == .ftps)\nexplicit_tls = \(kind == .ftpes)\n"
            return (config, "luma:" + url.path)
        case .sftp:
            guard FileManager.default.isReadableFile(atPath: credentials.knownHosts) else { throw SourceWorker.failure("SFTP 需要已校验服务器的 known_hosts 文件，请先提供该文件。") }
            config += "type = sftp\nhost = \(url.host!)\nport = \(url.port ?? 22)\nuser = \(credentials.username)\npass = \(pass)\nknown_hosts_file = \(credentials.knownHosts)\n"
            return (config, "luma:" + url.path)
        case .plex, .jellyfin, .emby:
            let (header, headerValue) = MediaServerClient.header(kind: kind, token: credentials.token)
            let escaped = headerValue.replacingOccurrences(of: "\"", with: "\"\"")
            config += "type = http\nurl = \(url.absoluteString.hasSuffix("/") ? url.absoluteString : url.absoluteString + "/")\nheaders = \"\(header)\",\"\(escaped)\"\n"
            return (config, "luma:")
        default: throw SourceWorker.failure("此协议不使用远程传输桥。")
        }
    }
}

actor RemoteSources {
    static let shared = RemoteSources()
    private struct SessionKey: Hashable { let source: UUID; let url: URL; let kind: String; let revision: UUID? }
    private struct Session { let process: Process; let folder: URL; let base: URL }
    private var sessions: [SessionKey: Session] = [:]
    private var mediaBridges: [SessionKey: (HTTPMediaBridge, URL)] = [:]
    private var starting: [SessionKey: (UUID, Task<URL, Error>)] = [:]
    private let credentialsProvider: @Sendable (UUID) async throws -> SourceCredentials
    init(credentialsProvider: @escaping @Sendable (UUID) async throws -> SourceCredentials = { try await SourceSecrets.read($0) }) {
        self.credentialsProvider = credentialsProvider
    }
    static func virtualURL(source: UUID, path: String) -> URL {
        var result = URL(string: "luma-source://\(source.uuidString)")!
        for component in path.split(separator: "/") { result.append(path: String(component)) }
        return result
    }
    func browsedSMBURL(_ file: URL, connection: LibrarySource) async throws -> URL {
        let components = SMBClient.pathComponents(file)
        guard components.count >= 2, let share = components.first,
              SMBClient.serverURL(file) == SMBClient.serverURL(connection.url) else {
            throw SourceWorker.failure("此视频不在当前 SMB 共享中。")
        }
        var source = connection
        source.url = SMBClient.serverURL(file).appending(component: String(share))
        return try await playbackURL(source: source, path: components.dropFirst().joined(separator: "/"))
    }
    func scan(_ source: LibrarySource, credentials: SourceCredentials) async throws -> ScanResult {
        if source.kind == .smb && LibrarySource.smbURL(source.url.absoluteString) == nil { throw SourceWorker.failure("请先选择一个 SMB 共享文件夹。") }
        let (config, remote) = try await RcloneTool.configuration(kind: source.kind, url: source.url, credentials: credentials)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "rclone.conf"); try Data(config.utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let data = try await RcloneTool.run(["lsjson", remote, "--config", file.path, "--recursive", "--files-only", "--no-mimetype", "--no-modtime", "--contimeout", "15s", "--timeout", "45s", "--retries", "1"])
        struct Entry: Decodable { let Path: String; let IsDir: Bool }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        var files: [ScannedFile] = []
        var sidecars: [URL: SidecarIndex] = [:]
        for entry in entries where !entry.IsDir && Self.safePath(entry.Path) {
            try Task.checkCancellation()
            let url = Self.virtualURL(source: source.id, path: entry.Path)
            if SidecarIndex.remoteVideoExtensions.contains(url.pathExtension.lowercased()) {
                files.append(ScannedFile(url: url, relativePath: entry.Path))
            } else if !SidecarIndex.supports(url) { continue }
            sidecars[url.deletingLastPathComponent(), default: SidecarIndex()].insert(url)
        }
        SidecarIndex.attach(sidecars, to: &files)
        let enriched = try await NFOReader.enrich(files) { url in
            try await self.playbackURL(source: source, path: url.pathComponents.dropFirst().joined(separator: "/"))
        }
        return ScanResult(files: enriched, unreadable: 0)
    }
    func playbackURL(source: LibrarySource, path: String) async throws -> URL {
        let key = SessionKey(source: source.id, url: source.url, kind: source.kind.rawValue, revision: source.connectionRevision)
        guard Self.safePath(path) else { throw SourceWorker.failure("无效的远程文件路径。") }
        if let bridge = mediaBridges[key] { return append(path, to: bridge.1) }
        if let session = sessions[key], session.process.isRunning { return append(path, to: session.base) }
        let task: Task<URL, Error>
        if let pending = starting[key] { task = pending.1 }
        else {
            let ticket = UUID()
            task = Task { try await self.start(source: source, key: key, ticket: ticket) }
            starting[key] = (ticket, task)
        }
        let base = try await task.value
        try Task.checkCancellation()
        return append(path, to: base)
    }
    private func start(source: LibrarySource, key: SessionKey, ticket: UUID) async throws -> URL {
        defer { if starting[key]?.0 == ticket { starting[key] = nil } }
        let credentials = try await credentialsProvider(source.credentialID)
        try Task.checkCancellation()
        if source.kind.mediaServer {
            let bridge = try HTTPMediaBridge(source: source, credentials: credentials)
            do {
                let base = try await bridge.start()
                try Task.checkCancellation()
                guard starting[key]?.0 == ticket else { throw CancellationError() }
                mediaBridges[key] = (bridge, base)
                return base
            } catch { bridge.stop(); throw error }
        }
        let (config, remote) = try await RcloneTool.configuration(kind: source.kind, url: source.url, credentials: credentials)
        let folder = try temporaryFolder(); let file = folder.appending(path: "rclone.conf")
        try Data(config.utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let port = try Self.availablePort(); let prefix = UUID().uuidString
        let base = URL(string: "http://127.0.0.1:\(port)/\(prefix)/")!
        let process = Process(); process.executableURL = RcloneTool.executable
        process.arguments = ["serve", "http", remote, "--config", file.path, "--addr", "127.0.0.1:\(port)", "--baseurl", prefix, "--read-only", "--vfs-cache-mode", "off", "--contimeout", "15s", "--timeout", "45s"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        var ready = false
        var retained = false
        defer { if !retained { if process.isRunning { process.terminate() }; try? FileManager.default.removeItem(at: folder) } }
        try process.run()
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard process.isRunning else { throw SourceWorker.failure("远程播放桥启动失败，请检查来源配置。") }
            var request = URLRequest(url: base); request.httpMethod = "HEAD"; request.timeoutInterval = 0.2
            if (try? await URLSession.shared.data(for: request)) != nil { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { throw SourceWorker.failure("远程播放桥启动超时。") }
        try Task.checkCancellation()
        guard starting[key]?.0 == ticket else { throw CancellationError() }
        sessions[key] = Session(process: process, folder: folder, base: base)
        retained = true
        return base
    }
    private func stop(_ key: SessionKey) {
        starting.removeValue(forKey: key)?.1.cancel()
        mediaBridges.removeValue(forKey: key)?.0.stop()
        if let session = sessions.removeValue(forKey: key) {
            if session.process.isRunning { session.process.terminate(); session.process.waitUntilExit() }
            try? FileManager.default.removeItem(at: session.folder)
        }
    }
    func stop(_ id: UUID) {
        let keys = Set(sessions.keys).union(starting.keys).union(mediaBridges.keys).filter { $0.source == id }
        for key in keys { stop(key) }
    }
    func stopAll() async {
        let tasks = starting.values.map { $0.1 }
        for key in Set(sessions.keys).union(starting.keys).union(mediaBridges.keys) { stop(key) }
        for task in tasks { _ = try? await task.value }
    }
    private func append(_ path: String, to base: URL) -> URL { path.split(separator: "/").reduce(base) { $0.appending(path: String($1)) } }
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Luma-Source-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return folder
    }
    static func safePath(_ path: String) -> Bool { !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && !path.contains("\0") }
    private static func availablePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0); guard socket >= 0 else { throw SourceWorker.failure("无法创建本地播放端口。") }; defer { Darwin.close(socket) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw SourceWorker.failure("无法绑定本地播放端口。") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &size) } }
        return UInt16(bigEndian: address.sin_port)
    }
}

enum RemoteSourceResolver {
    static func resolve(_ media: Media) async throws -> URL {
        guard media.url.scheme == "luma-source", let id = media.sourceID, let path = media.remotePath ?? media.relativePath else { return media.url }
        return try await resolve(id: id, path: path)
    }

    static func resolveSidecar(_ url: URL) async throws -> URL {
        if url.isFileURL { return url }
        guard url.scheme == "luma-source", let id = url.host.flatMap(UUID.init(uuidString:)), SidecarIndex.supports(url) else {
            throw SourceWorker.failure("无效的附属文件地址。")
        }
        return try await resolve(id: id, path: url.pathComponents.dropFirst().joined(separator: "/"))
    }

    private static func resolve(id: UUID, path: String) async throws -> URL {
        let file = URL.applicationSupportDirectory.appending(path: "Luma/sources.json")
        let sources = try JSONDecoder().decode([LibrarySource].self, from: Data(contentsOf: file))
        guard let source = sources.first(where: { $0.id == id }) else { throw SourceWorker.failure("来源配置已移除，请重新添加该来源。") }
        return try await RemoteSources.shared.playbackURL(source: source, path: path)
    }
}
