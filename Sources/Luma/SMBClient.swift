import Foundation

struct SMBFolder: Identifiable, Sendable {
    let name: String
    let url: URL
    var id: String { url.absoluteString }
}

enum SMBClient {
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
    static func browse(_ url: URL, credentials: SourceCredentials) async throws -> [SMBFolder] {
        guard endpoint(url.absoluteString) != nil else { throw SourceWorker.failure("SMB 地址无效。") }
        let (config, remote) = try await RcloneTool.configuration(kind: .smb, url: url, credentials: credentials)
        let folder = FileManager.default.temporaryDirectory.appending(path: "Luma-SMB-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "rclone.conf")
        FileManager.default.createFile(atPath: file.path, contents: Data(config.utf8), attributes: [.posixPermissions: 0o600])
        let data: Data
        do {
            data = try await RcloneTool.run(["lsjson", remote, "--config", file.path, "--dirs-only", "--no-mimetype", "--no-modtime", "--contimeout", "8s", "--timeout", "15s", "--retries", "1", "--low-level-retries", "1"])
        } catch is CancellationError { throw CancellationError() }
        catch { throw SourceWorker.failure("无法读取 SMB 共享。请检查服务器地址、用户名、密码及文件夹访问权限。") }
        struct Entry: Decodable { let Name: String; let IsDir: Bool }
        return try JSONDecoder().decode([Entry].self, from: data).filter {
            $0.IsDir && !$0.Name.isEmpty && $0.Name != "." && $0.Name != ".." && !$0.Name.contains("/") && !$0.Name.contains("\\") && !$0.Name.contains("\0")
        }.map { SMBFolder(name: $0.Name, url: url.appending(component: $0.Name)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
