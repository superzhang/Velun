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
    var excludedFromLibrary: Bool?
    var smbBrowseOnly: Bool?
    var smbFolderFavorite: Bool?
    var smbCredentialOwnerID: UUID?
    var credentialID: UUID { smbCredentialOwnerID ?? id }
    var isMediaSource: Bool { smbBrowseOnly != true && smbFolderFavorite != false }
    var kind: SourceKind { connectionKind ?? (isSMB ? .smb : .nfs) }
    var protocolTitle: String { url.isFileURL ? "文件夹" : kind.title }
    var isRemote: Bool { directSMB == true || (connectionKind.map { !$0.mounted } ?? false) }
    var isFileShare: Bool { !kind.mediaServer && kind != .dlna }
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
struct ScannedFile: Sendable { let url: URL; let relativePath: String; var remotePath: String? = nil; var displayTitle: String? = nil; var localFile: Bool? = nil; var sidecars: MediaSidecars? = nil; var nfo: NFOCandidates? = nil; var localMetadata: LocalMetadata? = nil; var nfoReadFailed = false }
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
        let scan = try scanDirectory(root)
        return ScanResult(files: try await NFOReader.enrich(scan.files), unreadable: scan.unreadable)
    }
    static func scanDirectory(_ input: URL) throws -> ScanResult {
        let root = input.resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path) else { throw failure("目录不可访问，请先连接 NAS 并确认读取权限。") }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        var unreadable = 0
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in unreadable += 1; return true }) else { throw failure("无法读取目录。") }
        let local = localVolume(root)
        var files: [ScannedFile] = []
        var sidecars: [URL: SidecarIndex] = [:]
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let isVideo = SidecarIndex.videoExtensions.contains(url.pathExtension.lowercased())
            guard isVideo || SidecarIndex.supports(url) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { unreadable += 1; continue }
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            sidecars[url.deletingLastPathComponent(), default: SidecarIndex()].insert(url)
            guard isVideo else { continue }
            let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            files.append(ScannedFile(url: url, relativePath: relative, localFile: local))
        }
        SidecarIndex.attach(sidecars, to: &files)
        return ScanResult(files: files.sorted { $0.relativePath < $1.relativePath }, unreadable: unreadable)
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "NAS", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

enum SourceScanIssue: Equatable {
    case notMounted
    case failed(String)
    case incomplete(Int)

    var title: String {
        switch self {
        case .notMounted: "共享未挂载"
        case .failed: "扫描失败"
        case .incomplete: "扫描不完整"
        }
    }

    var detail: String {
        switch self {
        case .notMounted: "请连接共享后重新扫描。"
        case .failed(let message): message
        case .incomplete(let count): "有 \(count) 项无法读取。"
        }
    }
}

@MainActor @Observable final class SourcesStore {
    private var records: [LibrarySource] = []
    var sources: [LibrarySource] { records.filter(\.isMediaSource) }
    var starredSMBFolders: [LibrarySource] { sources.filter { $0.directSMB == true } }
    var smbBrowserSources: [LibrarySource] {
        var byServer: [URL: LibrarySource] = [:]
        for record in records where record.directSMB == true {
            let server = SMBClient.serverURL(record.url)
            if byServer[server] == nil || record.smbBrowseOnly == true { byServer[server] = record }
        }
        return byServer.values.sorted { smbBrowserName($0).localizedStandardCompare(smbBrowserName($1)) == .orderedAscending }
    }
    private(set) var scanIssues: [UUID: SourceScanIssue] = [:]
    var excludedSourceIDs: Set<UUID> {
        Set(records.lazy.filter { !$0.isMediaSource || $0.excludedFromLibrary == true }.map(\.id))
    }
    var librarySources: [LibrarySource] { sources.filter { $0.excludedFromLibrary != true } }
    var networkFileShares: [LibrarySource] { sources.filter { !$0.url.isFileURL && $0.isFileShare } }
    var networkIssueCount: Int { networkFileShares.filter { scanIssues[$0.id] != nil }.count }
    var busy = false
    var status = ""
    var error: String?
    private var task: Task<Void, Never>?
    private var pendingFavoriteScans: Set<UUID> = []
    private let file: URL
    private var loadFailed = false
    init(file: URL? = nil) {
        self.file = file ?? URL.applicationSupportDirectory.appending(path: "Luma/sources.json")
        if FileManager.default.fileExists(atPath: self.file.path) {
            do { records = try JSONDecoder().decode([LibrarySource].self, from: Data(contentsOf: self.file)) }
            catch { self.error = "来源列表读取失败，原文件已保留。"; loadFailed = true }
        }
    }
    func add(name: String, url: URL, kind: SourceKind? = nil, directSMB: Bool? = nil, id: UUID = UUID()) -> LibrarySource {
        if let source = sources.first(where: { $0.url == url && $0.connectionKind == kind && $0.directSMB == directSMB }) { return source }
        let source = LibrarySource(id: id, name: name.isEmpty ? (url.host ?? url.lastPathComponent) : name, url: url, connectionKind: kind, directSMB: directSMB)
        records.append(source); save(); return source
    }
    func smbBrowserName(_ source: LibrarySource) -> String {
        if source.smbBrowseOnly == true { return source.name }
        let host = source.url.host ?? source.name
        if let port = SMBClient.serverURL(source.url).port { return "\(host):\(port)" }
        return host
    }

