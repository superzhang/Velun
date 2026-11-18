import Foundation
import NetFS
import Observation

struct LibrarySource: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var url: URL
    var lastScan: Date?
    var connectionKind: SourceKind?
    var directSMB: Bool?
    var connectionRevision: UUID?
    var kind: SourceKind { connectionKind ?? (isSMB ? .smb : .nfs) }
    var protocolTitle: String { url.isFileURL ? "文件夹" : kind.title }
    var isRemote: Bool { directSMB == true || (connectionKind.map { !$0.mounted } ?? false) }
    var isSMB: Bool { url.scheme == "smb" }
    static func smbURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "smb", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !url.pathComponents.filter({ $0 != "/" }).isEmpty,
              !url.pathComponents.contains("..") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = "smb"
        return components.url
    }
}
struct ScannedFile: Sendable { let url: URL; let relativePath: String; var remotePath: String? = nil; var displayTitle: String? = nil; var localFile: Bool? = nil }
struct ScanResult: Sendable { let files: [ScannedFile]; let unreadable: Int }

enum SourceWorker {
    static func localVolume(_ input: URL) -> Bool {
        guard input.isFileURL else { return false }
        var url = input
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        return (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? false
    }
    @concurrent static func sourceLocality(_ sources: [LibrarySource]) async -> [UUID: Bool] {
        var result: [UUID: Bool] = [:]
        for source in sources {
            if !source.url.isFileURL { result[source.id] = false }
            else if FileManager.default.fileExists(atPath: source.url.path) { result[source.id] = localVolume(source.url) }
        }
        return result
    }
    @concurrent static func mount(_ url: URL) async throws -> URL {
        if url.scheme == "nfs" {
            var mounts: Unmanaged<CFArray>?
            let code = NetFSMountURLSync(url as CFURL, nil, nil, nil, nil, nil, &mounts)
            guard code == 0, let paths = mounts?.takeRetainedValue() as? [String], let path = paths.first else { throw failure("NFS 连接失败（\(code)）。请确认服务器导出路径和本机访问权限。") }
            return URL(filePath: path)
        }
        guard let valid = LibrarySource.smbURL(url.absoluteString) else { throw failure("请输入 smb://主机/共享文件夹，可附带子目录。") }
        var parts = valid.pathComponents.filter { $0 != "/" }
        let share = parts.removeFirst()
        var components = URLComponents(url: valid, resolvingAgainstBaseURL: false)!
        components.path = "/" + share
        var mounts: Unmanaged<CFArray>?
        let code = NetFSMountURLSync(components.url! as CFURL, nil, nil, nil, nil, nil, &mounts)
        guard code == 0 else {
            if code == -128 { throw failure("已取消 NAS 登录。") }
            throw failure("SMB 连接失败（\(code)）。请检查 NAS 地址、共享名称、网络和系统登录窗口中的账号权限。")
        }
        guard let paths = mounts?.takeRetainedValue() as? [String], let path = paths.first else { throw failure("系统未返回 SMB 挂载位置。") }
        var root = URL(filePath: path)
        for part in parts { root.append(path: part) }
        return root
    }
    @concurrent static func scan(_ root: URL) async throws -> ScanResult {
        try scanDirectory(root)
    }
    static func scanDirectory(_ input: URL) throws -> ScanResult {
        let root = input.resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path) else { throw failure("目录不可访问，请先连接 NAS 并确认读取权限。") }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        var unreadable = 0
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in unreadable += 1; return true }) else { throw failure("无法读取目录。") }
        let extensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "m2ts", "mpg", "mpeg", "webm"]
        let local = localVolume(root)
        var files: [ScannedFile] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            files.append(ScannedFile(url: url, relativePath: relative, localFile: local))
        }
        return ScanResult(files: files.sorted { $0.relativePath < $1.relativePath }, unreadable: unreadable)
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "NAS", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@MainActor @Observable final class SourcesStore {
    private(set) var sources: [LibrarySource] = []
    var busy = false
    var status = ""
    var error: String?
    private var task: Task<Void, Never>?
    private let file: URL
    private var loadFailed = false
    init(file: URL? = nil) {
        self.file = file ?? URL.applicationSupportDirectory.appending(path: "Luma/sources.json")
        if FileManager.default.fileExists(atPath: self.file.path) {
            do { sources = try JSONDecoder().decode([LibrarySource].self, from: Data(contentsOf: self.file)) }
            catch { self.error = "来源列表读取失败，原文件已保留。"; loadFailed = true }
        }
    }
    func add(name: String, url: URL, kind: SourceKind? = nil, directSMB: Bool? = nil, id: UUID = UUID()) -> LibrarySource {
        if let source = sources.first(where: { $0.url == url && $0.connectionKind == kind && $0.directSMB == directSMB }) { return source }
        let source = LibrarySource(id: id, name: name.isEmpty ? (url.host ?? url.lastPathComponent) : name, url: url, connectionKind: kind, directSMB: directSMB)
        sources.append(source); save(); return source
    }
    func update(_ source: LibrarySource, name: String, url: URL, kind: SourceKind, directSMB: Bool? = nil) -> LibrarySource {
        var value = source; value.name = name.isEmpty ? (url.host ?? source.name) : name; value.url = url; value.connectionKind = kind; value.lastScan = nil; value.directSMB = directSMB; value.connectionRevision = UUID()
        if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index] = value; save() }
        return value
    }
    func remove(_ source: LibrarySource) { SourceSecrets.remove(source.id); Task { await RemoteSources.shared.stop(source.id) }; sources.removeAll { $0.id == source.id }; save() }
    func scan(_ source: LibrarySource, library: Library, metadata: MetadataStore) {
        guard !busy else { return }
        busy = true; error = nil
        status = source.isSMB && !source.isRemote ? "正在连接 \(source.name)…请在系统窗口中完成登录。" : "正在扫描目录…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                status = "正在扫描 \(source.name)…"
                let result: ScanResult
                if source.isRemote {
                    var credentials = try await SourceSecrets.read(source.id)
                    if source.kind.mediaServer {
                        let connected = try await MediaServerClient.scan(source, credentials: credentials)
                        if connected.credentials.token != credentials.token || connected.credentials.userID != credentials.userID,
                           let i = sources.firstIndex(where: { $0.id == source.id }) { sources[i].connectionRevision = UUID() }
                        credentials = connected.credentials
                        try SourceSecrets.save(credentials, id: source.id)
                        result = connected.result
                    } else if source.kind == .dlna { result = try await DLNAClient.scan(source) }
                    else { result = try await RemoteSources.shared.scan(source, credentials: credentials) }
                } else {
                    let root = source.url.isFileURL ? source.url : try await SourceWorker.mount(source.url)
                    result = try await SourceWorker.scan(root)
                }
                try Task.checkCancellation()
                library.importSource(source.id, files: result.files)
                if let i = sources.firstIndex(where: { $0.id == source.id }) { sources[i].lastScan = Date(); save() }
                status = "扫描完成：\(result.files.count) 个视频" + (result.unreadable > 0 ? "，\(result.unreadable) 个目录无法读取。" : "。")
                if metadata.autoMatch { metadata.matchMissing(library) }
            } catch is CancellationError { status = "已停止扫描。" }
            catch { self.error = error.localizedDescription; status = "" }
        }
    }
    func cancel() { task?.cancel(); status = "正在停止…系统登录窗口可点取消。" }
    private func save() {
        guard !loadFailed else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(sources).write(to: file, options: .atomic)
        } catch { self.error = "来源保存失败：\(error.localizedDescription)" }
    }
}
