import AVKit
import SwiftUI

enum PlaybackControlPanel { case airPlay, episodes }

struct PlaybackExtraControls: View {
    let playback: Playback
    @Binding var panel: PlaybackControlPanel?
    let height: CGFloat
    let routeInteraction: (Bool) -> Void

    var body: some View {
        if playback.mpv != nil {
            button("airplay.video", label: "隔空播放") { panel = .airPlay }
                .popover(isPresented: presented(.airPlay), arrowEdge: .top) { airPlayOptions }
        } else if !playback.loading, playback.error == nil {
            VideoAirPlayPicker(player: playback.player, interaction: routeInteraction)
                .frame(width: 38, height: height)
                .help("隔空播放")
                .accessibilityLabel("隔空播放")
        }
    }

    var episodeButton: some View {
        let episodes = playback.selectableEpisodes
        return Group {
            if let id = playback.media?.id, !episodes.isEmpty {
                button("list.bullet.rectangle", label: "选集") { panel = .episodes }
                    .popover(isPresented: presented(.episodes), arrowEdge: .top) {
                        PlaybackEpisodeList(items: episodes, currentID: id) { episode in
                            panel = nil
                            playback.selectEpisode(episode)
                        }
                    }
            }
        }
    }

    private func presented(_ value: PlaybackControlPanel) -> Binding<Bool> {
        Binding(get: { panel == value }, set: { if !$0, panel == value { panel = nil } })
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 38, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var airPlayOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("隔空播放", systemImage: "airplay.video").font(.headline)
            Text("兼容片源可切换到系统播放器，再点击隔空播放选择电视。")
                .fixedSize(horizontal: false, vertical: true)
            Button {
                playback.prepareAirPlay()
            } label: {
                if playback.preparingAirPlay { ProgressView().controlSize(.small) }
                else { Text("切换到系统播放器") }
            }
            .disabled(playback.preparingAirPlay)
            if let message = playback.airPlayMessage {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            Divider()
            Text("屏幕镜像")
                .font(.subheadline.weight(.semibold))
            Text("打开 macOS 控制中心里的「屏幕镜像」，选择电视。MKV、外挂字幕和增强播放器的画面也可以这样投屏。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct VideoAirPlayPicker: NSViewRepresentable {
    let player: AVPlayer
    let interaction: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(interaction: interaction) }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.player = player
        picker.delegate = context.coordinator
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.white, for: .normal)
        picker.setRoutePickerButtonColor(.white, for: .normalHighlighted)
        picker.setRoutePickerButtonColor(.systemOrange, for: .active)
        picker.setRoutePickerButtonColor(.systemOrange, for: .activeHighlighted)
        picker.toolTip = "隔空播放"
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        if picker.player !== player { picker.player = player }
        context.coordinator.interaction = interaction
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var interaction: (Bool) -> Void
        init(interaction: @escaping (Bool) -> Void) { self.interaction = interaction }
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { interaction(true) }
        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) { interaction(false) }
    }
}

private struct PlaybackEpisodeList: View {
    private struct Episode: Identifiable {
        let media: Media
        let code: EpisodeCode
        var id: UUID { media.id }
        var title: String { code.episode > 0 ? "第 \(code.episode) 集" : media.title }
    }

    private let seasons: [Int: [Episode]]
    let currentID: UUID
    let select: (UUID) -> Void
    @State private var season: Int

    init(items: [Media], currentID: UUID, select: @escaping (UUID) -> Void) {
        let episodes = items.map { Episode(media: $0, code: EpisodeCode($0)) }
        seasons = Dictionary(grouping: episodes, by: \.code.season)
        self.currentID = currentID
        self.select = select
        _season = State(initialValue: episodes.first { $0.id == currentID }?.code.season ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("选集").font(.headline)
                Spacer()
                if seasons.count > 1 {
                    Picker("季", selection: $season) {
                        ForEach(seasons.keys.sorted(), id: \.self) {
                            Text($0 == 0 ? "特别篇" : "第 \($0) 季").tag($0)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(season == 0 ? "特别篇" : "第 \(season) 季").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(seasons[season] ?? []) { episode in
                            row(episode).id(episode.id)
                        }
                    }
                }
                .onAppear { scroll.scrollTo(currentID, anchor: .center) }
                .onChange(of: season) { _, newSeason in
                    if let first = seasons[newSeason]?.first {
                        scroll.scrollTo(first.id, anchor: .top)
                    }
                }
            }
            .frame(height: CGFloat(min(seasons[season]?.count ?? 0, 7)) * 46)
        }
        .padding(12)
        .frame(width: 310)
    }

    private func row(_ episode: Episode) -> some View {
        let current = episode.id == currentID
        let status = current ? "当前集" : episode.media.isWatched ? "已观看" : episode.media.isContinuing ? "继续观看" : "未观看"
        return Button { select(episode.id) } label: {
            HStack(spacing: 9) {
                Image(systemName: current ? "play.fill" : episode.media.isWatched ? "checkmark" : "play")
                    .foregroundStyle(current ? Color.orange : .secondary)
                    .frame(width: 18)
                Text(episode.title).lineLimit(1)
                Spacer(minLength: 4)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 42)
            .background(current ? Color.orange.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(episode.title)，\(status)")
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