    func smbBrowserSource(at url: URL) -> LibrarySource? {
        records.first { $0.smbBrowseOnly == true && SMBClient.serverURL($0.url) == SMBClient.serverURL(url) }
    }

    func addSMBBrowser(name: String, url: URL, id: UUID) -> LibrarySource {
        let server = SMBClient.serverURL(url)
        let source = LibrarySource(id: id, name: name.isEmpty ? server.host ?? server.absoluteString : name,
                                   url: server, connectionKind: .smb, directSMB: true, smbBrowseOnly: true)
        records.append(source)
        save()
        return source
    }

    func smbFolder(at url: URL) -> LibrarySource? {
        records.first { $0.directSMB == true && $0.smbBrowseOnly != true && SMBClient.sameFolder($0.url, url) }
    }

    func hasLinkedSMBFolders(_ source: LibrarySource) -> Bool {
        records.contains { $0.smbCredentialOwnerID == source.id }
    }

    func addSMBFavorite(at url: URL, id: UUID, credentialOwnerID: UUID?, library: Library, metadata: MetadataStore) {
        let source = LibrarySource(id: id, name: url.lastPathComponent, url: url, connectionKind: .smb,
                                   directSMB: true, smbCredentialOwnerID: credentialOwnerID)
        records.append(source)
        save()
        scanFavorite(source, library: library, metadata: metadata)
    }

    func setSMBFolderFavorite(_ favorite: Bool, for id: UUID, library: Library, metadata: MetadataStore) {
        guard let index = records.firstIndex(where: { $0.id == id && $0.directSMB == true && $0.smbBrowseOnly != true }),
              records[index].isMediaSource != favorite else { return }
        records[index].smbFolderFavorite = favorite ? nil : false
        save()
        if favorite {
            scanFavorite(records[index], library: library, metadata: metadata)
        } else {
            pendingFavoriteScans.remove(id)
            scanIssues[id] = nil
        }
    }

    private func scanFavorite(_ source: LibrarySource, library: Library, metadata: MetadataStore) {
        if busy { pendingFavoriteScans.insert(source.id) }
        else { scan(source, library: library, metadata: metadata) }
    }

    func update(_ source: LibrarySource, name: String, url: URL, kind: SourceKind, directSMB: Bool? = nil) -> LibrarySource {
        let index = records.firstIndex(where: { $0.id == source.id })
        var value = index.map { records[$0] } ?? source
        value.name = name.isEmpty ? (url.host ?? source.name) : name; value.url = url; value.connectionKind = kind; value.lastScan = nil; value.directSMB = directSMB; value.connectionRevision = UUID()
        value.smbCredentialOwnerID = nil
        if let index {
            records[index] = value
            if value.smbBrowseOnly == true {
                for linked in records.indices where records[linked].smbCredentialOwnerID == source.id {
                    records[linked].connectionRevision = value.connectionRevision
                }
            }
            scanIssues[source.id] = nil
            save()
        }
        return value
    }
    func remove(_ source: LibrarySource) {
        let credentialID = records.first { $0.id == source.id }?.credentialID ?? source.id
        Task { await RemoteSources.shared.stop(source.id) }
        records.removeAll { $0.id == source.id }
        if !records.contains(where: { $0.credentialID == credentialID }) { SourceSecrets.remove(credentialID) }
        pendingFavoriteScans.remove(source.id)
        scanIssues[source.id] = nil
        save()
    }
    func scan(_ source: LibrarySource, library: Library, metadata: MetadataStore) {
        beginScan([source], library: library, metadata: metadata, automatic: false)
    }

