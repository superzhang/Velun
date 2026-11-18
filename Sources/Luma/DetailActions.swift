import SwiftUI
import UniformTypeIdentifiers

struct DetailActions: View {
    let group: MediaGroup
    let selected: Media
    let library: Library
    let playback: Playback
    let match: (Media) -> Void
    var heroStyle = false
    @State private var showMore = false
    @State private var panel: DetailPanel?
    @State private var name = ""
    @State private var downloading = false
    @State private var downloadMessage = ""
    private var ids: [UUID] { group.items.map(\.id) }
    enum DetailPanel: String, Identifiable { case rating, playlist, collection, download; var id: String { rawValue } }
    var body: some View {
        HStack(spacing: 8) {
            if heroStyle { heroButtons } else {
            Button { library.setWatchlist([selected.id], value: selected.watchlisted != true) } label: {
                Image(systemName: selected.watchlisted == true ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44).contentShape(Capsule())
            }.buttonStyle(DetailToolbarButtonStyle())
                .accessibilityLabel(selected.watchlisted == true ? "移出正在观看列表" : "加入到正在观看列表")
            Button { showMore.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }.frame(width: 64, height: 44).contentShape(Capsule())
            }.buttonStyle(DetailToolbarButtonStyle()).accessibilityLabel("影片更多操作")
                .popover(isPresented: $showMore, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                Button("循环播放") { perform { playback.playQueue(group.items, shuffled: false, loop: true) } }
                Button("随机播放") { perform { playback.playQueue(group.items, shuffled: true, loop: false) } }
                Menu("标记为…") {
                    Button(group.isTV ? "本集已观看" : "已观看") { perform { library.setWatched([selected.id], to: true) } }
                    Button(group.isTV ? "本集未观看" : "未观看") { perform { library.setWatched([selected.id], to: false) } }
                    if group.items.count > 1 {
                        Divider()
                        Button("全部已观看") { perform { library.setWatched(ids, to: true) } }
                        Button("全部未观看") { perform { library.setWatched(ids, to: false) } }
                    }
                }
                Button(selected.watchlisted == true ? "移出正在观看列表" : "加入到正在观看列表") { perform { library.setWatchlist([selected.id], value: selected.watchlisted != true) } }
                Button("播放列表") { perform { name = ""; panel = .playlist } }
                Button("系列") { perform { name = ""; panel = .collection } }
                Button("评分") { perform { panel = .rating } }
                Button("编辑元数据") { perform { match(selected) } }
                ShareLink(item: selected.url) { Text("分享") }
                Button(downloading ? "正在下载…" : "下载") { perform { download() } }.disabled(downloading)
                    }.buttonStyle(DetailActionRowStyle()).padding(8).frame(width: 250)
                }
        }
        }
        .sheet(item: $panel) { value in
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(value == .rating ? "我的评分" : value == .playlist ? "播放列表" : value == .collection ? "系列" : "下载").font(.title2.weight(.semibold))
                    Spacer(); Button("完成") { panel = nil }.keyboardShortcut(.cancelAction)
                }
                Text(group.title).foregroundStyle(.secondary)
                switch value {
                case .rating:
                    Picker("评分", selection: Binding(get: { selected.personalRating ?? 0 }, set: { library.setDetailInfo(ids, rating: $0) })) {
                        Text("未评分").tag(0)
                        ForEach(1...10, id: \.self) { Text("\($0) / 10").tag($0) }
                    }
                    Text("评分保存在本机，不会提交到 TMDB。").font(.caption).foregroundStyle(.secondary)
                case .playlist:
                    Text("选择播放列表，或创建一个新列表。")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(library.playlistNames, id: \.self) { playlist in
                                Toggle(playlist, isOn: Binding(get: { selected.playlists?.contains(playlist) == true }, set: { library.setPlaylist(ids, name: playlist, included: $0) }))
                            }
                        }
                    }.frame(maxHeight: 180)
                    HStack {
                        TextField("新播放列表名称", text: $name)
                        Button("创建并加入") { library.setPlaylist(ids, name: name, included: true); name = "" }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                case .collection:
                    Text("将本作品加入自定义系列。")
                    Picker("已有系列", selection: Binding(get: { selected.collectionName ?? "" }, set: { library.setDetailInfo(ids, collection: $0) })) {
                        Text("无系列").tag("")
                        ForEach(library.collectionNames, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        TextField("新系列名称", text: $name)
                        Button("创建并加入") { library.setDetailInfo(ids, collection: name); name = "" }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                case .download: Text(downloadMessage).textSelection(.enabled)
                }
            }.padding(26).frame(width: 480)
        }
    }
    private var heroButtons: some View {
        HStack(spacing: 9) {
            heroButton(selected.isWatched ? "eye.slash" : "eye", title: "切换观看状态") { library.setWatched([selected.id], to: !selected.isWatched) }
            heroButton(downloading ? "arrow.down.circle" : "arrow.down.to.line", title: downloading ? "正在下载…" : "下载") { download() }.disabled(downloading)
            heroButton(selected.watchlisted == true ? "bookmark.fill" : "bookmark", title: "正在观看列表") { library.setWatchlist([selected.id], value: selected.watchlisted != true) }
            heroButton(group.hasFavorite ? "star.fill" : "star", title: group.hasFavorite ? "取消收藏" : "加入收藏") { library.setFavorite(ids, to: !group.hasFavorite) }
            heroButton("plus.rectangle.on.rectangle", title: "加入播放列表") { name = ""; panel = .playlist }
        }
    }
    private func heroButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(.white.opacity(0.22)))
                .contentShape(Circle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    private func perform(_ action: () -> Void) { showMore = false; action() }
    private func download() {
        guard !["m3u8", "mpd"].contains(selected.url.pathExtension.lowercased()) else {
            downloadMessage = "分段流暂不支持离线下载，请选择视频文件直链或 NAS 文件。"; panel = .download; return
        }
        let save = NSSavePanel(); save.nameFieldStringValue = selected.url.lastPathComponent
        save.message = "保存视频副本，原视频保留在原位置。"
        guard save.runModal() == .OK, let destination = save.url else { return }
        guard destination.resolvingSymlinksInPath() != selected.url.resolvingSymlinksInPath() else { downloadMessage = "请选择与原视频不同的位置。"; panel = .download; return }
        downloading = true
        let source = selected.url
        Task {
            defer { downloading = false }
            do {
                let resolved = source.scheme == "luma-source" ? try await RemoteSourceResolver.resolve(selected) : source
                try await VideoCopy.save(resolved, to: destination); downloadMessage = "已保存到：\(destination.path)" }
            catch { downloadMessage = "保存失败：\(error.localizedDescription)" }
            panel = .download
        }
    }
}

enum VideoCopy {
    @concurrent static func save(_ source: URL, to destination: URL) async throws {
        let staging = destination.deletingLastPathComponent().appending(path: ".luma-\(UUID())")
        defer { try? FileManager.default.removeItem(at: staging) }
        if source.isFileURL { try FileManager.default.copyItem(at: source, to: staging) }
        else {
            let (temporary, response) = try await URLSession.shared.download(from: source)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: temporary, to: staging)
        }
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: destination) }
    }
}

private struct DetailToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.primary)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(LumaTheme.ink.opacity(0.14)))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
private struct DetailActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14))
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(LumaTheme.ink.opacity(configuration.isPressed ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6))
    }
}
