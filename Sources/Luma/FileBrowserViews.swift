import SwiftUI
import AppKit

struct FileBrowserRow: View {
    let title: String
    let icon: String
    var subtitle: String? = nil
    var watched = false
    var opensFolder = false
    var action: (() -> Void)?
    var activation: FileItemActivation?
    @State private var hovered = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    label
                }.buttonStyle(.plain)
                    .background(LumaTheme.ink.opacity(hovered ? 0.065 : 0))
                    .onHover { hovered = $0 }
                    .help(title)
                    .modifier(activation ?? FileItemActivation())
            } else {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 22)).frame(width: 32)
                .foregroundStyle(opensFolder ? LumaTheme.navigationAccent : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            if watched {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(LumaTheme.navigationAccent)
                    .accessibilityLabel("已观看")
            }
            if opensFolder {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background(LumaTheme.ink.opacity(activation?.isSelected == true ? 0.14 : 0))
        .contentShape(Rectangle())
    }
}

struct OfflineDownloadsPage: View {
    let downloads: OfflineDownloads
    let play: (URL) -> Void
    @State private var removal: OfflineDownloads.Item?
    @State private var error: String?

    var body: some View {
        if downloads.items.isEmpty {
            ContentUnavailableView("没有下载", systemImage: "arrow.down.circle",
                                   description: Text("在网络视频的菜单中选择「下载」，即可离线播放。"))
        } else {
            LazyVStack(spacing: 0) {
                ForEach(downloads.items) { item in
                    HStack(spacing: 8) {
                        switch item.state {
                        case .transferring(let fraction):
                            VStack(alignment: .leading, spacing: 4) {
                                FileBrowserRow(title: item.name, icon: "arrow.down.circle", subtitle: "正在下载")
                                Group {
                                    if let fraction { ProgressView(value: fraction) }
                                    else { ProgressView() }
                                }.controlSize(.small).padding(.horizontal, 16).padding(.bottom, 10)
                            }
                            Button("取消") { downloads.cancel(item.id) }.padding(.trailing, 16)
                        case .ready(let file):
                            FileBrowserRow(title: item.name, icon: "play.rectangle", action: { play(file) })
                            Menu {
                                Button("播放") { play(file) }
                                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                                Button("移除下载…", role: .destructive) { removal = item }
                            } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).fixedSize()
                                .accessibilityLabel("下载文件操作").padding(.trailing, 16)
                        case .failed(let message):
                            FileBrowserRow(title: item.name, icon: "exclamationmark.circle", subtitle: "下载失败 · \(message)")
                            Button("清除") { remove(item) }.padding(.trailing, 16)
                        }
                    }
                    Divider().padding(.leading, 16)
                }
            }
            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .confirmationDialog("移除离线副本？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
                Button("移到废纸篓", role: .destructive) { if let removal { remove(removal) }; removal = nil }
            }
            if let error { Text(error).foregroundStyle(LumaTheme.warningText).font(.callout) }
        }
    }

    private func remove(_ item: OfflineDownloads.Item) {
        do { try downloads.remove(item); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct FileVideoRow: View {
    let title: String
    let media: Media?
    let action: () -> Void
    var download: (() -> Void)?
    var select: (() -> Void)?
    var selected = false

    var body: some View {
        HStack(spacing: 8) {
            FileBrowserRow(title: title, icon: "play.rectangle", watched: media?.isWatched == true,
                           action: select ?? action, activation: select.map { _ in FileItemActivation(isSelected: selected, open: action) })
            if let download {
                Menu {
                    Button("播放", action: action)
                    Button("下载", action: download)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("\(title) 的操作").padding(.trailing, 16)
            }
        }
    }
}

struct FileItemActivation: ViewModifier {
    var isSelected = false
    var open: (() -> Void)?

    func body(content: Content) -> some View {
        if let open {
            content
                .simultaneousGesture(TapGesture(count: 2).onEnded { open() })
                .onKeyPress(.return) {
                    open()
                    return .handled
                }
                .accessibilityAction(named: Text("打开"), open)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content
        }
    }
}

struct SavedSourceFileBrowser: View {
    let source: LibrarySource
    let library: Library
    let filter: String
    let play: (Media) -> Void
    let download: (Media) -> Void
    var listMode = true
    var descendingNames = false
    var usesSelection = false
    @State private var path = ""
    @State private var refresh = 0
    @State private var location: URL?
    @State private var entries: [FileDirectoryEntry] = []
    @State private var listedPath: String?
    @State private var loading = true
    @State private var error: String?
    @State private var selectedEntries: [String: URL] = [:]

    private var usesIndex: Bool { !source.isFileShare }
    private var indexedItems: [String: Media] {
        Dictionary(library.items.lazy.filter { $0.sourceID == source.id && $0.sourceMissing != true }
            .map { ($0.sourcePath, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let indexed = indexedItems
        let artwork = listMode ? [:] : FileDirectoryArtwork.index(groups: library.groupedItems, directories: [source.id: path.split(separator: "/")])
        let visible = (usesIndex ? indexedEntries(indexed) : listedPath == path ? entries : []).filter {
            filter.isEmpty || $0.name.localizedStandardContains(filter)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return FileNameOrder.compare($0.name, $1.name, descending: descendingNames)
        }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if !path.isEmpty {
                    Button {
                        path = path.split(separator: "/").dropLast().joined(separator: "/")
                    } label: { Label("上一级", systemImage: "chevron.left") }
                        .disabled(loading)
                }
                Text(path.isEmpty ? "共享目录" : path).lineLimit(1).truncationMode(.middle)
                Spacer()
                if loading && !usesIndex { ProgressView().controlSize(.small) }
                else if !usesIndex {
                    Button { refresh += 1 } label: { Label("刷新", systemImage: "arrow.clockwise") }
                }
            }
            if let error { Text(error).foregroundStyle(LumaTheme.warningText).font(.callout) }
            if visible.isEmpty && (usesIndex || !loading) && error == nil {
                Text(usesIndex ? "扫描此来源后即可浏览视频。" : filter.isEmpty ? "此目录没有文件夹或视频。" : "没有匹配的文件。")
                    .foregroundStyle(.secondary).padding(.vertical, 14)
            }
            Group {
                if listMode {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { entry in
                            let relative = path.isEmpty ? entry.name : path + "/" + entry.name
                            if entry.isDirectory {
                                FileBrowserRow(title: entry.name, icon: "folder", opensFolder: true,
                                               action: click(entry, open: { path = relative }),
                                               activation: activation(entry, open: { path = relative }))
                                    .contextMenu { Button("打开") { path = relative } }
                            } else {
                                let item = media(entry, relative: relative, indexed: indexed[relative])
                                FileVideoRow(title: entry.name, media: item, action: { play(item) },
                                             download: OfflineDownloads.supports(item.url) ? { download(item) } : nil,
                                             select: usesSelection ? { selectedEntries[path] = entry.url } : nil,
                                             selected: selectedEntries[path] == entry.url)
                            }
                            Divider().padding(.leading, 16)
                        }
                    }.background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    FileBrowserGrid {
                        ForEach(visible) { entry in
                            let relative = path.isEmpty ? entry.name : path + "/" + entry.name
                            if entry.isDirectory {
                                FileBrowserCard(title: entry.name, icon: "folder",
                                                activation: activation(entry, open: { path = relative }) ?? FileItemActivation(),
                                                portrait: true, artwork: artwork[entry.name],
                                                action: click(entry, open: { path = relative }))
                                    .contextMenu { Button("打开") { path = relative } }
                            } else {
                                let item = media(entry, relative: relative, indexed: indexed[relative])
                                FileBrowserCard(title: entry.name, icon: "play.rectangle", video: true,
                                                activation: activation(entry, open: { play(item) }) ?? FileItemActivation(),
                                                portrait: true, artwork: artwork[entry.name],
                                                action: click(entry, open: { play(item) }))
                                    .contextMenu {
                                        Button("播放") { play(item) }
                                        if OfflineDownloads.supports(item.url) { Button("下载") { download(item) } }
                                    }
                            }
                        }
                    }
                }
            }.disabled(loading && !usesIndex)
        }
        .task(id: Listing(path: path, refresh: refresh, revision: source.connectionRevision)) { await load() }
    }

    private func click(_ entry: FileDirectoryEntry, open: @escaping () -> Void) -> () -> Void {
        usesSelection ? { selectedEntries[path] = entry.url } : open
    }

    private func activation(_ entry: FileDirectoryEntry, open: @escaping () -> Void) -> FileItemActivation? {
        guard usesSelection else { return nil }
        return FileItemActivation(isSelected: selectedEntries[path] == entry.url) {
            selectedEntries[path] = entry.url
            open()
        }
    }

    private struct Listing: Hashable {
        let path: String
        let refresh: Int
        let revision: UUID?
    }

    private func indexedEntries(_ indexed: [String: Media]) -> [FileDirectoryEntry] {
        let prefix = path.isEmpty ? "" : path + "/"
        var folders: Set<String> = []
        var files: [FileDirectoryEntry] = []
        for (relative, item) in indexed where relative.hasPrefix(prefix) {
            let tail = relative.dropFirst(prefix.count)
            let parts = tail.split(separator: "/")
            guard let first = parts.first else { continue }
            if parts.count > 1 { folders.insert(String(first)) }
            else { files.append(FileDirectoryEntry(name: String(first), url: item.url, isDirectory: false)) }
        }
        return folders.map {
            FileDirectoryEntry(name: $0, url: source.url.appending(component: $0))
        } + files
    }

    private func media(_ entry: FileDirectoryEntry, relative: String, indexed: Media?) -> Media {
        if let indexed { return indexed }
        let url = source.isRemote ? RemoteSources.virtualURL(source: source.id, path: relative) : entry.url
        return Media(url: url, title: entry.name, sourceID: source.id, relativePath: relative)
    }

    private func load() async {
        guard !usesIndex else { return }
        let path = path
        let refresh = refresh
        loading = true; error = nil; entries = []
        defer { if path == self.path && refresh == self.refresh && !Task.isCancelled { loading = false } }
        do {
            let result: [FileDirectoryEntry]
            if source.isRemote {
                let credentials = try await SourceSecrets.read(source.credentialID)
                result = try await RcloneTool.listDirectory(source.kind, at: source.url, path: path, credentials: credentials)
            } else {
                let root: URL
                if let location { root = location }
                else if source.url.isFileURL { root = source.url }
                else { root = try await SourceWorker.mount(source.url) }
                try Task.checkCancellation()
                location = root
                result = try await Self.localEntries(path.isEmpty ? root : root.appending(path: path))
            }
            try Task.checkCancellation()
            guard path == self.path && refresh == self.refresh else { return }
            entries = result
            listedPath = path
        } catch is CancellationError {} catch {
            if !Task.isCancelled && path == self.path && refresh == self.refresh { self.error = error.localizedDescription }
        }
    }

    @concurrent static func localEntries(_ directory: URL) async throws -> [FileDirectoryEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return nil }
            let folder = values.isDirectory == true
            guard folder || (values.isRegularFile == true && SidecarIndex.remoteVideoExtensions.contains(url.pathExtension.lowercased())) else { return nil }
            return FileDirectoryEntry(name: url.lastPathComponent, url: url, isDirectory: folder)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct FileLayoutButton: View {
    @Binding var listMode: Bool

    var body: some View {
        Button { listMode.toggle() } label: {
            Image(systemName: listMode ? "square.grid.2x2" : "list.bullet")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle())
        .help(listMode ? "网格视图" : "列表视图")
        .accessibilityLabel(listMode ? "切换为网格视图" : "切换为列表视图")
    }
}

enum FileNameOrder {
    static func compare(_ lhs: String, _ rhs: String, descending: Bool) -> Bool {
        lhs.localizedStandardCompare(rhs) == (descending ? .orderedDescending : .orderedAscending)
    }
}

struct FileBrowserGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 144, maximum: 190), spacing: 16)], alignment: .leading, spacing: 16) {
            content
        }
    }
}

