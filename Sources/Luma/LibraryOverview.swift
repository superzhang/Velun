import SwiftUI

struct LibraryOverview: View {
    let groups: [MediaGroup]
    let sources: SourcesStore
    let metadata: MetadataStore
    let libraryError: String?
    let refreshingLocalMetadata: Bool
    @Binding var showLibraryShortcut: Bool
    let browse: (Destination) -> Void
    let manageSources: () -> Void
    let refreshLibrary: () -> Void
    let refreshMetadata: () -> Void
    let configureMetadata: () -> Void

    private var lastScan: Date? {
        sources.librarySources.compactMap(\.lastScan).max()
    }

    var body: some View {
        let folders = sources.starredSMBFolders.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        let seriesCount = groups.lazy.filter(\.isTV).count
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("媒体库概览")
                        .font(.system(size: 28, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    if let lastScan {
                        Text("最近扫描：\(lastScan.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("尚无扫描记录").foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 16) {
                    statistic("电影", count: groups.count - seriesCount, icon: "film", destination: .movies)
                    statistic("电视剧", count: seriesCount, icon: "tv", destination: .shows)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        heading("文件来源")
                        Spacer()
                        Button(action: manageSources) {
                            Label("管理来源", systemImage: "folder.badge.plus")
                        }
                    }

                    if folders.isEmpty {
                        Text("在共享目录中点星收藏的文件夹会显示在这里。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        ForEach(folders) { source in folderRow(source) }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    heading("显示与维护")
                    Toggle("在主屏幕显示媒体库入口", isOn: $showLibraryShortcut)
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))

                    HStack(spacing: 10) {
                        Button(action: refreshLibrary) { Label("刷新媒体库", systemImage: "arrow.clockwise") }
                            .disabled(sources.busy || sources.librarySources.isEmpty)
                            .help("重新扫描已纳入媒体库的来源")
                        Button(action: refreshMetadata) { Label("刷新元数据", systemImage: "text.badge.checkmark") }
                            .disabled(refreshingLocalMetadata || metadata.busy)
                            .help("重新读取单独导入视频的本地资料，并补全未匹配的 TMDB 信息")
                        if !metadata.configured || metadata.needsAttention {
                            Button("设置 TMDB…", action: configureMetadata)
                        }
                    }.controlSize(.large)

                    status
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
    }

    private func statistic(_ title: String, count: Int, icon: String, destination: Destination) -> some View {
        Button { browse(destination) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(count, format: .number)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: icon).font(.title3)
                }
                .foregroundStyle(LumaTheme.navigationAccent)
                HStack {
                    Text(title).font(.callout.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }.foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(LibraryStatisticButtonStyle())
        .accessibilityLabel("\(title)，\(count) 部")
        .accessibilityHint("打开\(title)分类")
    }

    private func folderRow(_ source: LibrarySource) -> some View {
        Toggle(isOn: Binding(
            get: { source.excludedFromLibrary != true },
            set: { sources.setLibraryInclusion($0, for: source.id) }
        )) {
            Text(source.url.lastPathComponent)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
        .accessibilityHint("控制此文件夹是否纳入媒体库")
        .help(sources.scanIssues[source.id]?.detail ?? source.url.absoluteString)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var status: some View {
        if sources.busy || refreshingLocalMetadata || metadata.busy || !sources.status.isEmpty || !metadata.status.isEmpty ||
            sources.error != nil || libraryError != nil {
            VStack(alignment: .leading, spacing: 8) {
                if sources.busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(sources.status)
                        Spacer()
                        Button("停止扫描") { sources.cancel() }
                    }
                } else if !sources.status.isEmpty {
                    Text(sources.status)
                }

                if refreshingLocalMetadata {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在检查本地资料…")
                    }
                } else if !metadata.status.isEmpty {
                    HStack {
                        if metadata.busy { ProgressView().controlSize(.small) }
                        Text(metadata.status)
                        if metadata.busy {
                            Spacer()
                            Button("停止匹配") { metadata.cancel() }
                        }
                    }
                }

                if let error = sources.error { Text(error).foregroundStyle(LumaTheme.warningText).textSelection(.enabled) }
                if let libraryError { Text(libraryError).foregroundStyle(LumaTheme.warningText).textSelection(.enabled) }
            }.font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct LibraryStatisticButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        configuration.label
            .background(LumaTheme.ink.opacity(configuration.isPressed ? 0.10 : hovered ? 0.05 : 0), in: shape)
            .background(LumaTheme.surface, in: shape)
            .overlay {
                shape.strokeBorder(
                    focused ? Color.accentColor : LumaTheme.ink.opacity(hovered ? 0.24 : 0.09),
                    lineWidth: focused ? 2 : 1
                ).allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
    }
}
