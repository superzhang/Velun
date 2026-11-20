import Foundation

struct FileDirectoryEntry: Identifiable, Sendable {
    let name: String
    let url: URL
    var isDirectory = true
    var id: String { url.absoluteString }
}

enum SMBClient {
    static func serverURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.host = components.host?.lowercased()
        if components.port == 445 { components.port = nil }
        components.path = ""
        return components.url ?? url
    }

    static func pathComponents(_ url: URL) -> [Substring] {
        url.path(percentEncoded: false).split(separator: "/")
    }

    static func playbackHistoryURL(_ url: URL) -> URL {
        pathComponents(url).reduce(serverURL(url)) { $0.appending(component: String($1)) }
    }

    static func sameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        serverURL(lhs) == serverURL(rhs) && pathComponents(lhs) == pathComponents(rhs)
    }

    /// Both a server and a share URL are valid during connection setup.
    static func endpoint(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.contains("://") ? trimmed : "smb://" + trimmed
        guard !trimmed.isEmpty, !value.contains("\\"),
              var parts = URLComponents(string: value), parts.scheme?.lowercased() == "smb",
              let host = parts.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              !parts.path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              !parts.path.contains("\0") else { return nil }
        parts.scheme = "smb"
        return parts.url
    }
    static func browse(_ url: URL, credentials: SourceCredentials) async throws -> [FileDirectoryEntry] {
        guard endpoint(url.absoluteString) != nil else { throw SourceWorker.failure("SMB 地址无效。") }
        do {
            return try await RcloneTool.listDirectory(.smb, at: url, credentials: credentials)
        } catch is CancellationError { throw CancellationError() }
        catch { throw SourceWorker.failure("无法读取 SMB 共享。请检查服务器地址、用户名、密码及文件夹访问权限。") }
    }
}

extension RcloneTool {
    static func listDirectory(_ kind: SourceKind, at url: URL, path: String = "", credentials: SourceCredentials) async throws -> [FileDirectoryEntry] {
        guard path.isEmpty || RemoteSources.safePath(path) else { throw SourceWorker.failure("无效的远程目录路径。") }
        let (config, base) = try await RcloneTool.configuration(kind: kind, url: url, credentials: credentials)
        let prefix = base.hasSuffix(":") || base.hasSuffix("/") ? base : base + "/"
        let remote = path.isEmpty ? base : prefix + path
        let folder = FileManager.default.temporaryDirectory.appending(path: "Velun-Directory-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "rclone.conf")
        FileManager.default.createFile(atPath: file.path, contents: Data(config.utf8), attributes: [.posixPermissions: 0o600])
        let data = try await RcloneTool.run(["lsjson", remote, "--config", file.path, "--no-mimetype", "--no-modtime", "--contimeout", "8s", "--timeout", "15s", "--retries", "1", "--low-level-retries", "1"])
        struct Entry: Decodable { let Name: String; let IsDir: Bool }
        return try JSONDecoder().decode([Entry].self, from: data).filter {
            !$0.Name.isEmpty && $0.Name != "." && $0.Name != ".." && !$0.Name.contains("/") && !$0.Name.contains("\\") && !$0.Name.contains("\0")
                && ($0.IsDir || SidecarIndex.remoteVideoExtensions.contains(URL(filePath: $0.Name).pathExtension.lowercased()))
        }.map { FileDirectoryEntry(name: $0.Name, url: url.appending(component: $0.Name), isDirectory: $0.IsDir) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
