import SwiftUI
import AppKit
import AVFoundation

enum Destination: Hashable {
    case home, libraryOverview, recent, all, movies, shows, unwatched, favorites, top, genres, unmatched, files, missing, source(UUID), playlist(String), collection(String)
    case performer(Int, String)
    var title: String {
        switch self { case .home: "主屏幕"; case .libraryOverview: "媒体库"; case .recent: "最近添加"; case .all: "全部视频"; case .movies: "电影"; case .shows: "电视剧"; case .unwatched: "未观看的"; case .favorites: "我的收藏"; case .top: "最受好评的电影"; case .genres: "电影类型"; case .unmatched: "待匹配"; case .files: "文件"; case .missing: "缺失文件"; case .source: "文件来源"; case .playlist(let name), .collection(let name), .performer(_, let name): name }
    }
}

struct RootView: View {
    private enum Page {
        case detail(UUID)
        case performer(CastMember)
    }

    @Bindable var library: Library
    @Bindable var playback: Playback
    @Bindable var sources: SourcesStore
    @Bindable var metadata: MetadataStore
    @Environment(\.openSettings) private var openSettings
    @State private var destination: Destination = .home
    @State private var returnsToLibraryOverview = false
    @State private var pages: [Page] = []
    @State private var performerCredits: [Int: Set<TMDBTitleID>] = [:]
    @State private var failedPerformerLookup: Int?
    @State private var performerGridAnchor: String?
    @State private var selectedDetailID: UUID?
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var queryCache = LibraryQueryCache()
    @State private var homeExpanded = false
    @State private var libraryExpanded = false
    @State private var filesExpanded = false
    @State private var selectedFileFolderID: UUID?
    @State private var sourcePanel: SourcePanelOpening?
    @State private var showTMDB = false
    @State private var matching: Media?
    @State private var finderError: String?
    @State private var locatingInFinder = false
    @State private var refreshingLocalMetadata = false
    @AppStorage("library.showHomeShortcut") private var showLibraryShortcut = true
    @AppStorage("library.listMode") private var listMode = false
    @AppStorage("files.listMode") private var filesInList = false
    @AppStorage("files.descendingNames") private var descendingFileNames = false
    @AppStorage("library.sort") private var sort = "recent"
    @State private var localOnly = false
    @State private var selectedGenre: String?
    @State private var gridAnchor: String?
    @State private var featuredMediaID: UUID?
    @AppStorage("library.posterWidth") private var posterWidth = 155.0
    private let background = LumaTheme.canvas
    private var detailID: UUID? {
        if case .detail(let id) = pages.last { return id }
        return nil
    }
    private var performer: CastMember? {
        if case .performer(let member) = pages.last { return member }
        return nil
    }
    private var excludedSourceIDs: Set<UUID> {
        switch destination {
        case .files, .missing, .source: []
        default: sources.excludedSourceIDs.union(sources.removedSourceIDs(in: library.referencedSourceIDs))
        }
    }
    private var detail: MediaGroup? {
        guard let detailID, let group = library.group(containing: detailID) else { return nil }
        let excluded = excludedSourceIDs
        if excluded.isEmpty { return group }
        let visible = group.items.filter { item in
            item.sourceID.map { !excluded.contains($0) } ?? true
        }
        if visible.count == group.items.count { return group }
        return visible.isEmpty ? nil : MediaGroup(id: group.id, items: visible)
    }
    private var showsLibraryOverview: Bool {
        destination == .libraryOverview && pages.isEmpty && search.isEmpty
    }
    private var fileWorkspace: Bool {
        switch destination {
        case .files, .source: true
        default: false
        }
    }
    private var fileSourceID: UUID? {
        if case .source(let id) = destination { return id }
        return nil
    }
    private var groups: [MediaGroup] {
        if let performer {
            return queryCache.groups(in: library, destination: .performer(performer.id, performer.name),
                                     localOnly: localOnly, sort: sort, excludedSourceIDs: excludedSourceIDs,
                                     castCredits: performerCredits[performer.id] ?? [])
        }
        return queryCache.groups(in: library, destination: destination, search: search, localOnly: localOnly, genre: selectedGenre, sort: sort, excludedSourceIDs: excludedSourceIDs)
    }
    var body: some View {
        ZStack {
            if playback.media == nil || fileWorkspace {
                HStack(spacing: 0) {
                    sidebar
                    if destination == .files {
                        filesHome
                    } else if let fileSourceID {
                        SourcesView(store: sources, library: library, metadata: metadata, play: playback.open,
                                    initialSourceID: fileSourceID, filter: search, backToFiles: { navigate(.files) },
                                    playQueue: playback.playQueue)
                            .id(fileSourceID)
                    } else {
                        VStack(spacing: 0) {
                            toolbar
                            Divider().opacity(0.25)
                            if let detail {
                                DetailView(group: detail, library: library, metadata: metadata, playback: playback,
                                           sourceName: { item in sources.sources.first { $0.id == item.sourceID }?.name },
                                           play: { playback.open($0) }, match: { matching = $0 },
                                           selectionChanged: { selectedDetailID = $0.id }, finderAction: finderAction,
                                           openPerformer: { member in
                                               performerGridAnchor = nil
                                               pages.append(.performer(member))
                                           })
                                    .id(detailID)
                            } else if performer != nil {
                                gridPage
                            } else if showsLibraryOverview { libraryOverview }
                            else if destination == .missing {
                                MissingFilesView(library: library, sources: sources, metadata: metadata, search: search)
                            }
                            else if destination == .genres && selectedGenre == nil && search.isEmpty { genrePage }
                            else if destination == .home && search.isEmpty { homePage }
                            else { gridPage }
                            if !showsLibraryOverview && (sources.busy || metadata.busy || library.error != nil || !metadata.configured || metadata.needsAttention) { activityBar }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(background)
                    }
                }
                .opacity(playback.media == nil ? 1 : 0)
                .allowsHitTesting(playback.media == nil)
                .accessibilityHidden(playback.media != nil)
            }
            if playback.media != nil { PlaybackView(playback: playback) }
        }
        .background(background)
        .sheet(item: $sourcePanel) { opening in
            SourcesView(store: sources, library: library, metadata: metadata, play: playback.open, opening: opening)
        }
        .sheet(isPresented: $showTMDB) { TMDBSettingsView(store: metadata, library: library).tint(.orange) }
        .sheet(item: $matching, onDismiss: recoverPlaybackHistory) { item in MatchView(media: item, library: library, store: metadata).tint(.orange) }
        .alert("无法在 Finder 中显示", isPresented: Binding(
            get: { finderError != nil }, set: { if !$0 { finderError = nil } }
        )) {
            Button("好", role: .cancel) { finderError = nil }
        } message: {
            Text(finderError ?? "")
        }
        .task {
            recoverPlaybackHistory()
            if metadata.autoMatch { metadata.matchMissing(library) }
        }
        .onChange(of: library.structureRevision) { _, _ in
            recoverPlaybackHistory()
            if metadata.autoMatch { metadata.matchMissing(library) }
        }
        .onChange(of: metadata.busy) { _, busy in if !busy { recoverPlaybackHistory() } }
        .onChange(of: sources.removedSourceIDs(in: library.referencedSourceIDs)) { _, _ in recoverPlaybackHistory() }
        .onChange(of: search) { _, value in if !value.isEmpty { pages.removeAll() } }
        .task(id: metadata.configured ? performer?.id : nil) {
            guard metadata.configured, let performer, performerCredits[performer.id] == nil else { return }
            failedPerformerLookup = nil
            do {
                let credits = try await metadata.client.castCredits(personID: performer.id, token: try await KeychainToken.readAsync())
                try Task.checkCancellation()
                performerCredits[performer.id] = credits
            } catch {
                if !Task.isCancelled { failedPerformerLookup = performer.id }
            }
        }
    }
    private func recoverPlaybackHistory() {
        library.recoverRetiredPlaybackHistory(from: sources.removedSourceIDs(in: library.referencedSourceIDs))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(fileWorkspace ? "搜索文件" : "搜索", text: $search).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel(fileWorkspace ? "搜索当前目录" : "搜索媒体库")
                if !search.isEmpty { Button { search = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill").frame(width: 32, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("清空搜索") }
            }.padding(.horizontal, 11).frame(height: 44)
                .background { Capsule().fill(LumaTheme.ink.opacity(0.085)).contentShape(Capsule()).onTapGesture { searchFocused = true } }
                .overlay(Capsule().stroke(LumaTheme.ink.opacity(0.1)).allowsHitTesting(false))
                .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 4) {
                    sidebarHeader("主屏幕", icon: "play", destination: .home, expanded: $homeExpanded)
                    if homeExpanded {
                        nav("每日精选", icon: "play.rectangle.on.rectangle", target: .home, indented: true)
                        nav("最近添加", icon: "clock.arrow.circlepath", target: .recent, indented: true)
                        nav("电影类型", icon: "square.stack.3d.up", target: .genres, indented: true)
                        nav("未观看的", icon: "eye.slash", target: .unwatched, indented: true)
                        nav("最受好评的电影", icon: "star", target: .top, indented: true)
                    }
                    sidebarHeader("媒体库", icon: "externaldrive", destination: .libraryOverview, expanded: $libraryExpanded)
                    if libraryExpanded {
                        nav("全部视频", icon: "square.grid.2x2", target: .all, indented: true)
                        nav("电影", icon: "film", target: .movies, indented: true)
                        nav("电视剧", icon: "tv", target: .shows, indented: true)
                        nav("我的收藏", icon: "heart", target: .favorites, indented: true)
                        nav("待匹配", icon: "questionmark.square", target: .unmatched, indented: true)
                    }
                    sidebarHeader("文件", icon: "folder", destination: .files, expanded: $filesExpanded)
                    if filesExpanded {
                        ForEach(sources.starredSMBFolders) { source in
                            nav(source.url.lastPathComponent, icon: "folder", target: .source(source.id), indented: true)
                        }
                    }
                }.padding(.horizontal, 12)
            }
            HStack {
                Button { openSettings() } label: {
                    Image(systemName: "gearshape").font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(SidebarButtonStyle()).accessibilityLabel("偏好设置").help("偏好设置（⌘,）")
                Spacer()
                Text("Velun").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }.frame(width: 250).background(LumaTheme.sidebar)
    }
    private func sidebarHeader(_ title: String, icon: String, destination target: Destination, expanded: Binding<Bool>) -> some View {
        let selected = pages.isEmpty && (destination == target || (target == .files && fileSourceID != nil))
            && (search.isEmpty || target == .files)
        return HStack(spacing: 0) {
            Button { navigate(target) } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon).foregroundStyle(LumaTheme.navigationAccent).accessibilityHidden(true)
                    Text(title).foregroundStyle(LumaTheme.ink.opacity(0.9)).lineLimit(1)
                }.font(.system(size: 15, weight: .semibold)).padding(.leading, 14)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(SidebarButtonStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            Button { expanded.wrappedValue.toggle() } label: {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(SidebarButtonStyle())
                .accessibilityLabel("展开或收起 \(title)")
                .accessibilityValue(expanded.wrappedValue ? "已展开" : "已收起")
        }.background(selected ? LumaTheme.ink.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
    }
    private func nav(_ title: String, icon: String, target: Destination, indented: Bool) -> some View {
        Button { navigate(target) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(LumaTheme.navigationAccent).frame(width: 22).accessibilityHidden(true)
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(LumaTheme.ink.opacity(0.9)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.leading, indented ? 30 : 14).padding(.trailing, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(SidebarButtonStyle(selected: destination == target && pages.isEmpty))
            .accessibilityAddTraits(destination == target && pages.isEmpty ? .isSelected : [])
    }
    private func navigate(_ target: Destination) {
        destination = target
        if case .source(let id) = target { selectedFileFolderID = id }
        returnsToLibraryOverview = false
        pages.removeAll()
        search = ""
        selectedGenre = nil
        gridAnchor = nil
        if target == .home { featuredMediaID = nil }
    }
    private func openDetail(_ group: MediaGroup) {
        selectedDetailID = nil
        pages.append(.detail(group.representative.id))
    }
    private var toolbar: some View {
        HStack(spacing: 18) {
            Button {
                if !pages.isEmpty {
                    pages.removeLast()
                    selectedDetailID = nil
                }
                else if selectedGenre != nil { selectedGenre = nil }
                else if returnsToLibraryOverview { navigate(.libraryOverview) }
                else { navigate(.home) }
            } label: { Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).frame(width: 28, height: 28) }.buttonStyle(.plain).disabled(pages.isEmpty && destination == .home).accessibilityLabel("返回").help("返回")
            if let detail { Text(detail.title).font(.headline).lineLimit(1) }
            else if let performer { Text(performer.name).font(.headline).lineLimit(1).accessibilityAddTraits(.isHeader) }
            else { Text(search.isEmpty ? (selectedGenre ?? destination.title) : "搜索结果").font(.headline) }
            Spacer()
            if pages.isEmpty && destination == .home && search.isEmpty && !sources.networkFileShares.isEmpty {
                let warningCount = sources.networkIssueCount
                if warningCount > 0 {
                    Button { navigate(.files) } label: {
                        Label("\(warningCount) 个共享需检查", systemImage: "exclamationmark.triangle")
                    }.help("查看来源状态")
                }
                Button {
                    sources.refreshNetwork(library: library, metadata: metadata)
                } label: {
                    Label("刷新 NAS", systemImage: "arrow.clockwise")
                }.disabled(sources.busy).help("扫描已连接的 NAS 共享")
            }
            if detailID == nil && !showsLibraryOverview && destination != .files && destination != .missing {
                Picker("显示范围", selection: $localOnly) { Text("全部").tag(false); Text("本地文件").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                Button { listMode.toggle() } label: { Image(systemName: listMode ? "square.grid.2x2" : "list.bullet").font(.system(size: 16)) }.buttonStyle(.plain).help(listMode ? "海报模式" : "列表模式").accessibilityLabel(listMode ? "海报模式" : "列表模式")
            }
            if let detail {
                DetailActions(group: detail, selected: detail.items.first { $0.id == selectedDetailID } ?? detail.resume, library: library, playback: playback, match: { matching = $0 })
            } else {
            Menu {
                if detailID == nil && !showsLibraryOverview && destination != .missing {
                    ControlGroup {
                        Button("缩小海报") { posterWidth = max(120, posterWidth - 15) }
                        Button("放大海报") { posterWidth = min(220, posterWidth + 15) }
                    }
                    Picker("排序", selection: $sort) { Text("最近添加").tag("recent"); Text("名称").tag("name"); Text("年份").tag("year"); Text("评分").tag("rating") }
                }
                Button("导入视频…") { Importer.files(library) }
                Button("添加文件…") { sourcePanel = .add }
                Button("TMDB 海报设置…") { showTMDB = true }
                Button("添加网络视频…") { sourcePanel = .directURL }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 19)) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多")
            }
        }.padding(.horizontal, 24).frame(height: 56)
    }
    private var libraryOverview: some View {
        let visibleGroups = queryCache.groups(in: library, destination: .libraryOverview, excludedSourceIDs: excludedSourceIDs)
        return LibraryOverview(
            groups: visibleGroups,
            sources: sources,
            metadata: metadata,
            libraryError: library.error,
            refreshingLocalMetadata: refreshingLocalMetadata,
            showLibraryShortcut: $showLibraryShortcut,
            browse: { target in
                navigate(target)
                libraryExpanded = true
                returnsToLibraryOverview = true
            },
            manageSources: { sourcePanel = .savedShares },
            refreshLibrary: { sources.refreshLibrary(library: library, metadata: metadata) },
            refreshMetadata: refreshLibraryMetadata,
            configureMetadata: { showTMDB = true }
        )
    }
    private func refreshLibraryMetadata() {
        guard !refreshingLocalMetadata, !metadata.busy else { return }
        refreshingLocalMetadata = true
        Task {
            await library.refreshLocalSidecars()
            refreshingLocalMetadata = false
            metadata.matchMissing(library, retryReviewed: true)
        }
    }
    private var filesHome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("文件").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                FileLayoutButton(listMode: $filesInList)
                Menu {
                    if let selected = sources.starredSMBFolders.first(where: { $0.id == selectedFileFolderID }),
                       search.isEmpty || selected.url.lastPathComponent.localizedStandardContains(search) {
                        Button("打开所选文件夹") { navigate(.source(selected.id)) }
                        Divider()
                    }
                    Picker("按名称排序", selection: $descendingFileNames) {
                        Text("升序").tag(false)
                        Text("降序").tag(true)
                    }
                    Divider()
                    Button("通过直接 URL") { sourcePanel = .directURL }
                    Button("下载") { sourcePanel = .downloads }
                    Button("本地视频与链接") { sourcePanel = .imported }
                    Button("缺失文件") { navigate(.missing) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 18))
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("文件更多操作")
                Button { sourcePanel = .add } label: {
                    Label("新增文件来源", systemImage: "plus")
                }.buttonStyle(.borderedProminent).tint(LumaTheme.navigationAccent).controlSize(.large)
            }.padding(.horizontal, 24).frame(height: 56)
            Divider().opacity(0.45)
            FileFavoritesPage(folders: sources.starredSMBFolders, filter: search, listMode: filesInList,
                              descendingNames: descendingFileNames, selectedFolderID: $selectedFileFolderID,
                              open: { navigate(.source($0.id)) },
                              addSource: { sourcePanel = .add })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(background)
    }
    private var isCustomList: Bool { switch destination { case .playlist, .collection: true; default: false } }
    private var gridPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if performer == nil && isCustomList {
                HStack {
                    Button("播放全部") { playback.playQueue(groups.flatMap { $0.playbackItems() }, shuffled: false, loop: false) }
                    Button("随机播放") { playback.playQueue(groups.flatMap { $0.playbackItems() }, shuffled: true, loop: false) }
                    Spacer()
                }.disabled(groups.isEmpty).padding(.horizontal, 28).padding(.top, 16)
            }
            if performer == nil && destination == .unmatched {
                HStack {
                    Text("\(groups.count) 个作品待确认 · 右键海报可编辑影片信息").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新自动匹配") { metadata.matchMissing(library, retryReviewed: true) }.disabled(metadata.busy || !metadata.configured)
                }.padding(.horizontal, 28).padding(.top, 16)
            }
        Group {
            if groups.isEmpty, let performer { emptyPerformerView(performer) }
            else if groups.isEmpty { emptyView }
            else if listMode {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groups) { group in
                            Button { openDetail(group) } label: {
                                HStack(spacing: 18) {
                                    PosterArtwork(media: group.representative, url: group.poster, fallbackURL: group.info?.poster).frame(width: 50, height: 75).clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 5) { Text(group.title).font(.headline); Text(group.subtitle).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    if group.isWatched { Image(systemName: "checkmark.circle").foregroundStyle(.orange) }
                                    if let rating = group.info?.rating { Label(String(format: "%.1f", rating), systemImage: "star.fill").font(.caption).foregroundStyle(.orange) }
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(12).contentShape(Rectangle())
                            }.buttonStyle(.plain).contextMenu { mediaMenu(group) }
                            Divider().opacity(0.3)
                        }
                    }.padding(24)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth, maximum: posterWidth + 35), spacing: 22)], alignment: .leading, spacing: 22) {
                        ForEach(groups) { group in posterCard(group) }
                    }.scrollTargetLayout().padding(28)
                }.scrollPosition(id: performer == nil ? $gridAnchor : $performerGridAnchor, anchor: .top)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var homePage: some View {
        let values = groups
        let movies = values.filter { !$0.isTV }
        let shows = values.filter(\.isTV)
        let favorites = values.filter(\.hasFavorite)
        let unwatched = values.filter { !$0.isWatched }
        let top = movies.filter { ($0.info?.rating ?? 0) > 0 }.sorted { ($0.info?.rating ?? 0) > ($1.info?.rating ?? 0) }
        let continuing = values.filter { $0.items.contains { $0.isContinuing || $0.watchlisted == true } }.sorted { $0.lastPlayed > $1.lastPlayed }
        var genreCounts: [String: Int] = [:]
        for movie in movies { for genre in Set(movie.genres) { genreCounts[genre, default: 0] += 1 } }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if let featured = values.first(where: { group in featuredMediaID.map { id in group.items.contains(where: { $0.id == id }) } ?? false }) ?? values.first(where: { $0.localBackdrop != nil || $0.info?.backdrop != nil }) ?? values.first {
                    FeatureBanner(group: featured, play: { playback.open(featured.resume) }, details: { openDetail(featured) }).onAppear { if featuredMediaID == nil { featuredMediaID = featured.representative.id } }
                }
                VStack(alignment: .leading, spacing: 14) {
                    homeSectionHeader("收藏夹")
                    HoverScrollRow {
                        LazyHStack(spacing: 16) {
                            if showLibraryShortcut {
                                homeShortcut("媒体库", icon: "square.stack.3d.up", detail: "\(values.count) 个作品", target: .all)
                            }
                            homeShortcut("电影", icon: "film", detail: "\(movies.count) 个作品", target: .movies)
                            homeShortcut("电视剧", icon: "tv", detail: "\(shows.count) 个系列", target: .shows)
                            homeShortcut("我的收藏", icon: "heart", detail: "\(favorites.count) 个作品", target: .favorites)
                            ForEach(library.playlistNames, id: \.self) { name in homeShortcut(name, icon: "list.bullet", detail: "播放列表", target: .playlist(name)) }
                            ForEach(library.collectionNames, id: \.self) { name in homeShortcut(name, icon: "square.stack", detail: "系列", target: .collection(name)) }
                            ForEach(sources.sources) { source in homeShortcut(source.name, icon: "folder", detail: source.protocolTitle, target: .source(source.id)) }
                        }.padding(.horizontal, 28).padding(.vertical, 4)
                    }.scrollIndicators(.hidden)
                }
                if !continuing.isEmpty { posterRow("正在观看", groups: Array(continuing.prefix(20))) }
                posterRow("每日精选", groups: Array(values.filter { $0.info != nil }.prefix(20)), target: .all)
                posterRow("最近添加", groups: Array(values.prefix(24)), target: .recent)
                VStack(alignment: .leading, spacing: 14) {
                    homeSectionHeader("电影类型", target: .genres)
                    if genreCounts.isEmpty { homeEmptyHint("匹配电影信息后，电影类型会显示在这里。") }
                    else {
                        HoverScrollRow {
                            LazyHStack(spacing: 16) {
                                ForEach(genreCounts.keys.sorted(), id: \.self) { genre in
                                    HomeCategoryCard(title: genre, icon: "film.stack", detail: "\(genreCounts[genre] ?? 0) 个作品") { navigate(.genres); selectedGenre = genre }
                                }
                            }.padding(.horizontal, 28).padding(.vertical, 4)
                        }.scrollIndicators(.hidden)
                    }
                }
                posterRow("未观看的", groups: Array(unwatched.prefix(20)), target: .unwatched, empty: "全部作品都已观看。新导入的视频会出现在这里。")
                posterRow("最受好评的电影", groups: Array(top.prefix(20)), target: .top, empty: "匹配 TMDB 评分后，会按评分从高到低展示电影。")
                posterRow("我的收藏", groups: Array(favorites.prefix(20)), target: .favorites, empty: "右键海报选择“加入收藏”，或在详情页点击爱心。")
                if !movies.isEmpty { posterRow("电影", groups: Array(movies.prefix(20)), target: .movies) }
                if !shows.isEmpty { posterRow("电视剧", groups: Array(shows.prefix(20)), target: .shows) }
                if values.isEmpty { emptyView }
            }.padding(.top, values.isEmpty ? 24 : 0).padding(.bottom, 32)
        }
    }
    private func homeShortcut(_ title: String, icon: String, detail: String, target: Destination) -> some View {
        HomeCategoryCard(title: title, icon: icon, detail: detail) { navigate(target) }
    }
    private func homeSectionHeader(_ title: String, target: Destination? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 20, weight: .semibold))
            Spacer()
            if let target {
                Button { navigate(target) } label: { Label("查看全部", systemImage: "chevron.right").font(.system(size: 13)).padding(.horizontal, 8).frame(height: 36).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("查看全部\(title)")
            }
        }.padding(.horizontal, 28)
    }
    private func homeEmptyHint(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .padding(20).background(LumaTheme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 28)
    }
    private func posterRow(_ title: String, groups values: [MediaGroup], target: Destination? = nil, empty: String = "暂无匹配的作品。") -> some View {
        VStack(alignment: .leading, spacing: 14) {
            homeSectionHeader(title, target: target)
            if values.isEmpty { homeEmptyHint(empty) }
            else {
                HoverScrollRow {
                    LazyHStack(alignment: .top, spacing: 20) { ForEach(values) { group in posterCard(group).frame(width: posterWidth) } }.padding(.horizontal, 28).padding(.bottom, 18)
                }.scrollIndicators(.hidden)
            }
        }
    }
    private func posterCard(_ group: MediaGroup) -> some View {
        LibraryPoster(group: group) { openDetail(group) }.contextMenu { mediaMenu(group) }
    }
    @ViewBuilder private func mediaMenu(_ group: MediaGroup) -> some View {
        Button(group.resume.isContinuing ? "继续播放" : "播放") { playback.open(group.resume) }
        Button("从头播放") { let item = group.resume; library.reset(item.id); if let fresh = library.items.first(where: { $0.id == item.id }) { playback.open(fresh) } }
        Button("查看详情") { openDetail(group) }
        Button(group.isWatched ? "标记为未观看" : "标记为已观看") { library.setWatched(group.items.map(\.id), to: !group.isWatched) }
        Button(group.hasFavorite ? "取消收藏" : "加入收藏") { library.setFavorite(group.items.map(\.id), to: !group.hasFavorite) }
        Button("编辑影片信息 / 海报…") { matching = group.representative }
        if let reveal = finderAction(group.representative) { Button("在 Finder 中显示", action: reveal) }
        Divider()
        Button("从媒体库移除", role: .destructive) { for item in group.items { library.remove(item.id) } }
    }
    private func finderAction(_ media: Media) -> (() -> Void)? {
        let source = sources.sources.first { $0.id == media.sourceID }
        guard FinderLocation.isAvailable(for: media, source: source) else { return nil }
        return {
            guard !locatingInFinder else { return }
            locatingInFinder = true
            Task {
                defer { locatingInFinder = false }
                do {
                    let file = try await FinderLocation.resolve(media, source: source)
                    let parent = file.deletingLastPathComponent()
                    let workspace = NSWorkspace.shared
                    guard workspace.selectFile(file.path, inFileViewerRootedAtPath: parent.path) || workspace.open(parent) else {
                        throw SourceWorker.failure("Finder 无法打开文件所在文件夹。")
                    }
                } catch {
                    finderError = error.localizedDescription
                }
            }
        }
    }
    private var genrePage: some View {
        let scope = groups
        let genres = Array(Set(scope.filter { !$0.isTV }.flatMap { $0.genres })).sorted()
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("电影类型").font(.system(size: 26, weight: .semibold))
                if genres.isEmpty { Text("匹配电影信息后，类型会自动显示在这里。").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 18)], spacing: 18) {
                    ForEach(genres, id: \.self) { genre in
                        Button { selectedGenre = genre } label: {
                            VStack(alignment: .leading, spacing: 20) {
                                Image(systemName: "film.stack").font(.system(size: 28, weight: .light)).foregroundStyle(.orange)
                                HStack { Text(genre).font(.title3.weight(.semibold)); Spacer(); Text("\(scope.filter { !$0.isTV && $0.genres.contains(genre) }.count)").foregroundStyle(.secondary) }
                            }.padding(24).background(LinearGradient(colors: [LumaTheme.ink.opacity(0.08), LumaTheme.ink.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(28)
        }
    }
    @ViewBuilder private func emptyPerformerView(_ performer: CastMember) -> some View {
        if metadata.configured && performerCredits[performer.id] == nil && failedPerformerLookup != performer.id {
            ProgressView("正在查找作品…")
        } else {
            ContentUnavailableView(localOnly ? "没有本地作品" : "媒体库中没有相关作品", systemImage: "film")
        }
    }
    private var emptyView: some View {
        ContentUnavailableView {
            Label(search.isEmpty ? "这里还没有视频" : "未找到相关视频", systemImage: search.isEmpty ? "play.rectangle.on.rectangle" : "magnifyingglass")
        } description: {
            Text(search.isEmpty ? "添加 NAS 文件来源，或导入本地视频。配置 TMDB 后会自动匹配海报。" : "试试修改片名或关键词。")
        } actions: {
            if search.isEmpty { Button("添加文件来源") { sourcePanel = .add }.buttonStyle(.borderedProminent); Button("导入视频") { Importer.files(library) } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var activityBar: some View {
        HStack {
            if sources.busy { ProgressView().controlSize(.small) }
            else if metadata.busy { ProgressView(value: Double(metadata.completed), total: Double(max(1, metadata.total))).frame(width: 100) }
            Text(library.error ?? (sources.busy ? sources.status : ((metadata.busy || metadata.needsAttention) ? metadata.status : "已导入 \(library.items.count) 个文件 · 配置 TMDB 后自动加载海报"))).font(.caption).lineLimit(2)
            Spacer()
            if !metadata.configured || metadata.needsAttention { Button("设置 TMDB…") { showTMDB = true } }
            if sources.busy { Button("停止扫描") { sources.cancel() } }
            else if metadata.busy { Button("停止匹配") { metadata.cancel() } }
            if metadata.configured { Button("查看待匹配") { navigate(.unmatched) } }
        }.padding(12).background(LumaTheme.ink.opacity(0.04))
    }

}

struct LibraryPoster: View {
    let group: MediaGroup
    let open: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                PosterArtwork(media: group.representative, url: group.poster, fallbackURL: group.info?.poster)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        if !group.isWatched { UnwatchedCorner().fill(.orange).frame(width: 28, height: 28).accessibilityLabel("未观看") }
                    }
                    .overlay(alignment: .bottom) {
                        if group.resume.isContinuing { GeometryReader { geometry in Color.orange.frame(width: geometry.size.width * group.resume.progress, height: 5).frame(maxHeight: .infinity, alignment: .bottom) } }
                    }
                    .overlay { if hovered { Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(.white).shadow(radius: 10) } }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(hovered ? 0.6 : 0), lineWidth: 2))
                Text(group.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).foregroundStyle(LumaTheme.ink.opacity(0.9))
                Text(group.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }.accessibilityLabel("查看 \(group.title)，\(group.subtitle)")
    }
}
struct UnwatchedCorner: Shape {
    func path(in rect: CGRect) -> Path { Path { path in path.move(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: rect.maxX, y: 0)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); path.closeSubpath() } }
}
struct PosterArtwork: View {
    let media: Media
    let url: URL?
    var fallbackURL: URL? = nil
    @State private var frame: NSImage?
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let url { PosterView(url: url, fallbackURL: url == fallbackURL ? nil : fallbackURL) }
            else if let frame {
                GeometryReader { geometry in Image(nsImage: frame).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
            } else {
                VStack(spacing: 16) { Image(systemName: "film").font(.system(size: 36, weight: .ultraLight)); Text(media.title).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 18) }.foregroundStyle(.white.opacity(0.55))
            }
        }.task(id: media.url) {
            guard url == nil, media.url.isFileURL else { return }
            // Avoid opening a video stream on a NAS merely to populate a poster grid.
            if media.sourceID != nil { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.url)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 400, height: 600)
            if let result = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)), !Task.isCancelled { frame = NSImage(cgImage: result.image, size: .zero) }
        }
    }
}

// Keep the hit shape inside the button label: transparent spacers and padding
// must receive the same action as the text. Hover/press feedback uses the same bounds.
struct SidebarButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        SidebarButtonSurface(label: configuration.label, selected: selected, pressed: configuration.isPressed)
    }
}
private struct SidebarButtonSurface<Label: View>: View {
    let label: Label
    let selected: Bool
    let pressed: Bool
    @State private var hovered = false
    var body: some View {
        label.contentShape(Rectangle())
            .background(LumaTheme.ink.opacity(pressed ? 0.2 : selected ? 0.14 : hovered ? 0.075 : 0), in: RoundedRectangle(cornerRadius: 9))
            .onHover { hovered = $0 }
    }
}

private struct HomeCategoryCard: View {
    let title: String
    let icon: String
    let detail: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.system(size: 32, weight: .light)).foregroundStyle(.orange).accessibilityHidden(true)
                Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 160, height: 125, alignment: .leading).padding(20)
                .background(LinearGradient(colors: [LumaTheme.ink.opacity(hovered ? 0.12 : 0.075), LumaTheme.ink.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(LumaTheme.ink.opacity(hovered ? 0.3 : 0.08)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }.accessibilityLabel("\(title)，\(detail)")
    }
}
