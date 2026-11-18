import SwiftUI
import AppKit

private enum SourceRoute: Hashable {
    case add, directURL, connection(SourceKind), smbBrowse, saved(UUID)
}

struct SourcesView: View {
    @Bindable var store: SourcesStore
    let library: Library
    let metadata: MetadataStore
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
    @State private var smbFolders: [SMBFolder] = []
    @State private var smbTask: Task<Void, Never>?
    @State private var smbLoading = false
    @State private var removal: LibrarySource?
    @FocusState private var addressFocused: Bool
    private var selectedSource: LibrarySource? {
        if case .saved(let id) = route { return store.sources.first { $0.id == id } }; return nil
    }
    private var title: String {
        switch route {
        case .add: "添加共享"
        case .directURL: "通过直接 URL"
        case .connection: (editing == nil ? "添加 " : "编辑 ") + kind.title
        case .smbBrowse: "选择 SMB 文件夹"
        case .saved: selectedSource?.name ?? "共享"
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.4)
            VStack(spacing: 0) {
                ZStack {
                    Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1).padding(.horizontal, 130)
                    HStack {
                        if case .connection = route {
                            Button { reset(); route = .add } label: { Label("添加共享", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }.padding(.horizontal, 28).frame(height: 66)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch route {
                        case .add: catalog
                        case .directURL: directURLPage
                        case .connection: connectionPage
                        case .smbBrowse: smbBrowser
                        case .saved: if let source = selectedSource { savedPage(source) }
                        }
                        if let inputError { Label(inputError, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    }.padding(.horizontal, 28).padding(.bottom, 28).frame(maxWidth: 720).frame(maxWidth: .infinity)
                }.id(route)
                if store.busy || !store.status.isEmpty || store.error != nil { statusBar }
            }.frame(maxWidth: .infinity).background(LumaTheme.canvas)
        }.frame(width: 940, height: 700).background(LumaTheme.sidebar).tint(.orange)
            .confirmationDialog("移除“\(removal?.name ?? "")”的来源配置？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                Button("移除来源", role: .destructive) { if let removal { store.remove(removal) }; removal = nil; reset(); route = .add }
            } message: { Text("原文件、海报和本机观看进度会保留。") }
            .task { discovery.start() }
            .onDisappear { discovery.stop(); smbTask?.cancel(); password = ""; token = "" }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).frame(width: 36, height: 36)
                    .background(LumaTheme.surface.opacity(0.7), in: Circle()).overlay(Circle().stroke(.secondary.opacity(0.15)))
            }.buttonStyle(.plain).accessibilityLabel("关闭添加文件").keyboardShortcut(.cancelAction).padding(18)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    navigation("通过直接 URL", icon: "globe", selected: route == .directURL) { reset(); route = .directURL }
                    Text("已保存的共享").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 24).padding(.bottom, 6)
                    navigation("添加…", icon: "plus", selected: route == .add || isConnecting) { reset(); route = .add }
                    ForEach(store.sources) { source in
                        HStack(spacing: 0) {
                            navigation(source.name, icon: source.url.isFileURL ? "folder" : "externaldrive", selected: route == .saved(source.id)) { reset(); route = .saved(source.id) }
                            if !source.url.isFileURL {
                                Button { edit(source) } label: { Image(systemName: "pencil").frame(width: 32, height: 44).contentShape(Rectangle()) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("编辑 \(source.name)").disabled(store.busy || loadingCredentials)
                            }
                        }
                    }
                }.padding(.horizontal, 12)
            }
            Text("只读访问\n原文件保留在来源中").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).padding(26)
        }.frame(width: 240).background(LumaTheme.sidebar)
    }
    private var isConnecting: Bool { if case .connection = route { true } else { false } }
    private func navigation(_ text: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) { Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.orange).frame(width: 22); Text(text).lineLimit(1); Spacer(minLength: 0) }
                .font(.system(size: 14, weight: selected ? .semibold : .regular)).padding(.horizontal, 13).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).background(selected ? LumaTheme.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8)).accessibilityAddTraits(selected ? .isSelected : [])
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
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button { smbTask?.cancel(); smbLoading = false; route = .connection(.smb); inputError = nil } label: { Label("连接信息", systemImage: "chevron.left") }.buttonStyle(.plain)
                Spacer()
                if smbLoading { ProgressView().controlSize(.small) }
            }
            if let url = smbURL {
                group("当前位置") { info("服务器", url.host ?? ""); separator; info("文件夹", url.path.isEmpty || url.path == "/" ? "共享列表" : url.path) }
                if !url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
                    Button { browseSMB(url.deletingLastPathComponent()) } label: { Label("上一级", systemImage: "arrow.up") }.disabled(smbLoading)
                }
                group("可用文件夹") {
                    if smbFolders.isEmpty { Text(smbLoading ? "正在读取…" : "此处没有子文件夹").foregroundStyle(.secondary).padding(20) }
                    ForEach(smbFolders) { folder in
                        choice(folder.name, symbol: "folder", color: .orange) { browseSMB(folder.url) }.disabled(smbLoading)
                        if folder.id != smbFolders.last?.id { separator }
                    }
                }
                caption("打开要加入媒体库的共享或子文件夹，再点击下方按钮。只扫描所选目录。")
                HStack { Spacer(); Button(editing == nil ? "添加此文件夹并扫描" : "保存此文件夹并扫描") { saveSMB(url) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(smbLoading || LibrarySource.smbURL(url.absoluteString) == nil || inputError != nil) }
            }
        }
    }
    private var directURLPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            group("网络视频") {
                field("地址") { TextField("https://example.com/video.mkv", text: $address).focused($addressFocused).onSubmit { addDirectURL() } }
            }
            caption("添加 HTTP / HTTPS 视频直链。NAS 目录或媒体服务器请从“添加共享”进入。")
            HStack { Spacer(); Button("添加到媒体库") { addDirectURL() }.buttonStyle(.borderedProminent).controlSize(.large) }
        }.textFieldStyle(.plain)
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
    private func reset() { smbTask?.cancel(); smbTask = nil; smbLoading = false; smbURL = nil; smbFolders = []; name = ""; address = ""; username = ""; password = ""; token = ""; userID = ""; originalCredentials = nil; editing = nil; inputError = nil; addressFocused = false; editGeneration = UUID(); loadingCredentials = false }
    private func begin(_ kind: SourceKind) { reset(); self.kind = kind; route = .connection(kind) }
    private func connect() {
        guard !store.busy, !loadingCredentials, !smbLoading else { return }
        guard let url = kind.validatedURL(address) else { inputError = "请填写正确的 \(kind.title) 地址，账号密码不要写入 URL。"; return }
        if kind == .smb { browseSMB(url); return }
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
    private func browseSMB(_ url: URL) {
        smbTask?.cancel(); smbLoading = true; inputError = nil
        let credentials = SourceCredentials(username: username, password: password)
        let generation = UUID(); editGeneration = generation
        smbTask = Task {
            defer { if editGeneration == generation { smbLoading = false } }
            do {
                let folders = try await SMBClient.browse(url, credentials: credentials)
                try Task.checkCancellation()
                guard editGeneration == generation else { return }
                smbURL = url; smbFolders = folders; route = .smbBrowse
            } catch is CancellationError {} catch { if editGeneration == generation { inputError = error.localizedDescription } }
        }
    }
    private func saveSMB(_ url: URL) {
        guard !smbLoading, LibrarySource.smbURL(url.absoluteString) != nil else { return }
        let existing = editing ?? store.sources.first { $0.url == url && $0.directSMB == true }
        let id = existing?.id ?? UUID()
        do {
            try SourceSecrets.save(SourceCredentials(username: username, password: password), id: id)
            let source = existing.map { store.update($0, name: name, url: url, kind: .smb, directSMB: true) } ?? store.add(name: name, url: url, kind: .smb, directSMB: true, id: id)
            reset(); route = .saved(source.id); store.scan(source, library: library, metadata: metadata)
        } catch { inputError = error.localizedDescription }
    }
    private func edit(_ source: LibrarySource) {
        guard !loadingCredentials, !store.busy else { return }
        loadingCredentials = true
        let generation = UUID(); editGeneration = generation
        Task {
            defer { if editGeneration == generation { loadingCredentials = false } }
            do {
                let credentials = try await SourceSecrets.read(source.id)
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
    private func addDirectURL() {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { inputError = "请输入有效的 HTTP / HTTPS 视频地址。"; return }
        library.add([url]); reset(); dismiss()
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
