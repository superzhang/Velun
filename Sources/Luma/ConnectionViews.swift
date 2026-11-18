import SwiftUI
import AppKit


struct TMDBSettingsView: View {
    @Bindable var store: MetadataStore
    let library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("TMDB 海报与影片信息").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("根据视频文件名搜索电影或剧集，并显示中文片名、年份与海报。无法确定的候选结果会留给你手动选择。") .foregroundStyle(.secondary)
            Text("请在 TMDB 账户的 API 设置中申请 API 凭据，然后将 API Read Access Token 粘贴到下方。播放本地或 NAS 视频无需配置令牌。")
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("读取访问令牌") { SecureField(store.configured ? "已保存在钥匙串；填写可替换" : "API Read Access Token", text: $token) }.textFieldStyle(.roundedBorder)
            HStack {
                Button("保存令牌") {
                    do { guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "请输入令牌。"; return }; try store.saveToken(token); token = ""; message = "令牌已保存到 macOS 钥匙串。"; if store.autoMatch { store.matchMissing(library) } }
                    catch { message = error.localizedDescription }
                }.disabled(store.busy)
                if store.configured { Label("已配置", systemImage: "checkmark.circle.fill").foregroundStyle(.orange) }
                Spacer()
                Link("获取 TMDB 令牌", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
            }
            Toggle("导入或扫描后自动匹配海报", isOn: $store.autoMatch).onChange(of: store.autoMatch) { _, enabled in if enabled { store.matchMissing(library) } }
            Text("自动匹配会向 TMDB 发送清理后的影片名和年份。令牌仅发送给 TMDB API，不会保存在媒体库文件中。") .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("为未匹配视频查找海报") { store.matchMissing(library, retryReviewed: true) }.buttonStyle(.borderedProminent).disabled(!store.configured || store.busy)
                if store.busy { ProgressView().controlSize(.small); Button("停止") { store.cancel() } }
                Spacer()
                Button("移除令牌", role: .destructive) { do { try store.saveToken(""); message = "令牌已移除。" } catch { message = error.localizedDescription } }.disabled(!store.configured || store.busy)
            }
            if !message.isEmpty { Text(message).textSelection(.enabled) }
            if !store.status.isEmpty { Text(store.status).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            HStack(spacing: 16) {
                if let url = Bundle.module.url(forResource: "tmdb", withExtension: "svg", subdirectory: "Resources"), let logo = NSImage(contentsOf: url) {
                    Image(nsImage: logo).resizable().scaledToFit().frame(width: 64, height: 48).accessibilityLabel("TMDB")
                }
                Text("关于 TMDB").font(.headline)
            }
            Link("影片信息与海报由 The Movie Database（TMDB）提供", destination: URL(string: "https://www.themoviedb.org")!)
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 620)
    }
}

struct MatchView: View {
    let media: Media
    let library: Library
    let store: MetadataStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var year = ""
    @State private var isTV = false
    @State private var results: [MovieInfo] = []
    @State private var message = ""
    @State private var busy = false
    @State private var searchTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("匹配海报").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(media.title).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                TextField("影片名称", text: $query).accessibilityLabel("影片名称").onSubmit { search() }
                TextField("年份（可选）", text: $year).frame(width: 110).accessibilityLabel("年份")
                Picker("类型", selection: $isTV) { Text("电影").tag(false); Text("剧集").tag(true) }.frame(width: 125)
                Button("搜索") { search() }.disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.configured)
            }.textFieldStyle(.roundedBorder)
            if !store.configured { Text("请先在侧栏的 TMDB 设置中填写读取访问令牌。") .foregroundStyle(.orange) }
            if busy { ProgressView("正在搜索 TMDB…") }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(results) { info in
                        HStack(alignment: .top, spacing: 16) {
                            PosterView(url: info.poster).frame(width: 68, height: 102).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(info.title)  \(info.year)").font(.headline)
                                Text(info.overview.isEmpty ? "暂无简介" : info.overview).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                                Link("在 TMDB 查看", destination: info.creditURL).font(.caption)
                            }
                            Spacer()
                            Button("使用此海报") { apply(info) }.buttonStyle(.borderedProminent).disabled(busy)
                        }.padding(12).background(LumaTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            HStack {
                if media.metadata != nil { Button("移除匹配") { library.applyMetadata(nil, to: library.groupedItems.first(where: { $0.items.contains(where: { $0.id == media.id }) })?.items.map(\.id) ?? [media.id]); dismiss() } }
                Spacer()
                Text("数据与图片：TMDB").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(28).frame(width: 740, height: 570)
        .onAppear { let parsed = MediaName(media.url.deletingPathExtension().lastPathComponent); query = parsed.title; year = parsed.year ?? ""; isTV = parsed.isTV }
        .onDisappear { searchTask?.cancel() }
    }
    private func apply(_ info: MovieInfo) {
        busy = true
        searchTask = Task {
            defer { busy = false }
            do {
                let token = try await KeychainToken.readAsync()
                let enriched = try await store.client.details(info, token: token)
                try Task.checkCancellation()
                library.applyMetadata(enriched, to: library.groupedItems.first(where: { $0.items.contains(where: { $0.id == media.id }) })?.items.map(\.id) ?? [media.id]); dismiss()
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
    private func search() {
        busy = true; message = ""; results = []
        searchTask = Task {
            defer { busy = false }
            do {
                let token = try await KeychainToken.readAsync()
                let found = try await store.client.search(title: query.trimmingCharacters(in: .whitespacesAndNewlines), year: year, isTV: isTV, token: token)
                try Task.checkCancellation(); results = found
                if found.isEmpty { message = "没有找到匹配结果，试试修改片名、类型或清空年份。" }
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
}

struct PosterView: View {
    let url: URL?
    var fallbackURL: URL? = nil
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            LumaTheme.ink.opacity(0.05)
            if let image { GeometryReader { geometry in Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() } }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.task(id: url) {
            image = nil
            if let fallbackURL, let data = await PosterCache.shared.cachedData(for: fallbackURL), !Task.isCancelled { image = NSImage(data: data) }
            if let url, let data = try? await PosterCache.shared.data(for: url), !Task.isCancelled { image = NSImage(data: data) }
            if image == nil, let fallbackURL, let data = try? await PosterCache.shared.data(for: fallbackURL), !Task.isCancelled { image = NSImage(data: data) }
        }
    }
}
