import SwiftUI
import AppKit

struct FeatureBanner: View {
    let group: MediaGroup
    let play: () -> Void
    let details: () -> Void
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let url = group.info?.backdrop ?? group.info?.poster { PosterView(url: url) }
            else { LinearGradient(colors: [LumaTheme.sidebar, LumaTheme.canvas], startPoint: .topTrailing, endPoint: .bottomLeading) }
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: LumaTheme.canvas.opacity(0.65), location: 0.4), .init(color: LumaTheme.canvas, location: 0.85), .init(color: LumaTheme.canvas, location: 1)], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [LumaTheme.canvas.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 14) {
                Text(group.resume.isContinuing ? "正在观看" : "从你的媒体库精选").font(.caption.weight(.semibold)).foregroundStyle(LumaTheme.ink.opacity(0.7))
                Text(group.title).font(.system(size: 36, weight: .bold)).lineLimit(2).frame(maxWidth: 650, alignment: .leading)
                HStack(spacing: 12) {
                    if let year = group.info?.year, !year.isEmpty { Text(year) }
                    Text(group.isTV ? "电视剧" : "电影")
                    if let rating = group.info?.rating, rating > 0 { Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(.orange) }
                }.font(.subheadline).foregroundStyle(LumaTheme.ink.opacity(0.75))
                if let overview = group.info?.overview, !overview.isEmpty { Text(overview).font(.system(size: 14)).lineLimit(2).frame(maxWidth: 600, alignment: .leading).foregroundStyle(LumaTheme.ink.opacity(0.8)) }
                HStack(spacing: 12) {
                    Button(action: play) { Label(group.resume.isContinuing ? "继续播放" : "播放", systemImage: "play.fill").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 24).padding(.vertical, 11).foregroundStyle(LumaTheme.canvas).background(LumaTheme.ink, in: Capsule()) }.buttonStyle(.plain)
                    Button(action: details) { Label("更多信息", systemImage: "info.circle").font(.system(size: 14, weight: .medium)).padding(.horizontal, 22).padding(.vertical, 11).background(LumaTheme.ink.opacity(0.15), in: Capsule()) }.buttonStyle(.plain)
                }.padding(.top, 4)
            }.padding(32)
        }.frame(height: 410).clipped()
    }
}

