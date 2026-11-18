import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

@main struct LumaApp: App {
    @NSApplicationDelegateAdaptor(LumaApplicationDelegate.self) private var appDelegate
    @AppStorage("app.appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("library.autoRefreshNAS") private var autoRefreshNAS = true
    @State private var library: Library
    @State private var sources = SourcesStore()
    @State private var metadata = MetadataStore()
    @State private var playback: Playback
    init() {
        let library = Library(backgroundSaving: true)
        let playback = Playback(library: library)
        LumaApplicationDelegate.prepareForTermination = {
            playback.close()
            await library.flush()
            await RemoteSources.shared.stopAll()
        }
        _library = State(initialValue: library)
        _playback = State(initialValue: playback)
    }
    var body: some Scene {
        WindowGroup("Velun") {
            RootView(library: library, playback: playback, sources: sources, metadata: metadata)
                .frame(minWidth: 1000, minHeight: 680)
                .preferredColorScheme(playback.media != nil ? .dark : (AppAppearance(rawValue: appearance) ?? .system).colorScheme)
                .tint(.orange)
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    library.add([url]); playback.open(library.items.first { $0.url == url }!)
                }
                .task { library.updateSourceLocality(await SourceWorker.sourceLocality(sources.sources)) }
                .task { await library.refreshLocalSidecars() }
                .task(id: autoRefreshNAS) {
                    guard autoRefreshNAS else { return }
                    do {
                        try await Task.sleep(for: .seconds(3))
                        while !Task.isCancelled {
                            let started = playback.media == nil && sources.refreshNetwork(library: library, metadata: metadata)
                            try await Task.sleep(for: .seconds(started ? 900 : 60))
                        }
                    } catch is CancellationError {
                        // The window closed or automatic refresh was switched off.
                    } catch { }
                }
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    if let index = args.firstIndex(of: "--play"), args.indices.contains(index + 1) {
                        let url = URL(filePath: args[index + 1]); library.add([url])
                        if let media = library.items.first(where: { $0.url == url }) { playback.open(media) }
                    }
                }

        }
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandMenu("外观") {
                Picker("主题", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("导入视频…") { Importer.files(library) }.keyboardShortcut("o")
            }
        }
        Settings {
            AppSettingsView(library: library, playback: playback, sources: sources, metadata: metadata)
        }

    }
}

@MainActor enum Importer {
    static func files(_ library: Library) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]
        panel.message = "添加本地视频，原文件会保留在原位置。"
        if panel.runModal() == .OK { library.add(panel.urls) }
    }
}


@MainActor final class LumaApplicationDelegate: NSObject, NSApplicationDelegate {
    static var prepareForTermination: (() async -> Void)?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await Self.prepareForTermination?()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
