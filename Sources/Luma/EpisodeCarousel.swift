import SwiftUI

struct EpisodeCarousel: View {
    let items: [EpisodeSlot]
    let info: [Int: EpisodeInfo]
    let selectedID: UUID
    let selectedSlot: EpisodeSlot?
    let sourceName: (Media) -> String?
    let seasons: [Int]
    @Binding var season: Int
    let loading: Bool
    let select: (Media) -> Void
    let play: (Media) -> Void
    let setWatched: (Media, Bool) -> Void
    let restart: (Media) -> Void
    @State private var scrollID: EpisodeSlot.ID?
    private let cardWidth: CGFloat = 200
    private let spacing: CGFloat = 16

    var body: some View {
        GeometryReader { _ in
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Picker("季", selection: $season) {
                        ForEach(seasons, id: \.self) { value in Text(value == 0 ? "特别篇" : "第 \(value) 季").tag(value) }
                    }.labelsHidden().fixedSize()
                    Text("\(items.count) 集").font(.subheadline).foregroundStyle(.secondary)
                    if let selectedSlot, selectedSlot.files.count > 1 {
                        Picker("片源", selection: Binding(
                            get: { selectedID },
                            set: { id in
                                if let file = selectedSlot.files.first(where: { $0.id == id }) { select(file) }
                            }
                        )) {
                            ForEach(selectedSlot.files) { file in
                                Text(versionTitle(file)).tag(file.id)
                            }
                        }.pickerStyle(.menu).frame(maxWidth: 360)
                    }
                    Spacer()
                    if loading { ProgressView().controlSize(.small).accessibilityLabel("正在读取单集信息") }
                }.padding(.horizontal, 32).frame(height: 44)
                HoverScrollRow {
                    LazyHStack(alignment: .top, spacing: spacing) {
                        ForEach(items) { slot in
                            let selected = slot.id == selectedSlot?.id
                            let item = slot.preferredFile(favoring: selected ? selectedID : nil)
                            EpisodeCard(item: item, info: info[slot.code.episode], selected: selected, watched: slot.isWatched) { select(item) }
                                .frame(width: cardWidth).id(slot.id)
                                .contextMenu {
                                    Button(item.isContinuing ? "继续播放" : "播放") { play(item) }.disabled(item.sourceMissing == true)
                                    Button("从头播放") { restart(item) }.disabled(item.sourceMissing == true)
                                    Divider()
                                    Button(slot.isWatched ? "标记为未观看" : "标记为已观看") { setWatched(item, !slot.isWatched) }
                                }
                        }
                    }.scrollTargetLayout().padding(.horizontal, 32).padding(.vertical, 5)
                }.scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $scrollID, anchor: .leading)
            }
        }.frame(height: 292)
            .onAppear { scrollID = selectedSlot?.id }
    }

    private func versionTitle(_ file: Media) -> String {
        let status = file.sourceMissing == true ? "（文件缺失）" : ""
        return file.url.lastPathComponent + (sourceName(file).map { " · \($0)" } ?? "") + status
    }
}

private struct EpisodeCard: View {
    let item: Media
    let info: EpisodeInfo?
    let selected: Bool
    let watched: Bool
    let select: () -> Void
    @State private var hovered = false
    private var code: EpisodeCode { EpisodeCode(item) }
    private var title: String {
        if let name = item.localMetadata?.episode?.title ?? info?.name, !name.isEmpty { return "\(code.episode). \(name)" }
        return code.episode > 0 ? "第 \(code.episode) 集" : item.title
    }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if let still = info?.still { PosterView(url: still) }
                    else {
                        LinearGradient(colors: [Color(white: 0.25), Color(white: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "play.rectangle").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.5))
                    }
                }.frame(height: 128).clipped()
                    .overlay(alignment: .topTrailing) {
                        if watched {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .black.opacity(0.55)).padding(8)
                        } else { UnwatchedCorner().fill(.orange).frame(width: 22, height: 22) }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if item.isContinuing {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Color.black.opacity(0.45)
                                    Color.orange.frame(width: geometry.size.width * item.progress)
                                }
                            }.frame(height: 4)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.orange : LumaTheme.ink.opacity(hovered ? 0.5 : 0.12), lineWidth: selected ? 3 : 1))
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .medium)).lineLimit(2, reservesSpace: true).foregroundStyle(.primary)
                HStack {
                    if item.sourceMissing == true { Text("文件缺失").foregroundStyle(.orange) }
                    else if item.isContinuing { Text("继续观看").foregroundStyle(.orange) }
                    else if watched { Text("已观看") }
                    else { Text("未观看") }
                    Spacer(minLength: 4)
                    if item.duration > 0 { Text("\(Int(item.duration / 60)) 分钟") }
                    else if let runtime = item.localMetadata?.episode?.runtime ?? info?.runtime, runtime > 0 { Text("\(runtime) 分钟") }
                }.font(.caption).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel("第 \(code.season) 季，\(title)，\(item.sourceMissing == true ? "文件缺失" : watched ? "已观看" : item.isContinuing ? "继续观看" : "未观看")")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help("选择本集后，点击上方播放；右键可直接播放")
    }
}