    func setLibraryInclusion(_ included: Bool, for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id && $0.isMediaSource }),
              (records[index].excludedFromLibrary != true) != included else { return }
        records[index].excludedFromLibrary = included ? nil : true
        save()
    }

    func refreshLibrary(library: Library, metadata: MetadataStore) {
        let included = librarySources
        guard !included.isEmpty else { return }
        beginScan(included, library: library, metadata: metadata, automatic: false)
    }

    @discardableResult
    func refreshNetwork(library: Library, metadata: MetadataStore) -> Bool {
        let network = networkFileShares
        guard !network.isEmpty, !busy else { return false }
        beginScan(network, library: library, metadata: metadata, automatic: true)
        return true
    }

    private func beginScan(_ candidates: [LibrarySource], library: Library, metadata: MetadataStore, automatic: Bool) {
        guard !busy else { return }
        busy = true; error = nil
        status = "正在扫描目录…"
        task = Task {
            defer {
                busy = false; task = nil
                let queued = records.filter { $0.isMediaSource && pendingFavoriteScans.contains($0.id) }
                pendingFavoriteScans.removeAll()
                if !queued.isEmpty { beginScan(queued, library: library, metadata: metadata, automatic: false) }
            }
            let mounts = automatic && candidates.contains(where: { !$0.isRemote }) ? await MountedShareScanner.scan() : []
            var completed = 0
            var imported = 0
            var issues: [String] = []
            do {
                for source in candidates {
                    do {
                        try Task.checkCancellation()
                        guard currentIndex(for: source) != nil else { continue }
                        status = "正在扫描 \(source.name)…"
                        let result: ScanResult
                        var updatedCredentials: SourceCredentials?
                        if source.isRemote {
                            if source.kind == .dlna {
                                result = try await DLNAClient.scan(source)
                            } else {
                                let credentials = try await SourceSecrets.read(source.credentialID)
                                if source.kind.mediaServer {
                                    let connected = try await MediaServerClient.scan(source, credentials: credentials)
                                    if connected.credentials.token != credentials.token || connected.credentials.userID != credentials.userID {
                                        updatedCredentials = connected.credentials
                                    }
                                    result = connected.result
                                } else {
                                    result = try await RemoteSources.shared.scan(source, credentials: credentials)
                                }
                            }
                        } else {
                            let root: URL
                            if source.url.isFileURL {
                                root = source.url
                            } else if automatic {
                                guard let mounted = mounts.compactMap({ MountedShareScanner.directory(for: source.url, on: $0) }).first else {
                                    scanIssues[source.id] = .notMounted
                                    issues.append("\(source.name) 未挂载")
                                    continue
                                }
                                root = mounted
                            } else {
                                status = "正在连接 \(source.name)…如系统提示，请完成登录。"
                                root = try await SourceWorker.mount(source.url)
                            }
                            result = try await SourceWorker.scan(root)
                        }
                        try Task.checkCancellation()
                        guard let i = currentIndex(for: source) else { continue }
                        if let updatedCredentials {
                            try SourceSecrets.save(updatedCredentials, id: source.id)
                            records[i].connectionRevision = UUID()
                        }
                        library.importSource(source.id, files: result.files, complete: source.isFileShare && result.unreadable == 0)
                        if result.unreadable == 0 {
                            scanIssues[source.id] = nil
                            records[i].lastScan = Date()
                            save()
                        } else {
                            scanIssues[source.id] = .incomplete(result.unreadable)
                            issues.append("\(source.name) 有 \(result.unreadable) 项无法读取")
                        }
                        completed += 1
                        imported += result.files.count
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        guard currentIndex(for: source) != nil else { continue }
                        scanIssues[source.id] = .failed(error.localizedDescription)
                        issues.append("\(source.name)（\(error.localizedDescription)）")
                    }
                }
                if completed > 0 {
                    status = "扫描完成，共 \(imported) 个视频。"
                    if metadata.autoMatch { metadata.matchMissing(library) }
                } else {
                    status = ""
                }
                if !issues.isEmpty { self.error = issues.joined(separator: "；") }
            } catch {
                status = "已停止扫描。"
            }
        }
    }

    private func currentIndex(for source: LibrarySource) -> Int? {
        records.firstIndex { $0.id == source.id && $0.isMediaSource && $0.url == source.url && $0.connectionRevision == source.connectionRevision }
    }

    func cancel() { pendingFavoriteScans.removeAll(); task?.cancel(); status = "正在停止…系统登录窗口可点取消。" }
    private func save() {
        guard !loadFailed else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: file, options: .atomic)
        } catch { self.error = "来源保存失败：\(error.localizedDescription)" }
    }
}
