import SwiftUI
import AppKit

enum SourcePanelOpening: String, Identifiable {
    case add, savedShares, directURL, downloads, imported
    var id: Self { self }
}

private enum SourceRoute: Hashable {
    case add, directURL, downloads, imported, connection(SourceKind), smbBrowse, saved(UUID)
}

struct SourcesView: View {
    @Bindable var store: SourcesStore
    let library: Library
    let metadata: MetadataStore
    let play: (Media) -> Void
    var opening = SourcePanelOpening.add
    var initialSourceID: UUID?
    var filter = ""
    var backToFiles: (() -> Void)?
    var playQueue: (([Media], Bool, Bool) -> Void)?
    @AppStorage("files.listMode") private var filesInList = false
    @AppStorage("files.descendingNames") private var descendingFileNames = false
    private let downloads = OfflineDownloads.shared
    @Environment(\.dismiss) private var dismiss
    @State private var route = SourceRoute.add
    @State private var name = ""
    @State private var address = ""
    @State private var kind = SourceKind.smb
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var userID = ""
    @State private var originalCredentials: SourceCredentials?
    @State private var knownHosts = URL.homeDirectory.appending(path: ".ssh/known_hosts").path
    @State private var inputError: String?
    @State private var editing: LibrarySource?
    @State private var discovery = LocalShareDiscovery()
    @State private var loadingCredentials = false
    @State private var editGeneration = UUID()
    @State private var smbURL: URL?
    @State private var smbRequestedURL: URL?
    @State private var smbConnection: LibrarySource?
    @State private var smbCredentials: SourceCredentials?
    @State private var smbFolders: [FileDirectoryEntry] = []
    @State private var selectedSMBEntries: [String: String] = [:]
    @State private var smbTask: Task<Void, Never>?
    @State private var smbLoading = false
    @State private var preparingPlayback = false
    @State private var playbackTask: Task<Void, Never>?
    @State private var removal: LibrarySource?
    @State private var availableStorage: String?
    @FocusState private var addressFocused: Bool
    private var embedded: Bool { backToFiles != nil }
    private var smbDirectoryKey: String? {
        smbURL.map { SMBClient.pathComponents($0).joined(separator: "/") }
    }
    private var smbParent: URL? {
        guard let current = smbRequestedURL ?? smbURL, !SMBClient.pathComponents(current).isEmpty else { return nil }
        if embedded, let root = smbConnection?.url, SMBClient.sameFolder(current, root) { return nil }
        return current.deletingLastPathComponent()
    }
    private var selectedSource: LibrarySource? {
        if case .saved(let id) = route { return store.sources.first { $0.id == id } }; return nil
    }
    private var title: String {
        switch route {
        case .add: "添加共享"
        case .directURL: "通过直接 URL"
        case .downloads: "下载"
        case .imported: "本地视频与链接"
        case .connection: (editing == nil ? "添加 " : "编辑 ") + kind.title
        case .smbBrowse:
            if embedded, let name = (smbURL ?? smbRequestedURL)?.lastPathComponent, !name.isEmpty { name }
            else { smbConnection.map(store.smbBrowserName) ?? "浏览 SMB 共享" }
        case .saved: selectedSource?.name ?? "共享"
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            if !embedded {
                sidebar
                Divider().opacity(0.4)
            }
            VStack(spacing: 0) {
                if let backToFiles {
                    HStack(spacing: 12) {
                        Button {
                            if let smbParent, smbCredentials != nil { browseSMB(smbParent) }
                            else { backToFiles() }
                        } label: {
                            Image(systemName: "chevron.left").frame(width: 32, height: 32).contentShape(Rectangle())
                        }.buttonStyle(SidebarButtonStyle()).accessibilityLabel("返回")
                        Text(title).font(.headline).lineLimit(1).accessibilityAddTraits(.isHeader)
                        Spacer()
                        FileLayoutButton(listMode: $filesInList)
                        Menu {
                            if let directory = smbDirectoryKey, let selected = selectedSMBEntries[directory],
                               let entry = smbFolders.first(where: { $0.name == selected }),
                               filter.isEmpty || entry.name.localizedStandardContains(filter) {
                                Button("打开所选项目") { openSMBEntry(entry) }.disabled(smbLoading || preparingPlayback)
                                Divider()
                            }
                            Picker("按名称排序", selection: $descendingFileNames) {
                                Text("升序").tag(false)
                                Text("降序").tag(true)
                            }
                            if let url = smbURL {
                                Divider()
                                if playQueue != nil, smbFolders.contains(where: { !$0.isDirectory }) {
                                    Button("播放当前目录") { playSMBDirectory() }.disabled(smbLoading || preparingPlayback)
                                    Button("循环播放") { playSMBDirectory(loop: true) }.disabled(smbLoading || preparingPlayback)
                                    Button("随机播放") { playSMBDirectory(shuffled: true) }.disabled(smbLoading || preparingPlayback)
                                    Divider()
                                }
                                Button(store.smbFolder(at: url)?.isMediaSource == true ? "取消收藏此文件夹" : "收藏此文件夹") {
                                    toggleSMBFolder(url)
                                }.disabled(smbLoading || smbCredentials == nil)
                            }
                        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("目录更多操作")
                    }.padding(.horizontal, 24).frame(height: 56)
                } else {
                    panelHeader
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch route {
                        case .add: catalog
                        case .directURL: directURLPage
                        case .downloads:
                            OfflineDownloadsPage(downloads: downloads) { url in
                                openMedia(Media(url: url, title: url.lastPathComponent))
                            }
                        case .imported: importedPage
                        case .connection: connectionPage
                        case .smbBrowse: smbBrowser
                        case .saved:
                            if let source = selectedSource {
                                SavedSourceFileBrowser(source: source, library: library, filter: filter, play: openMedia, download: downloadMedia,
                                                       listMode: !embedded || filesInList, descendingNames: embedded && descendingFileNames,
                                                       usesSelection: embedded)
                                    .id(source.id)
                                if !embedded {
                                    DisclosureGroup("共享设置") { savedPage(source).padding(.top, 12) }
                                }
                            } else {
                                ContentUnavailableView("找不到此来源", systemImage: "folder.badge.questionmark")
                            }
                        }
                        if route != .smbBrowse, let inputError { sourceError(inputError) }
                    }.padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: embedded ? .infinity : 720).frame(maxWidth: .infinity)
                }.id(route)
                if store.busy || !store.status.isEmpty || store.error != nil { statusBar }
            }.frame(maxWidth: .infinity).background(LumaTheme.canvas)
        }.frame(width: embedded ? nil : 1000, height: embedded ? nil : 700)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LumaTheme.sidebar).tint(LumaTheme.navigationAccent)
            .confirmationDialog("移除“\(removal?.name ?? "")”的来源配置？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                Button("移除来源", role: .destructive) { if let removal { store.remove(removal) }; removal = nil; reset(); route = .add }
            } message: { Text("原文件、海报和本机观看进度会保留。") }
            .task {
                openInitialPage()
                if !embedded, let capacity = try? URL.applicationSupportDirectory
                    .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
                    availableStorage = ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
                }
            }
            .onChange(of: route, initial: true) { _, value in
                if value == .add && !embedded { discovery.start() }
                else { discovery.stop() }
            }
            .onDisappear { discovery.stop(); reset() }
    }
    private var panelHeader: some View {
        ZStack {
            Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 130).accessibilityAddTraits(.isHeader)
            HStack {
                if case .connection = route {
                    Button { reset(); route = .add } label: {
                        Label("添加共享", systemImage: "chevron.left")
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                if route == .smbBrowse, let connection = smbConnection {
                    Menu {
                        Button("编辑连接…") { edit(connection) }.disabled(store.busy || loadingCredentials)
                        if connection.smbBrowseOnly == true {
                            Button("移除共享连接…", role: .destructive) { removal = connection }.disabled(store.busy)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("管理共享")
                }
            }
        }.padding(.horizontal, 28).frame(height: 60)
    }

    private func openInitialPage() {
        if let initialSourceID {
            if let source = store.sources.first(where: { $0.id == initialSourceID }) { openSavedFolder(source) }
            else { route = .saved(initialSourceID) }
            return
        }
        switch opening {
        case .add: break
        case .savedShares:
            if let source = store.smbBrowserSources.first { openSMB(source) }
            else if let source = store.sources.first { openSavedFolder(source) }
        case .directURL: route = .directURL
        case .downloads: route = .downloads
        case .imported: route = .imported
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).frame(width: 36, height: 36)
                    .background(LumaTheme.surface.opacity(0.7), in: Circle()).overlay(Circle().stroke(.secondary.opacity(0.15)))
            }.buttonStyle(.plain).accessibilityLabel("关闭共享管理").keyboardShortcut(.cancelAction).padding(18)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    navigation("通过直接 URL", icon: "globe", selected: route == .directURL) { reset(); route = .directURL }
                    let activeDownloads = downloads.transferringCount
                    navigation(activeDownloads == 0 ? "下载" : "下载（\(activeDownloads)）",
                               icon: "arrow.down.circle", selected: route == .downloads) { reset(); route = .downloads }
                    sidebarSection("已保存的共享")
                    navigation("添加…", icon: "plus", selected: route == .add || isConnecting) { reset(); route = .add }
                    ForEach(store.smbBrowserSources + store.sources.filter { $0.directSMB != true }) { source in
                        let isSMB = source.directSMB == true
                        let selected = isSMB
                            ? route == .smbBrowse && smbConnection.map { SMBClient.serverURL($0.url) } == SMBClient.serverURL(source.url)
                            : route == .saved(source.id)
                        let title = isSMB ? store.smbBrowserName(source) : source.name
                        HStack(spacing: 0) {
                            navigation(title, icon: source.url.isFileURL ? "folder" : "externaldrive", selected: selected, highlight: false) {
                                if isSMB { openSMB(source) }
                                else { reset(); route = .saved(source.id) }
                            }
                            if !source.url.isFileURL {
                                Button { edit(source) } label: { Image(systemName: "pencil").frame(width: 40, height: 44).contentShape(Rectangle()) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("编辑 \(title)").disabled(store.busy || loadingCredentials)
                            }
                        }.background(selected ? LumaTheme.ink.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(.horizontal, 12)
            }
            if let availableStorage {
                Label("\(availableStorage) 可用", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary).padding(16)
            }
        }.frame(width: 258).background(LumaTheme.sidebar)
    }
    private func sidebarSection(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
    private var isConnecting: Bool { if case .connection = route { true } else { false } }
    private func navigation(_ text: String, icon: String, selected: Bool, highlight: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) { Image(systemName: icon).font(.system(size: 17)).foregroundStyle(LumaTheme.navigationAccent).frame(width: 22); Text(text).lineLimit(1); Spacer(minLength: 0) }
                .font(.system(size: 14, weight: selected ? .semibold : .regular)).padding(.horizontal, 13).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).background(selected && highlight ? LumaTheme.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8)).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var catalog: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionTitle("可用的共享")
                    Spacer()
                    Button { discovery.start() } label: { if discovery.searching { ProgressView().controlSize(.small) } else { Label("刷新", systemImage: "arrow.clockwise") } }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(discovery.searching || store.busy)
                }
                if discovery.shares.isEmpty { caption(discovery.searching ? "正在自动查找局域网共享…" : "未发现共享，可刷新或通过下方协议手动添加。") }
                else {
                    surface {
                        ForEach(discovery.shares) { share in
                            choice(share.name, subtitle: share.mountedURL != nil ? "已连接" : (share.kind == .webdav ? share.url.scheme?.uppercased() : nil), badge: share.kind.badge, color: share.kind.badgeColor) { select(share) }
                                .accessibilityLabel("\(share.kind.title)，\(share.name)，\(share.url.scheme ?? "")").disabled(store.busy)
                            if share.id != discovery.shares.last?.id { separator }
                        }
                    }
                }
                if let warning = discovery.warning { caption(warning) }

            }
            group("本地共享") {
                choice("添加本地文件夹", symbol: "desktopcomputer", color: .green) { chooseFolder() }.disabled(store.busy)
                separator
                choice("导入视频文件", symbol: "film", color: .blue) { Importer.files(library) }
            }
            group("网络共享") {
                ForEach([SourceKind.smb, .ftp, .nfs, .webdav, .alist, .sftp, .ftps, .ftpes]) { kind in
                    protocolChoice(kind)
                    if kind != .ftpes { separator }
                }
            }
            group("媒体服务器") {
                ForEach([SourceKind.plex, .jellyfin, .emby, .dlna]) { kind in
                    protocolChoice(kind)
                    if kind != .dlna { separator }
                }
            }
        }
    }
    private func protocolChoice(_ kind: SourceKind) -> some View {
        choice("添加 \(kind.title)", badge: kind.badge, color: kind.badgeColor) { begin(kind) }.disabled(store.busy)
    }
    private var connectionPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("连接信息") {
                field("名称") { TextField("例如：家里的 NAS", text: $name) }; separator
                field("地址") { TextField(kind == .smb ? "nas.local 或 smb://nas.local/Movies" : kind.placeholder, text: $address).focused($addressFocused).onSubmit { connect() } }
                if kind != .nfs && kind != .dlna {
                    if kind != .plex {
                        separator; field("用户名") { TextField("账号", text: $username) }
                        separator; field("密码") { SecureField("密码", text: $password) }
                    }
                    if kind.mediaServer { separator; field(kind == .plex ? "访问令牌" : "令牌（可选）") { SecureField(kind == .plex ? "X-Plex-Token" : "访问令牌", text: $token) } }
                }
            }
            if kind == .sftp {
                group("服务器校验") { field("主机密钥") { TextField("known_hosts 文件路径", text: $knownHosts); Button("选择…") { chooseKnownHosts() } } }
                caption("选择已确认服务器密钥的 known_hosts 文件，SFTP 会校验连接的服务器身份。")
            }
            if kind == .nfs { caption("使用 macOS 系统连接与权限，地址需包含服务器导出路径。") }
            else if kind == .smb { caption("填写 NAS 账号密码后浏览共享文件夹。域账号可使用 域名\\用户名；访客访问请填写 guest。凭据保存在 macOS 钥匙串。") }
            else if kind == .dlna { caption("填写设备描述 XML 地址，也可返回“添加共享”选择自动发现的服务器。") }
            else { caption("账号密码和令牌保存在 macOS 钥匙串。") }
            if kind == .alist { caption("请填写 Alist / OpenList 的 WebDAV 地址，通常以 /dav/ 结尾。") }
            if kind.mediaServer { caption("扫描电影与剧集并播放原始文件，暂不与服务器同步观看进度。") }
            HStack {
                Spacer()
                Button(kind == .smb ? "连接并浏览" : (editing == nil ? "连接并扫描" : "更新并扫描")) { connect() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.busy || loadingCredentials || smbLoading)
                if smbLoading { ProgressView().controlSize(.small) }
            }
        }.textFieldStyle(.plain)
    }
    private var smbBrowser: some View {
        let current = smbURL ?? smbRequestedURL
        let visibleEntries = smbFolders.filter { filter.isEmpty || $0.name.localizedStandardContains(filter) }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return FileNameOrder.compare($0.name, $1.name, descending: embedded && descendingFileNames)
        }
        let artwork = (embedded && !filesInList && !visibleEntries.isEmpty)
            ? FileDirectoryArtwork.index(groups: library.groupedItems, directories: indexedSMBPaths())
            : [:]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if !embedded, let smbParent {
                    Button {
                        browseSMB(smbParent)
                    } label: {
                        Label("上一级", systemImage: "chevron.left")
                    }.disabled(smbLoading || smbCredentials == nil)
                }
                let path = current.map { SMBClient.pathComponents($0).joined(separator: " / ") } ?? ""
                Text(path.isEmpty ? "共享目录" : path)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if smbLoading { ProgressView().controlSize(.small).accessibilityLabel("正在读取目录") }
                else if let url = smbRequestedURL {
                    Button { browseSMB(url, reading: smbCredentials == nil ? smbConnection : nil) } label: {
                        Label(inputError == nil ? "刷新" : "重试", systemImage: "arrow.clockwise")
                    }
                }
            }.controlSize(.regular)

            if let inputError { sourceError(inputError) }

            if !embedded, let url = smbURL, !SMBClient.pathComponents(url).isEmpty {
                HStack {
                    Label {
                        Text("当前文件夹").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "folder").foregroundStyle(LumaTheme.navigationAccent)
                    }
                    Spacer()
                    folderStar(url, name: url.lastPathComponent)
                }.padding(.leading, 14)
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            }

            if let connection = smbConnection, inputError != nil, smbURL == nil,
               connection.smbBrowseOnly != true, smbCredentials != nil {
                Button("打开已保存目录") { browseSMB(connection.url) }
            }

            if visibleEntries.isEmpty, !smbLoading, inputError == nil {
                Text(filter.isEmpty ? "此目录没有文件夹或视频。" : "没有匹配的文件。")
                    .foregroundStyle(.secondary).padding(.vertical, 18)
            }

            if embedded && !filesInList {
                FileBrowserGrid {
                    ForEach(visibleEntries) { entry in
                        if entry.isDirectory {
                            FileBrowserCard(title: entry.name, icon: "folder",
                                            favorite: store.smbFolder(at: entry.url)?.isMediaSource == true,
                                            activation: smbActivation(for: entry), portrait: true, artwork: artwork[entry.name]) {
                                selectSMBEntry(entry)
                            }.contextMenu {
                                Button("打开") { openSMBEntry(entry) }
                                folderBookmarkAction(entry.url)
                            }
                        } else {
                            FileBrowserCard(title: entry.name, icon: "play.rectangle", video: true, activation: smbActivation(for: entry),
                                            portrait: true, artwork: artwork[entry.name]) {
                                selectSMBEntry(entry)
                            }.contextMenu {
                                Button("播放") { openSMBEntry(entry) }
                                Button("下载") { downloadSMB(entry) }
                            }.disabled(preparingPlayback)
                        }
                    }
                }.disabled(smbLoading)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visibleEntries) { entry in
                        if entry.isDirectory { smbFolderRow(entry) }
                        else { smbVideoRow(entry) }
                        Divider().padding(.leading, 16)
                    }
                }.background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func smbFolderRow(_ folder: FileDirectoryEntry) -> some View {
        HStack(spacing: 0) {
            FileBrowserRow(title: folder.name, icon: "folder", opensFolder: true,
                           action: { if embedded { selectSMBEntry(folder) } else { browseSMB(folder.url) } },
                           activation: embedded ? smbActivation(for: folder) : nil)
                .disabled(smbLoading)
            if !embedded { folderStar(folder.url, name: folder.name) }
        }.contextMenu {
            if embedded {
                Button("打开") { openSMBEntry(folder) }
                folderBookmarkAction(folder.url)
            }
        }
    }

    private func folderBookmarkAction(_ url: URL) -> some View {
        Button(store.smbFolder(at: url)?.isMediaSource == true ? "取消收藏" : "收藏文件夹") {
            toggleSMBFolder(url)
        }.disabled(smbLoading || smbCredentials == nil)
    }

    private func smbVideoRow(_ entry: FileDirectoryEntry) -> some View {
        FileVideoRow(title: entry.name, media: nil, action: { openSMBEntry(entry) },
                     download: smbConnection == nil ? nil : { downloadSMB(entry) },
                     select: embedded ? { selectSMBEntry(entry) } : nil,
                     selected: embedded && isSMBEntrySelected(entry))
            .disabled(smbLoading || preparingPlayback)
    }

    private func smbActivation(for entry: FileDirectoryEntry) -> FileItemActivation {
        FileItemActivation(isSelected: isSMBEntrySelected(entry)) { openSMBEntry(entry) }
    }

    private func isSMBEntrySelected(_ entry: FileDirectoryEntry) -> Bool {
        smbDirectoryKey.flatMap { selectedSMBEntries[$0] } == entry.name
    }

    private func selectSMBEntry(_ entry: FileDirectoryEntry) {
        if let smbDirectoryKey { selectedSMBEntries[smbDirectoryKey] = entry.name }
    }

    private func openSMBEntry(_ entry: FileDirectoryEntry) {
        guard !smbLoading, !preparingPlayback else { return }
        if embedded { selectSMBEntry(entry) }
        if entry.isDirectory { browseSMB(entry.url) }
        else { playSMB(entry) }
    }

    private func folderStar(_ url: URL, name: String) -> some View {
        let source = store.smbFolder(at: url)
        let starred = source?.isMediaSource == true
        return Button { toggleSMBFolder(url) } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LumaTheme.navigationAccent)
                .frame(width: 52, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(starred ? "取消收藏 \(name)" : "收藏 \(name)")
            .help(starred ? "从收藏目录中移除" : "收藏此目录并扫描视频")
            .disabled(smbLoading || smbCredentials == nil)
            .contextMenu {
                if let source, starred {
                    Button("重新扫描") { store.scan(source, library: library, metadata: metadata) }.disabled(store.busy)
                    Button("编辑连接…") { edit(source) }.disabled(store.busy || loadingCredentials)
                    Button("移除来源…", role: .destructive) { removal = source }.disabled(store.busy)
                }
            }
    }
    private var directURLPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("网络视频") {
                field("地址") {
                    TextField("https://example.com/video.mkv", text: $address).focused($addressFocused)
                        .onSubmit { directURLAction(.play) }
                }
            }
            HStack {
                Button("保存链接") { directURLAction(.save) }.disabled(address.isEmpty)
                Button("下载") { directURLAction(.download) }.disabled(address.isEmpty)
                Spacer()
                Button("播放") { directURLAction(.play) }.buttonStyle(.borderedProminent)
                    .disabled(address.isEmpty)
            }.controlSize(.large)
        }.textFieldStyle(.plain)
    }

    private var importedPage: some View {
        let items = library.items.filter {
            $0.sourceID == nil && (filter.isEmpty || $0.title.localizedStandardContains(filter) || $0.url.lastPathComponent.localizedStandardContains(filter))
        }.sorted { $0.added > $1.added }
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                Button { Importer.files(library) } label: { Label("导入视频…", systemImage: "plus") }
            }
            if items.isEmpty {
                ContentUnavailableView("没有文件", systemImage: "film", description: Text("导入本地视频，或保存网络视频链接。"))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        FileVideoRow(title: item.url.isFileURL ? item.url.lastPathComponent : item.title, media: item,
                                     action: { openMedia(item) }, download: OfflineDownloads.supports(item.url) ? { downloadMedia(item) } : nil)
                        Divider().padding(.leading, 16)
                    }
                }.background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    private func savedPage(_ source: LibrarySource) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            group("共享信息") {
                info("名称", source.name); separator
                info("连接方式", source.protocolTitle); separator
                info("地址", source.url.isFileURL ? source.url.path : source.url.absoluteString)
                if let date = source.lastScan { separator; info("最近扫描", date.formatted(date: .abbreviated, time: .shortened)) }
            }
            group("管理共享") {
                choice("重新扫描", symbol: "arrow.clockwise", color: .blue) { store.scan(source, library: library, metadata: metadata) }.disabled(store.busy)
                if !source.url.isFileURL { separator; choice("编辑连接", symbol: "pencil", color: .orange) { edit(source) }.disabled(store.busy || loadingCredentials) }
            }
            caption("重新扫描会保留海报、收藏与观看进度。")
            Button("移除来源…", role: .destructive) { removal = source }.buttonStyle(.plain).disabled(store.busy)
        }
    }
    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            if store.busy { HStack { ProgressView().controlSize(.small); Text(store.status).lineLimit(2); Spacer(); Button("停止") { store.cancel() } } }
            else if !store.status.isEmpty { Text(store.status).foregroundStyle(.secondary) }
            if let error = store.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }.font(.system(size: 12)).padding(18).frame(maxWidth: .infinity, alignment: .leading).background(LumaTheme.surface)
    }
    private func sectionTitle(_ text: String) -> some View { Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 17) }
    private func sourceError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(LumaTheme.warningText)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func caption(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3).padding(.horizontal, 17) }
    private func surface<Content: View>(@ViewBuilder content: () -> Content) -> some View { VStack(spacing: 0, content: content).background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 13)) }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 10) { sectionTitle(title); surface(content: content) } }
    private var separator: some View { Divider().opacity(0.5).padding(.leading, 60) }
    private func choice(_ title: String, subtitle: String? = nil, badge: String? = nil, symbol: String? = nil, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(color)
                    if let badge { Text(badge).font(.system(size: badge.count > 3 ? 8 : 10, weight: .heavy)).foregroundStyle(.white).minimumScaleFactor(0.7) }
                    else { Image(systemName: symbol ?? "folder").font(.system(size: 17, weight: .medium)).foregroundStyle(.white) }
                }.frame(width: 29, height: 29).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 14, weight: .medium)); if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) } }
                Spacer(minLength: 8); Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 17).padding(.vertical, 13).frame(minHeight: 56).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) { Text(title).font(.system(size: 13)).frame(width: 83, alignment: .leading); content().font(.system(size: 13)) }.padding(.horizontal, 17).frame(minHeight: 52)
    }
    private func info(_ title: String, _ value: String) -> some View { field(title) { Text(value).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.vertical, 12); Spacer(minLength: 0) } }
    private func reset() {
        smbTask?.cancel(); smbTask = nil; smbLoading = false
        playbackTask?.cancel(); playbackTask = nil; preparingPlayback = false
        smbURL = nil; smbRequestedURL = nil; smbFolders = []; selectedSMBEntries = [:]; smbConnection = nil; smbCredentials = nil
        name = ""; address = ""; username = ""; password = ""; token = ""; userID = ""
        originalCredentials = nil; editing = nil; inputError = nil; addressFocused = false
        editGeneration = UUID(); loadingCredentials = false
    }
    private func begin(_ kind: SourceKind) { reset(); self.kind = kind; route = .connection(kind) }
    private func connect() {
        guard !store.busy, !loadingCredentials, !smbLoading else { return }
        guard let url = kind.validatedURL(address) else { inputError = "请填写正确的 \(kind.title) 地址，账号密码不要写入 URL。"; return }
        if kind == .smb {
            if let editing, editing.smbBrowseOnly == true, store.hasLinkedSMBFolders(editing),
               SMBClient.serverURL(editing.url) != SMBClient.serverURL(url) {
                inputError = "已收藏的目录使用此地址。要连接另一台服务器，请添加新的共享。"
                return
            }
            if let editing, editing.smbBrowseOnly != true, LibrarySource.smbURL(url.absoluteString) == nil {
                inputError = "编辑已收藏的目录时，请填写包含共享目录的 SMB 地址。"
                return
            }
            browseSMB(url, savingConnection: true)
            return
        }
        if kind == .sftp && !FileManager.default.isReadableFile(atPath: knownHosts) { inputError = "请选择已校验服务器的 known_hosts 文件。"; return }
        if kind == .plex && token.isEmpty { inputError = "请填写 X-Plex-Token。"; return }
        inputError = nil
        let existing = editing ?? store.sources.first { $0.url == url && $0.kind == kind }
        let id = existing?.id ?? UUID()
        do {
            if kind != .nfs && kind != .dlna {
                var credentials = SourceCredentials(username: username, password: password, token: token, userID: userID, knownHosts: knownHosts)
                if kind.mediaServer { credentials = credentials.edited(from: originalCredentials, endpointChanged: editing.map { $0.url != url } ?? false) }
                try SourceSecrets.save(credentials, id: id)
            }
            let source = existing.map { store.update($0, name: name, url: url, kind: kind) } ?? store.add(name: name, url: url, kind: kind, id: id)
            reset(); route = .saved(source.id); store.scan(source, library: library, metadata: metadata)
        } catch { inputError = error.localizedDescription }
    }
    private func openSavedFolder(_ source: LibrarySource) {
        if source.directSMB == true { openSMB(source, at: source.url) }
        else { reset(); route = .saved(source.id) }
    }

    private func openSMB(_ source: LibrarySource, at location: URL? = nil) {
        reset()
        smbConnection = source
        route = .smbBrowse
        browseSMB(location ?? SMBClient.serverURL(source.url), reading: source)
    }

    private func browseSMB(_ url: URL, reading source: LibrarySource? = nil, savingConnection: Bool = false) {
        if preparingPlayback {
            playbackTask?.cancel()
            playbackTask = nil
            preparingPlayback = false
        }
        smbTask?.cancel()
        smbLoading = true; inputError = nil; smbRequestedURL = url
        let currentCredentials = savingConnection ? SourceCredentials(username: username, password: password) : smbCredentials
        let generation = UUID(); editGeneration = generation
        smbTask = Task {
            defer { if editGeneration == generation { smbLoading = false } }
            do {
                let credentials: SourceCredentials
                if let source { credentials = try await SourceSecrets.read(source.credentialID) }
                else if let currentCredentials { credentials = currentCredentials }
                else { throw SourceWorker.failure("请重新连接 SMB 共享。") }
                try Task.checkCancellation()
                guard editGeneration == generation else { return }
                if !savingConnection { smbCredentials = credentials }
                let folders = try await SMBClient.browse(url, credentials: credentials)
                try Task.checkCancellation()
                guard editGeneration == generation else { return }
                if savingConnection {
                    smbConnection = try saveSMBConnection(url, credentials: credentials)
                    username = ""; password = ""; originalCredentials = nil; editing = nil
                }
                smbCredentials = credentials
                smbURL = url; smbFolders = folders; route = .smbBrowse
            } catch is CancellationError {} catch {
                if editGeneration == generation { inputError = error.localizedDescription }
            }
        }
    }

    private func saveSMBConnection(_ url: URL, credentials: SourceCredentials) throws -> LibrarySource {
        let existingBrowser = store.smbBrowserSource(at: url)
        if let editing, editing.smbBrowseOnly == true, let existingBrowser, editing.id != existingBrowser.id {
            throw SourceWorker.failure("此服务器已有保存的连接，请从侧栏编辑该连接。")
        }
        if let editing, editing.smbBrowseOnly != true,
           let existing = store.smbFolder(at: url), existing.id != editing.id {
            throw SourceWorker.failure("此目录已经保存，请分别编辑两个目录的连接。")
        }
        let existing = editing ?? existingBrowser
        let id = existing?.id ?? UUID()
        try SourceSecrets.save(credentials, id: id)
        if let existing {
            let isServer = existing.smbBrowseOnly == true
            let updated = store.update(existing, name: name, url: isServer ? SMBClient.serverURL(url) : url, kind: .smb, directSMB: true)
            if !isServer, updated.isMediaSource { store.scan(updated, library: library, metadata: metadata) }
            return updated
        }
        return store.addSMBBrowser(name: name, url: url, id: id)
    }

    private func toggleSMBFolder(_ url: URL) {
        guard !smbLoading, let credentials = smbCredentials,
              LibrarySource.smbURL(url.absoluteString) != nil else { return }
        inputError = nil
        if let existing = store.smbFolder(at: url) {
            store.setSMBFolderFavorite(!existing.isMediaSource, for: existing.id, library: library, metadata: metadata)
            return
        }
        let owner = smbConnection.flatMap { $0.smbBrowseOnly == true ? $0.id : nil }
        let id = UUID()
        do {
            if owner == nil { try SourceSecrets.save(credentials, id: id) }
            store.addSMBFavorite(at: url, id: id, credentialOwnerID: owner, library: library, metadata: metadata)
        } catch { inputError = error.localizedDescription }
    }
    private func edit(_ source: LibrarySource) {
        guard !loadingCredentials, !store.busy else { return }
        smbTask?.cancel(); smbLoading = false
        loadingCredentials = true
        let generation = UUID(); editGeneration = generation
        Task {
            defer { if editGeneration == generation { loadingCredentials = false } }
            do {
                let credentials = try await SourceSecrets.read(source.credentialID)
                guard editGeneration == generation else { return }
                begin(source.kind); editing = source; name = source.name; address = source.url.absoluteString
                originalCredentials = credentials
                username = credentials.username; password = credentials.password; token = credentials.token; userID = credentials.userID
                if !credentials.knownHosts.isEmpty { knownHosts = credentials.knownHosts }
            } catch { if editGeneration == generation { inputError = error.localizedDescription } }
        }
    }
    private func select(_ share: DiscoveredShare) {
        if share.kind == .smb { begin(.smb); name = share.name; address = share.url.absoluteString; return }
        if let volume = share.mountedURL {
            let source = store.add(name: share.name, url: volume)
            reset(); route = .saved(source.id); store.scan(source, library: library, metadata: metadata)
        } else { begin(share.kind); name = share.name; address = share.url.absoluteString }
    }
    private enum DirectURLAction { case play, save, download }

    private func directURLAction(_ action: DirectURLAction) {
        guard let url = Media.streamURL(address) else {
            inputError = "请输入有效的 HTTP / HTTPS 视频地址。"
            return
        }
        let item = library.items.first { $0.url == url } ?? Media(url: url, title: url.lastPathComponent.isEmpty ? "网络视频" : url.lastPathComponent)
        switch action {
        case .play: openMedia(item)
        case .save:
            library.add([url])
            reset(); route = .imported
        case .download:
            guard OfflineDownloads.supports(url) else {
                inputError = "此链接是分段流，请使用视频文件直链下载。"
                return
            }
            downloadMedia(item)
            reset(); route = .downloads
        }
    }

    private func openMedia(_ media: Media) {
        play(media)
        if !embedded { dismiss() }
    }

    private func downloadMedia(_ media: Media) {
        downloads.start(name: media.title, key: media.url) { try await RemoteSourceResolver.resolve(media) }
    }

    private func playSMB(_ entry: FileDirectoryEntry) {
        guard let source = smbConnection else { return }
        if let media = indexedSMBDirectory()[entry.name] { openMedia(media); return }
        preparingPlayback = true
        inputError = nil
        playbackTask = Task {
            defer { if !Task.isCancelled { preparingPlayback = false } }
            do {
                let url = try await RemoteSources.shared.browsedSMBURL(entry.url, connection: source)
                try Task.checkCancellation()
                openMedia(Media(url: url, title: entry.name, directPlaybackURL: SMBClient.playbackHistoryURL(entry.url)))
            } catch is CancellationError {} catch {
                if !Task.isCancelled { inputError = error.localizedDescription }
            }
        }
    }

    private func downloadSMB(_ entry: FileDirectoryEntry) {
        guard let source = smbConnection else { return }
        downloads.start(name: entry.name, key: entry.url) {
            try await RemoteSources.shared.browsedSMBURL(entry.url, connection: source)
        }
    }

    private func playSMBDirectory(shuffled: Bool = false, loop: Bool = false) {
        guard let source = smbConnection, let playQueue, !smbLoading, !preparingPlayback else { return }
        let entries = smbFolders.filter { !$0.isDirectory }.sorted {
            FileNameOrder.compare($0.name, $1.name, descending: descendingFileNames)
        }
        guard !entries.isEmpty else { return }
        preparingPlayback = true
        inputError = nil
        playbackTask = Task {
            defer { if !Task.isCancelled { preparingPlayback = false } }
            do {
                let indexed = indexedSMBDirectory()
                var items: [Media] = []
                for entry in entries {
                    try Task.checkCancellation()
                    if let media = indexed[entry.name] { items.append(media) }
                    else {
                        let url = try await RemoteSources.shared.browsedSMBURL(entry.url, connection: source)
                        items.append(Media(url: url, title: entry.name, directPlaybackURL: SMBClient.playbackHistoryURL(entry.url)))
                    }
                }
                try Task.checkCancellation()
                playQueue(items, shuffled, loop)
            } catch is CancellationError {} catch {
                if !Task.isCancelled { inputError = error.localizedDescription }
            }
        }
    }

    private func indexedSMBPaths() -> [UUID: [Substring]] {
        guard let smbURL, let connection = smbConnection else { return [:] }
        let server = SMBClient.serverURL(connection.url)
        let directory = SMBClient.pathComponents(smbURL)
        var paths: [UUID: [Substring]] = [:]
        for source in store.starredSMBFolders where SMBClient.serverURL(source.url) == server {
            let root = SMBClient.pathComponents(source.url)
            if directory.starts(with: root) {
                paths[source.id] = Array(directory.dropFirst(root.count))
            }
        }
        return paths
    }

    private func indexedSMBDirectory() -> [String: Media] {
        let paths = indexedSMBPaths().mapValues { $0.isEmpty ? "" : $0.joined(separator: "/") + "/" }
        return Dictionary(library.items.compactMap { item -> (String, Media)? in
            guard item.sourceMissing != true, let prefix = item.sourceID.flatMap({ paths[$0] }),
                  item.sourcePath.hasPrefix(prefix) else { return nil }
            let filename = item.sourcePath.dropFirst(prefix.count)
            guard !filename.contains("/") else { return nil }
            return (String(filename), item)
        }, uniquingKeysWith: { first, _ in first })
    }
    private func chooseKnownHosts() {
        let panel = NSOpenPanel(); panel.showsHiddenFiles = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { knownHosts = url.path }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "选择本地目录或 Finder 已挂载的 NAS 目录。"
        if panel.runModal() == .OK, let url = panel.url {
            let source = store.add(name: url.lastPathComponent, url: url)
            reset(); route = .saved(source.id); store.scan(source, library: library, metadata: metadata)
        }
    }
}

private extension SourceKind {
    var badge: String { switch self {
    case .smb: "SMB"; case .nfs: "NFS"; case .webdav, .alist: "DAV"; case .dlna: "DLNA"
    case .sftp: "SFTP"; case .ftps: "FTPS"; case .ftpes: "TLS"; case .ftp: "FTP"
    case .plex: "P"; case .jellyfin: "J"; case .emby: "E"
    } }
    var badgeColor: Color { switch self {
    case .smb: .indigo; case .ftp, .ftps, .ftpes: .blue; case .nfs, .dlna, .emby: .green
    case .webdav, .alist, .jellyfin: .purple; case .sftp: .teal; case .plex: .orange
    } }
}
