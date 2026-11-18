import SwiftUI

struct MissingFilesView: View {
    let library: Library
    let sources: SourcesStore
    let metadata: MetadataStore
    let search: String

    @State private var original: Media?
    @State private var removal: Set<UUID> = []
    @State private var showRemoval = false
    @State private var notice = ""

    private struct SourceGroup: Identifiable {
        let id: UUID?
        let source: LibrarySource?
        let files: [Media]
        var name: String { source?.name ?? "来源已移除" }
    }

    private var groups: [SourceGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let missing = library.items.filter {
            $0.sourceMissing == true && (query.isEmpty || $0.title.localizedStandardContains(query) || $0.sourcePath.localizedStandardContains(query))
        }
        let saved = Dictionary(sources.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(grouping: missing, by: \.sourceID).map { id, files in
            SourceGroup(id: id, source: id.flatMap { saved[$0] }, files: files.sorted {
                $0.sourcePath.localizedStandardCompare($1.sourcePath) == .orderedAscending
            })
        }.sorted { left, right in
            let comparison = left.name.localizedStandardCompare(right.name)
            return comparison == .orderedSame ? (left.id?.uuidString ?? "") < (right.id?.uuidString ?? "") : comparison == .orderedAscending
        }
    }

    var body: some View {
        let groups = groups
        VStack(spacing: 0) {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "没有缺失文件" : "未找到缺失文件", systemImage: "magnifyingglass")
                } description: {
                    if !search.isEmpty { Text("试试搜索片名或原文件路径。") }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            section(group)
                        }
                    }.padding(28)
                }
            }
            if (!sources.busy && !sources.status.isEmpty) || sources.error != nil || !notice.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    if !notice.isEmpty { Text(notice) }
                    if !sources.busy && !sources.status.isEmpty { Text(sources.status) }
                    if let error = sources.error { Text(error).foregroundStyle(.orange) }
                }.font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: $original) { ReplacementFileSheet(original: $0, library: library) { notice = "已重新关联文件。" } }
            .alert("移除 \(removal.count) 条缺失记录？", isPresented: $showRemoval, presenting: removal) { ids in
                Button("取消", role: .cancel) {}
                Button("移除记录", role: .destructive) {
                    let count = library.removeMissing(ids)
                    notice = count > 0 ? "已移除 \(count) 条缺失记录。" : "这些记录已恢复或移除。"
                }
            } message: { _ in
                Text("此操作仅移除仍缺失的媒体库记录及其观看进度、收藏和播放列表关联。")
            }
    }

    private func requestRemoval(_ ids: Set<UUID>) {
        removal = ids
        showRemoval = true
    }

    private func section(_ group: SourceGroup) -> some View {
        Section {
            ForEach(group.files) { file in
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.localMetadata?.episode?.title ?? file.localMetadata?.work?.title ?? file.metadata?.title ?? file.title)
                            .lineLimit(1)
                        Text(file.sourcePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(file.sourcePath)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if group.source != nil {
                        Button("重新关联…") { original = file }
                            .accessibilityLabel("重新关联 \(file.sourcePath)")
                    }
                    Button("移除…") { requestRemoval([file.id]) }
                        .accessibilityLabel("移除 \(file.sourcePath) 的记录")
                }.frame(minHeight: 52)
            }
        } header: {
            HStack(spacing: 12) {
                Label(group.name, systemImage: "externaldrive")
                    .font(.headline).accessibilityAddTraits(.isHeader).lineLimit(1)
                Text("\(group.files.count) 个").foregroundStyle(.secondary).font(.callout)
                Spacer()
                if let source = group.source {
                    Button("重新扫描") {
                        notice = ""
                        sources.scan(source, library: library, metadata: metadata)
                    }.disabled(sources.busy)
                }
                if group.files.count > 1 {
                    Menu {
                        Button("移除当前列表的缺失记录…", role: .destructive) { requestRemoval(Set(group.files.map(\.id))) }
                    } label: {
                        Image(systemName: "ellipsis.circle").accessibilityHidden(true)
                    }.fixedSize().accessibilityLabel("\(group.name)的更多操作")
                }
            }.frame(minHeight: 44).padding(.top, 12).padding(.bottom, 4)
        }
    }
}

private struct ReplacementFileSheet: View {
    let original: Media
    let library: Library
    let onRelink: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var candidates: [Media] = []
    @State private var selection: UUID?
    @State private var error: String?

    var body: some View {
        let filtered = candidates.filter { search.isEmpty || $0.sourcePath.localizedStandardContains(search) }
        VStack(alignment: .leading, spacing: 14) {
            Text("选择替换文件").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(original.sourcePath).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            Text("关联后会把这条记录的观看进度、收藏和播放列表带到新路径。")
                .foregroundStyle(.secondary).font(.callout)
            TextField("搜索同一来源的文件", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索替换文件")
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "没有可替换的文件" : "未找到替换文件", systemImage: "film")
                } description: {
                    if search.isEmpty { Text("先重新扫描，让新路径进入媒体库。已有观看记录或收藏的文件会保留自己的记录。") }
                }
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { item in
                        Text(item.sourcePath).lineLimit(2).truncationMode(.middle).tag(item.id)
                    }
                }.listStyle(.inset)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("重新关联") {
                    guard let selection else { return }
                    do {
                        try library.relinkMissing(original.id, to: selection)
                        onRelink()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(!filtered.contains { $0.id == selection })
            }
        }.padding(24).frame(minWidth: 580, idealWidth: 680, minHeight: 420, idealHeight: 500)
            .task(id: library.revision) {
                let originalName = original.url.lastPathComponent
                candidates = library.replacements(for: original).sorted {
                    let left = $0.url.lastPathComponent.localizedStandardCompare(originalName) == .orderedSame
                    let right = $1.url.lastPathComponent.localizedStandardCompare(originalName) == .orderedSame
                    if left != right { return left }
                    return $0.sourcePath.localizedStandardCompare($1.sourcePath) == .orderedAscending
                }
            }
            .onChange(of: search) { _, _ in selection = nil; error = nil }
    }
}