struct FileBrowserCard: View {
    let title: String
    let icon: String
    var favorite = false
    var video = false
    var activation = FileItemActivation()
    var portrait = false
    var artwork: FileDirectoryArtwork?
    let action: () -> Void
    @State private var artworkHovered = false

    var body: some View {
        Group {
            if portrait {
                Button(action: action) { portraitContent }
                    .buttonStyle(.plain)
            } else {
                Button(action: action) { compactContent }
                    .buttonStyle(SidebarButtonStyle())
                    .help(title)
            }
        }
        .modifier(activation)
    }

    private var portraitContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LumaTheme.surface)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    if let artwork {
                        PosterView(url: artwork.poster, fallbackURL: artwork.fallback, placeholderSymbol: icon)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 39, weight: .light))
                            .foregroundStyle(video ? Color.secondary : LumaTheme.navigationAccent)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(activation.isSelected ? LumaTheme.navigationAccent : LumaTheme.ink.opacity(artworkHovered ? 0.22 : 0.08),
                                      lineWidth: activation.isSelected ? 2 : 1)
                        .allowsHitTesting(false)
                }
                .onHover { artworkHovered = $0 }
                .accessibilityHidden(true)
            Text(artwork?.title ?? title)
                .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                .help(title)
            Text(artwork?.subtitle ?? " ")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityHidden(artwork?.subtitle == nil)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(video ? Color.secondary : LumaTheme.navigationAccent)
                Spacer(minLength: 0)
                if favorite {
                    Image(systemName: "star.fill").font(.system(size: 13))
                        .foregroundStyle(LumaTheme.navigationAccent)
                }
            }.accessibilityHidden(true)
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .background(activation.isSelected ? LumaTheme.navigationAccent.opacity(0.12) : LumaTheme.surface,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(activation.isSelected ? LumaTheme.navigationAccent : LumaTheme.ink.opacity(0.08))
            .allowsHitTesting(false))
        .contentShape(Rectangle())
    }
}

