import SwiftUI
import AppKit

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, library, sources, metadata, playback, audio, subtitles, language, shortcuts, about
    var id: String { rawValue }
    var title: String { switch self {
    case .general: "通用"; case .library: "媒体库"; case .sources: "文件与来源"; case .metadata: "元数据和封面"
    case .playback: "播放设置"; case .audio: "音频"; case .subtitles: "字幕"; case .language: "语言"
    case .shortcuts: "快捷键"; case .about: "关于 Velun"
    } }
}

struct AppSettingsView: View {
    @Bindable var library: Library
    @Bindable var playback: Playback
    @Bindable var sources: SourcesStore
    @Bindable var metadata: MetadataStore
    @AppStorage("app.appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("library.listMode") private var listMode = false
    @AppStorage("library.sort") private var sort = "recent"
    @AppStorage("library.posterWidth") private var posterWidth = 155.0
    @State private var page = SettingsPage.general
    @State private var showSources = false
    @State private var showTMDB = false
    private var options: Binding<PlayerOptions> {
        Binding(get: { playback.preferences.options }, set: { playback.preferences.options = $0 })
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("偏好设置").font(.system(size: 19, weight: .semibold)).padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 22)
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(SettingsPage.allCases) { item in
                            Button { page = item } label: {
                                Text(item.title).font(.system(size: 14, weight: page == item ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, minHeight: 43, alignment: .leading).padding(.horizontal, 14)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .background(page == item ? LumaTheme.ink.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                .accessibilityAddTraits(page == item ? .isSelected : [])
                        }
                    }.padding(.horizontal, 12)
                }
                Text("Velun").font(.caption).foregroundStyle(.secondary).padding(26)
            }.frame(width: 210).background(LumaTheme.surface)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(page.title).font(.system(size: 27, weight: .bold)).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
                    content
                }.padding(32).frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity)
            }.id(page).background(LumaTheme.canvas)
        }.frame(minWidth: 840, idealWidth: 960, minHeight: 620, idealHeight: 700)
            .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).colorScheme)
            .tint(.orange)
            .sheet(isPresented: $showSources) { SourcesView(store: sources, library: library, metadata: metadata).tint(.orange) }
            .sheet(isPresented: $showTMDB) { TMDBSettingsView(store: metadata, library: library).tint(.orange) }
            .onChange(of: playback.preferences.options) { _, _ in playback.applyPreferences() }
    }
    @ViewBuilder private var content: some View {
        switch page {
        case .general: general
        case .library: libraryPage
        case .sources: sourcesPage
        case .metadata: metadataPage
        case .playback: playbackPage
        case .audio: audioPage
        case .subtitles: subtitlesPage
        case .language: languagePage
        case .shortcuts: shortcutsPage
        case .about: aboutPage
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("外观") {
                HStack(spacing: 16) {
                    ForEach(AppAppearance.allCases) { theme in
                        Button { appearance = theme.rawValue } label: {
                            VStack(spacing: 10) {
                                HStack(spacing: 0) {
                                    RoundedRectangle(cornerRadius: 3).fill(theme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Capsule().fill(Color.orange).frame(width: 24, height: 4)
                                        HStack(spacing: 4) { ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 3).fill(theme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.08)) } }
                                    }.padding(8)
                                }.frame(height: 63).background(theme == .dark ? Color(white: 0.16) : Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(appearance == theme.rawValue ? Color.orange : Color.secondary.opacity(0.2), lineWidth: appearance == theme.rawValue ? 2 : 1))
                                HStack(spacing: 5) {
                                    Image(systemName: appearance == theme.rawValue ? "checkmark.circle.fill" : "circle").foregroundStyle(appearance == theme.rawValue ? Color.orange : .secondary)
                                    Text(theme.title)
                                }.font(.system(size: 12))
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(theme.title).accessibilityAddTraits(appearance == theme.rawValue ? .isSelected : [])
                    }
                }.padding(20)
            }
            card("显示") {
                toggle("使用列表视图", isOn: $listMode)
                separator
                row("海报大小") {
                    Slider(value: $posterWidth, in: 120...220, step: 5).frame(width: 170).accessibilityLabel("海报大小")
                    Text("\(Int(posterWidth))").monospacedDigit().foregroundStyle(.secondary).frame(width: 32)
                }
            }
            note("设置会自动保存，外观与媒体库显示选项立即生效。")
        }
    }
    private var libraryPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("媒体库") {
                row("作品") { value("\(library.groupedItems.count)") }; separator
                row("视频文件") { value("\(library.items.count)") }; separator
                row("文件来源") { value("\(sources.sources.count)") }
            }
            card("浏览") {
                row("默认排序") {
                    Picker("默认排序", selection: $sort) { Text("最近添加").tag("recent"); Text("名称").tag("name"); Text("年份").tag("year"); Text("评分").tag("rating") }.labelsHidden().frame(width: 150)
                }; separator
                action("管理文件来源") { page = .sources }
            }
            note("收藏、播放列表和观看进度保存在本机。重新扫描按来源与相对路径更新文件，保留已有海报及进度。")
        }
    }
    private var sourcesPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("共享与文件") {
                action("添加或管理来源", subtitle: "NAS、媒体服务器与本地文件夹") { showSources = true }
            }
            if !sources.sources.isEmpty {
                card("已保存的来源") {
                    ForEach(Array(sources.sources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 { separator }
                        row(source.name) { value(source.protocolTitle) }
                    }
                }
            }
            note("支持 SMB、NFS、WebDAV / Alist、FTP 系列、SFTP、DLNA，以及 Plex、Jellyfin、Emby。云盘暂不接入。")
            if sources.busy { Label(sources.status, systemImage: "arrow.triangle.2.circlepath").font(.callout).foregroundStyle(.secondary) }
        }
    }
    private var metadataPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("TMDB") {
                action("海报与影片信息", subtitle: metadata.configured ? "读取令牌已配置" : "配置读取访问令牌") { showTMDB = true }; separator
                toggle("自动匹配海报", isOn: Binding(get: { metadata.autoMatch }, set: { enabled in metadata.autoMatch = enabled; if enabled { metadata.matchMissing(library) } }))
            }
            card("匹配") {
                action(metadata.busy ? "停止自动匹配" : "查找未匹配的海报") {
                    if metadata.busy { metadata.cancel() } else { metadata.matchMissing(library, retryReviewed: true) }
                }.disabled(!metadata.configured)
            }
            if !metadata.status.isEmpty { note(metadata.status) }
            note("匹配时向 TMDB 发送清理后的片名和年份。模糊结果可在影片详情中手动修正；令牌保存在钥匙串。")
        }
    }
    private var playbackPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("播放") {
                toggle("自动播放下一集", isOn: $playback.autoAdvance).disabled(playback.preferences.options.repeatOne); separator
                toggle("循环播放当前视频", isOn: options.repeatOne); separator
                row("播放速度") {
                    Picker("播放速度", selection: options.speed) { ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { Text("\($0.formatted())×").tag($0) } }.labelsHidden().frame(width: 125)
                }
            }
            card("视频") {
                row("显示模式") { Picker("显示模式", selection: options.sizing) { ForEach(VideoSizing.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 150) }; separator
                row("画面比例") { Picker("画面比例", selection: options.aspect) { ForEach(VideoAspect.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 150) }; separator
                toggle("默认使用增强播放器", isOn: options.preferEnhancedPlayer)
            }
            card("HDR 与 Dolby Vision") {
                row("动态范围") {
                    Picker("动态范围", selection: Binding(get: { playback.preferences.options.hdrMode }, set: { playback.preferences.options.hdrOutput = $0 })) {
                        ForEach(HDRPlaybackMode.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 190)
                }; separator
                toggle("HDR / Atmos 优先使用系统播放器", isOn: Binding(get: { playback.preferences.options.nativeHDRPreferred }, set: { playback.preferences.options.preferNativeHDR = $0 }))
            }
            note("MKV 自动使用增强播放器。默认播放器在下次打开视频时生效；画面比例与字幕外观适用于增强播放器。")
            Button("恢复播放默认设置") { playback.resetSettings() }.buttonStyle(.bordered)
        }
    }
    private var audioPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("声音") {
                toggle("静音", isOn: options.muted); separator
                row("音量") {
                    Slider(value: options.volume, in: 0...100, step: 1).frame(width: 180).accessibilityLabel("默认音量")
                    value("\(Int(playback.preferences.options.volume))%")
                }
            }
            card("Dolby Atmos 与音频输出") {
                row("输出模式") {
                    Picker("输出模式", selection: Binding(get: { playback.preferences.options.audioMode }, set: { playback.preferences.options.audioOutput = $0 })) {
                        ForEach(AudioOutputMode.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 210)
                }; separator
                toggle("允许系统多声道空间音频", isOn: Binding(get: { playback.preferences.options.allowsSpatialAudio }, set: { playback.preferences.options.spatialAudio = $0 }))
            }
            note("Atmos 优先使用兼容的系统播放链路。增强播放器默认解码为 PCM；直通取决于接口与功放，直通时使用正常倍速且不应用声音增强。")
            card("语言") { audioLanguage }
            note("音轨切换和音画同步可在播放中的“播放设置”内调整。首选语言在下次打开视频时应用。")
        }
    }
    private var subtitlesPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("字幕") {
                toggle("默认开启字幕", isOn: options.subtitlesEnabled); separator
                subtitleLanguage
            }
            card("文字外观") {
                row("大小") { Slider(value: options.subtitleScale, in: 0.5...2, step: 0.05).frame(width: 170).accessibilityLabel("字幕大小"); value("\(Int(playback.preferences.options.subtitleScale * 100))%") }; separator
                row("颜色") { Picker("字幕颜色", selection: options.subtitleColor) { ForEach(SubtitleColor.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 130) }; separator
                toggle("覆盖 ASS 内置样式", isOn: options.overrideSubtitleStyle)
            }
            note("文字外观适用于增强播放器；图形字幕不支持修改文字颜色。外部字幕与时间同步在播放时设置。")
        }
    }
    private var languagePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("语言偏好") { audioLanguage; separator; subtitleLanguage }
            note("优先选择与语言偏好匹配的内嵌轨道，实际可选语言取决于视频文件。偏好在下次打开视频时应用。")
        }
    }
    private var audioLanguage: some View {
        row("首选音频语言") { Picker("首选音频语言", selection: options.audioLanguage) { ForEach(TrackLanguage.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 130) }
    }
    private var subtitleLanguage: some View {
        row("首选字幕语言") { Picker("首选字幕语言", selection: options.subtitleLanguage) { ForEach(TrackLanguage.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 130) }
    }
    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            card("应用") {
                shortcut("偏好设置", "⌘ ,"); separator; shortcut("导入视频", "⌘ O"); separator; shortcut("播放中的设置", "⌘ S")
            }
            card("增强播放器") {
                shortcut("播放 / 暂停", "空格"); separator; shortcut("后退 / 前进 10 秒", "← / →"); separator
                shortcut("降低 / 提高音量", "↓ / ↑"); separator; shortcut("全屏", "F"); separator; shortcut("退出全屏", "Esc")
            }
            note("播放器快捷键在播放画面获得键盘焦点时使用。")
        }
    }
    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                if let icon = NSApplication.shared.applicationIconImage {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 64, height: 64).accessibilityLabel("Velun 应用图标")
                }
                Text("Velun").font(.title.bold())
                Text("你的私人媒体库").foregroundStyle(.secondary)
            }.padding(.vertical, 8)
            card("关于") {
                row("版本") { value(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本") }; separator
                row("媒体信息") { value("The Movie Database") }
            }
            Link("访问 TMDB", destination: URL(string: "https://www.themoviedb.org")!)
            note("This product uses the TMDB API but is not endorsed or certified by TMDB.")
            note("播放组件：AVKit、libmpv / FFmpeg；文件传输：rclone。第三方许可随应用保存在 Resources/ThirdParty。")
        }
    }
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 15)
            VStack(spacing: 0, content: content).background(LumaTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(LumaTheme.ink.opacity(0.035)))
        }
    }
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16) { Text(title).font(.system(size: 14)); Spacer(minLength: 10); content() }
            .padding(.horizontal, 17).frame(minHeight: 50)
    }
    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        row(title) { Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(title) }
    }
    private func action(_ title: String, subtitle: String? = nil, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 14)); if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) } }
                Spacer(); Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 17).padding(.vertical, 13).frame(minHeight: 50).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var separator: some View { Divider().opacity(0.5).padding(.leading, 17) }
    private func note(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(4).padding(.horizontal, 15) }
    private func value(_ text: String) -> some View { Text(text).font(.system(size: 13)).foregroundStyle(.secondary) }
    private func shortcut(_ title: String, _ key: String) -> some View { row(title) { Text(key).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary) } }
}