struct DetailView: View {
    let group: MediaGroup
    let library: Library
    let metadata: MetadataStore
    let playback: Playback
    let sourceName: String?
    let play: (Media) -> Void
    let match: (Media) -> Void
    let selectionChanged: (Media) -> Void
    @State private var detailWidth: CGFloat = 1000
    @State private var technical: MediaTechnicalInfo?
    private var dimensions: VideoDimensions? { technical?.dimensions }
    @State private var imdbRating: IMDbRating?
    @State private var season = -1
    @State private var selectedEpisodeID: UUID?
    @State private var fullOverview = false
    @State private var message = ""
    @State private var episodeInfo: [Int: EpisodeInfo] = [:]
    @State private var loadingEpisodes = false
    private var currentSeason: Int { seasons.contains(season) ? season : EpisodeCode(group.resume.url.lastPathComponent).season }
    private var seasons: [Int] { Set(group.items.map { EpisodeCode($0.url.lastPathComponent).season }).sorted() }
    private var episodes: [Media] { group.items.filter { EpisodeCode($0.url.lastPathComponent).season == currentSeason } }
    private var activeEpisode: Media {
        episodes.first { $0.id == selectedEpisodeID } ?? episodes.first { $0.id == group.resume.id } ?? episodes.first ?? group.resume
    }
    private var displayedItem: Media { group.isTV ? activeEpisode : group.representative }
    private var selectedInfo: EpisodeInfo? { group.isTV ? episodeInfo[EpisodeCode(activeEpisode.url.lastPathComponent).episode] : nil }
    private var overview: String? {
        if let value = selectedInfo?.overview, !value.isEmpty { return value }
        return group.info?.overview
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                if group.isTV { episodesSection }
                else if group.items.count > 1 { versionsSection }
                if let cast = group.info?.cast, !cast.isEmpty { castSection(cast) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("文件信息").font(.system(size: 20, weight: .semibold))
                    Text(sourceName.map { "在 \($0) 上" } ?? (displayedItem.url.isFileURL ? "本地文件" : "网络视频")).foregroundStyle(.secondary)
                    Text(displayedItem.url.lastPathComponent).font(.system(size: 13)).textSelection(.enabled)
                    HStack(spacing: 12) {
                        Text(displayedItem.format)
                        if displayedItem.duration > 0 { Text(time(displayedItem.duration)) }
                        Text(displayedItem.url.isFileURL ? "原文件播放" : "流媒体播放")
                    }.font(.caption).foregroundStyle(.secondary)
                    if displayedItem.url.isFileURL { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([displayedItem.url]) } }
                    if let dimensions { Text("视频分辨率：\(dimensions.width) × \(dimensions.height)（\(dimensions.badge)）").font(.caption).foregroundStyle(.secondary) }
                    if let technical { ForEach(Array(technical.audio.enumerated()), id: \.offset) { _, audio in Text(audio.title).font(.caption).foregroundStyle(.secondary) } }
                    if let info = group.info { Link("影片信息与图片来自 TMDB", destination: info.creditURL).font(.caption) }
                    if group.info?.imdbID != nil {
                        Link("IMDb 评分：个人非商业数据集 · 每日缓存", destination: URL(string: "https://data.imdb.com/non-commercial-datasets/")!).font(.caption)
                    }
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
                }.padding(.horizontal, 32).padding(.bottom, 32)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        .task(id: "\(group.id)-\(currentSeason)") {
            episodeInfo = [:]; message = ""
            guard group.isTV, let info = group.info else { return }
            loadingEpisodes = true
            defer { loadingEpisodes = false }
            do {
                let values = try await metadata.client.season(series: info.id, number: currentSeason, token: (try? await KeychainToken.readAsync()) ?? "")
                try Task.checkCancellation()
                episodeInfo = Dictionary(values.map { ($0.episode, $0) }, uniquingKeysWith: { old, _ in old })
            } catch is CancellationError { }
            catch { message = "单集信息暂不可用，可继续播放本地文件。" }
        }
        .onChange(of: displayedItem.id, initial: true) { _, _ in fullOverview = false; selectionChanged(displayedItem) }
        .task(id: group.info?.id) {
            guard let info = group.info, info.detailVersion != 2, metadata.configured else { return }
            do {
                let details = try await metadata.client.details(info, token: try await KeychainToken.readAsync())
                try Task.checkCancellation()
                library.applyMetadata(details, to: group.items.map(\.id))
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }
    private var detailBackdrop: URL? {
        guard let url = group.info?.backdrop ?? group.info?.poster else { return nil }
        // Preserve the full backdrop at its natural ratio and request a sharper detail image.
        guard url.host == "image.tmdb.org" else { return url }
        return URL(string: url.absoluteString.replacingOccurrences(of: "/t/p/w780/", with: "/t/p/w1280/")) ?? url
    }
    private var hero: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 170)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 30) {
                    heroActions.frame(width: 260)
                    heroInformation.frame(minWidth: 340, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 24) {
                    heroActions.frame(maxWidth: 340)
                    heroInformation
                }
            }.padding(.horizontal, 30).padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, minHeight: min(780, max(540, detailWidth * 9 / 16)), alignment: .bottom)
        .background {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if let url = detailBackdrop {
                        PosterView(url: url, fallbackURL: group.info?.backdrop ?? group.info?.poster).frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                    LinearGradient(stops: [.init(color: .black.opacity(0.08), location: 0), .init(color: .black.opacity(0.15), location: 0.45), .init(color: .black.opacity(0.75), location: 0.78), .init(color: .black.opacity(0.96), location: 1)], startPoint: .top, endPoint: .bottom)
                    LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                }
            }
        }.clipped().foregroundStyle(.white).environment(\.colorScheme, .dark)
        .task(id: displayedItem.id) {
            technical = nil
            do {
                let result = try await VideoProbe.shared.information(displayedItem)
                try Task.checkCancellation(); technical = result
            } catch { /* A missing badge never prevents playback. */ }
        }
        .task(id: group.info?.imdbID) {
            imdbRating = nil
            guard let id = group.info?.imdbID else { return }
            do {
                let result = try await IMDbRatings.shared.rating(id)
                try Task.checkCancellation(); imdbRating = result
            } catch { /* IMDb stays a link when its public dataset is unavailable. */ }
        }
    }
    private var heroActions: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let logo = group.info?.logo {
                AsyncImage(url: logo) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 100, alignment: .leading).shadow(color: .black.opacity(0.5), radius: 5, y: 2).accessibilityLabel(group.title)
                    } else { heroTitle }
                }
            } else { heroTitle }
            Button { play(group.isTV ? activeEpisode : group.resume) } label: {
                let item = group.isTV ? activeEpisode : group.resume
                HStack(spacing: 8) {
                    if !item.isContinuing { Image(systemName: "play.fill") }
                    Text(item.isContinuing ? "继续 \(time(item.position))" : "播放").monospacedDigit()
                }.font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 44)
                    .foregroundStyle(.black)
                    .background {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Color.white.opacity(0.6)
                                Color.white.frame(width: geometry.size.width * (item.isContinuing ? item.progress : 1))
                            }
                        }.clipShape(Capsule())
                    }.overlay(Capsule().stroke(.white.opacity(0.5)))
            }.buttonStyle(.plain).accessibilityLabel((group.isTV ? activeEpisode : group.resume).isContinuing ? "继续播放" : "播放")
            DetailActions(group: group, selected: displayedItem, library: library, playback: playback, match: match, heroStyle: true)
        }
    }
    private var heroTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title).font(.system(size: 29, weight: .bold)).lineLimit(3)
            if let original = group.info?.originalTitle, original != group.title {
                Text(original).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var heroInformation: some View {
        VStack(alignment: .leading, spacing: 13) {
            if group.isTV {
                let code = EpisodeCode(activeEpisode.url.lastPathComponent)
                Text("第 \(code.season) 季 · 第 \(code.episode) 集" + (selectedInfo?.name.isEmpty == false ? " - \(selectedInfo!.name)" : ""))
                    .font(.system(size: 20, weight: .bold)).lineLimit(2)
            }
            MetadataFlowLayout(spacing: 13, lineSpacing: 8) { technicalInformation; genreLabel }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
            if let overview, !overview.isEmpty {
                Text(overview).font(.system(size: 14, weight: .medium)).lineSpacing(3).lineLimit(fullOverview ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { fullOverview.toggle() }
                if fullOverview || overview.count > 100 {
                    Button(fullOverview ? "收起" : "更多") { fullOverview.toggle() }.buttonStyle(.plain).font(.caption).foregroundStyle(.white.opacity(0.65))
                }
            } else {
                Button("匹配影片信息…") { match(group.representative) }.buttonStyle(.plain)
            }
            HStack(spacing: 22) {
                if let rating = selectedInfo?.rating ?? group.info?.rating, rating > 0, let link = group.info?.creditURL {
                    Link(destination: link) {
                        HStack(spacing: 7) {
                            Text("TMDB").font(.system(size: 11, weight: .black)).foregroundStyle(.teal)
                            Text("\(Int((rating * 10).rounded()))%").font(.system(size: 16, weight: .semibold))
                        }
                    }.buttonStyle(.plain).help(group.isTV && selectedInfo?.rating != nil ? "TMDB 单集评分" : "TMDB 作品评分")
                }
                if let id = group.info?.imdbID, IMDbRating.validID(id), let url = URL(string: "https://www.imdb.com/title/\(id)/") {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Text("IMDb").font(.system(size: 10, weight: .black)).foregroundStyle(.black).padding(.horizontal, 4).frame(height: 20).background(.yellow, in: RoundedRectangle(cornerRadius: 2))
                            if let imdbRating { Text(String(format: "%.1f", imdbRating.score)).font(.system(size: 16, weight: .semibold)) }
                            else { Text("查看").font(.caption).foregroundStyle(.white.opacity(0.65)) }
                        }
                    }.buttonStyle(.plain).help("IMDb 作品评分 · \(imdbRating?.votes ?? 0) 人评价")
                }
                if let personal = displayedItem.personalRating { Label("\(personal)", systemImage: "star.fill").font(.caption).foregroundStyle(.white.opacity(0.65)).help("我的评分") }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var genreLabel: some View {
        if let genres = group.info?.genres, !genres.isEmpty { Text(genres.joined(separator: "，")).lineLimit(1) }
    }
    private var technicalInformation: some View {
        Group {
            if let runtime = group.isTV ? selectedInfo?.runtime : group.info?.runtime, runtime > 0 { Text(runtime >= 60 ? "\(runtime / 60)小时\(runtime % 60)分钟" : "\(runtime)分钟") }
            else if displayedItem.duration > 0 { Text("\(Int(displayedItem.duration / 60))分钟") }
            if let date = selectedInfo?.airDate ?? group.info?.releaseDate, !date.isEmpty { Text(date.replacingOccurrences(of: "-", with: "/")) }
            else if let year = group.info?.year, !year.isEmpty { Text(year) }
            if let certification = group.info?.certification { Text(certification).font(.system(size: 11, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.5))) }
            if let dimensions { Text(dimensions.badge).help("\(dimensions.width) × \(dimensions.height)") }
            if let label = technical?.hdrLabel { Text(label).font(.system(size: 11, weight: .bold)) }
            if technical?.hasAtmos == true { Text("Dolby Atmos").font(.system(size: 11, weight: .bold)).help("片源含 Atmos 音轨，实际输出请查看播放器设置") }
            Text(displayedItem.format).font(.system(size: 11, weight: .bold)).opacity(0.8)
        }
    }
    private var episodesSection: some View {
        EpisodeCarousel(items: episodes, info: episodeInfo, selectedID: activeEpisode.id, seasons: seasons,
                        season: Binding(get: { currentSeason }, set: { season = $0; selectedEpisodeID = nil }),
                        loading: loadingEpisodes, select: { selectedEpisodeID = $0.id }, play: play,
                        setWatched: { library.setWatched([$0.id], to: $1) }, restart: { item in
                            library.reset(item.id)
                            if let fresh = library.items.first(where: { $0.id == item.id }) { play(fresh) }
                        })
            .id("\(group.id)-\(currentSeason)")
    }
    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("可用文件").font(.system(size: 20, weight: .semibold))
            ForEach(group.items) { item in Button { play(item) } label: { HStack { Image(systemName: "play.circle").foregroundStyle(.orange); Text(item.url.lastPathComponent).lineLimit(1); Spacer(); Text(item.format).font(.caption).foregroundStyle(.secondary) }.padding(12).contentShape(Rectangle()) }.buttonStyle(.plain) }
        }.padding(.horizontal, 32)
    }
    private func castSection(_ cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("演职员").font(.system(size: 20, weight: .semibold)).padding(.horizontal, 32)
            HoverScrollRow {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(cast) { member in
                        VStack(alignment: .leading, spacing: 8) {
                            PosterView(url: member.photo).frame(width: 82, height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
                            Text(member.name).font(.caption.weight(.medium)).lineLimit(2)
                            Text(member.character).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(width: 82, alignment: .leading)
                    }
                }.padding(.horizontal, 32)
            }.scrollIndicators(.hidden)
        }
    }
    private func time(_ seconds: Double) -> String {
        let value = Int(seconds.isFinite ? max(0, seconds) : 0)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
    }
}