struct FileFavoritesPage: View {
    let folders: [LibrarySource]
    let filter: String
    let listMode: Bool
    let descendingNames: Bool
    @Binding var selectedFolderID: UUID?
    let open: (LibrarySource) -> Void
    let addSource: () -> Void

    var body: some View {
        let visible = folders.filter {
            filter.isEmpty || $0.url.lastPathComponent.localizedStandardContains(filter)
        }.sorted { FileNameOrder.compare($0.url.lastPathComponent, $1.url.lastPathComponent, descending: descendingNames) }

        if visible.isEmpty {
            ContentUnavailableView {
                Label(filter.isEmpty ? "还没有收藏的文件夹" : "没有匹配的文件夹", systemImage: filter.isEmpty ? "folder.badge.plus" : "magnifyingglass")
            } description: {
                if filter.isEmpty { Text("在共享中点星收藏文件夹，即可从这里打开。") }
            } actions: {
                if filter.isEmpty { Button("新增文件来源", action: addSource).controlSize(.large) }
            }
        } else {
            ScrollView {
                if listMode {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { folder in
                            let item = activation(for: folder)
                            FileBrowserRow(title: folder.url.lastPathComponent, icon: "star", opensFolder: true,
                                           action: { selectedFolderID = folder.id }, activation: item)
                                .contextMenu { Button("打开") { open(folder) } }
                            Divider().padding(.leading, 16)
                        }
                    }
                    .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(28)
                } else {
                    FileBrowserGrid {
                        ForEach(visible) { folder in
                            FileBrowserCard(title: folder.url.lastPathComponent, icon: "folder", favorite: true, activation: activation(for: folder)) {
                                selectedFolderID = folder.id
                            }.contextMenu { Button("打开") { open(folder) } }
                        }
                    }.padding(28)
                }
            }
        }
    }

    private func activation(for folder: LibrarySource) -> FileItemActivation {
        FileItemActivation(isSelected: selectedFolderID == folder.id) { open(folder) }
    }
}
