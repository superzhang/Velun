import SwiftUI
import AppKit

struct MPVControls: View {
    @Bindable var engine: MPVEngine
    @Bindable var preferences: PlaybackPreferences
    let extraControls: PlaybackExtraControls
    let previous: () -> Void
    let next: (() -> Void)?
    let settings: (Int) -> Void
    let interaction: (Bool) -> Void
    @State private var scrub = 0.0
    @State private var seeking = false
    @State private var menuTracking = false
    @State private var showTracks = false
    @State private var showRemaining = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    control(preferences.options.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: preferences.options.muted ? "取消静音" : "静音") { preferences.options.muted.toggle() }
                    Slider(value: $preferences.options.volume, in: 0...100).frame(width: 96).accessibilityLabel("音量")
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    control("backward.end.fill", label: engine.position > 3 ? "从头播放" : "上一集或从头播放", action: previous)
                    control("gobackward.10", label: "后退 10 秒") { engine.command("seek", "-10", "relative+exact") }
                    Button { engine.togglePause() } label: {
                        Image(systemName: engine.paused ? "play.fill" : "pause.fill").font(.system(size: 24, weight: .semibold)).frame(width: 50, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).keyboardShortcut(.space, modifiers: []).help(engine.paused ? "播放" : "暂停").accessibilityLabel(engine.paused ? "播放" : "暂停")
                    control("goforward.10", label: "前进 10 秒") { engine.command("seek", "10", "relative+exact") }
                    control("forward.end.fill", label: "下一集") { next?() }.disabled(next == nil).opacity(next == nil ? 0.3 : 1)
                }
                HStack(spacing: 8) {
                    control("captions.bubble", label: "字幕与音轨") { showTracks.toggle() }
                        .popover(isPresented: $showTracks, arrowEdge: .top) { tracks }
                    advancedMenu
                    extraControls
                    control("arrow.up.left.and.arrow.down.right", label: "全屏") { engine.surface?.window?.toggleFullScreen(nil) }
                    extraControls.episodeButton
                }.fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.shadow(color: .black.opacity(0.55), radius: 2, y: 1)
            HStack(spacing: 10) {
                Text(time(seeking ? scrub : engine.position)).frame(width: 62, alignment: .leading).accessibilityLabel("已播放 \(time(seeking ? scrub : engine.position))")
                Slider(value: Binding(get: { seeking ? scrub : engine.position }, set: { value in
                    scrub = value
                    if !seeking { engine.seek(value) }
                }), in: 0...max(engine.duration, 1), onEditingChanged: { editing in
                    if editing { scrub = engine.position }
                    seeking = editing
                    if !editing { engine.seek(scrub) }
                }).disabled(engine.duration <= 0).accessibilityLabel("播放进度").frame(height: 30)
                Button { showRemaining.toggle() } label: {
                    Text((showRemaining ? "−" : "") + time(showRemaining ? max(0, engine.duration - (seeking ? scrub : engine.position)) : engine.duration)).frame(width: 65, height: 30, alignment: .trailing).contentShape(Rectangle())
                }.buttonStyle(.plain).help("切换剩余时间 / 总时长").accessibilityLabel(showRemaining ? "剩余时间" : "总时长")
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
        }.padding(.horizontal, 17).padding(.vertical, 10).frame(maxWidth: 760)
             .background {
                ZStack {
                    if !reduceTransparency {
                        RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial).opacity(0.28)
                    }
                    RoundedRectangle(cornerRadius: 18).fill(.black.opacity(reduceTransparency ? 1 : 0.28))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 3).foregroundStyle(.white).tint(.white)
            .environment(\.colorScheme, .dark).padding(.horizontal, 28).padding(.bottom, 28)
            .onChange(of: seeking || showTracks || menuTracking) { _, busy in interaction(busy) }
            .onDisappear { interaction(false) }
    }
    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(width: 38, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
    private var advancedMenu: some View {
        PlayerAdvancedMenu(entries: menuEntries, interaction: { open in
            menuTracking = open; interaction(seeking || showTracks || open)
        }).frame(width: 38, height: 44)
            .background { Button("更多播放设置…") { settings(0) }.keyboardShortcut("s", modifiers: .command).hidden().accessibilityHidden(true) }
    }
    private var menuEntries: [PlayerMenuEntry] {
        let subtitles: [PlayerMenuEntry] = [
            .action("无", selected: engine.selectedSubtitle == "no") { engine.selectSubtitle("no") },
            .action("自动", selected: engine.selectedSubtitle == "auto") { engine.selectSubtitle("auto") }
        ] + engine.subtitles.map { track in .action(track.title, selected: engine.selectedSubtitle == track.id) { engine.selectSubtitle(track.id) } }
        let audio: [PlayerMenuEntry] = [.action("自动", selected: engine.selectedAudio == "auto") { engine.selectAudio("auto") }] + engine.audio.map { track in
            .action(track.title, selected: engine.selectedAudio == track.id) { engine.selectAudio(track.id) }
        }
        return [
            .heading("高级选项"),
            .submenu("字幕", subtitles + [.separator, .action("加载外部字幕…") { engine.addSubtitle() }, .action("字幕外观与同步…") { settings(2) }]),
            .submenu("音频", audio + [.separator, .action("音画同步…") { settings(1) }]),
            .submenu("播放速度", [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].map { speed in
                .action("\(speed.formatted())×", selected: abs(preferences.options.speed - speed) < 0.001, enabled: preferences.options.audioMode != .passthrough || speed == 1) { preferences.options.speed = speed }
            }),
            .submenu("声音增强", [0, 3, 6, 9].map { boost in
                .action(boost == 0 ? "关闭" : "+\(boost) dB", selected: (preferences.options.audioMode == .passthrough ? 0 : preferences.audioBoost) == boost, enabled: preferences.options.audioMode != .passthrough || boost == 0) { preferences.audioBoost = boost }
            }),
            .separator, .action("更多播放设置…", key: "s") { settings(0) }
        ]
    }
    private var tracks: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("字幕与音轨").font(.headline)
            Picker("音轨", selection: Binding(get: { engine.selectedAudio }, set: { engine.selectAudio($0) })) {
                Text("自动").tag("auto")
                ForEach(engine.audio) { Text($0.title).tag($0.id) }
            }
            Picker("字幕", selection: Binding(get: { engine.selectedSubtitle }, set: { engine.selectSubtitle($0) })) {
                Text("关闭字幕").tag("no"); Text("自动").tag("auto")
                ForEach(engine.subtitles) { Text($0.title).tag($0.id) }
            }
            Picker("播放速度", selection: $preferences.options.speed) {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
            Divider()
            Button("加载外部字幕…") { engine.addSubtitle() }
            Button("更多播放设置…") { showTracks = false; settings(2) }
        }.padding(20).frame(width: 340).preferredColorScheme(.dark).tint(.orange)
    }
    private func time(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, min(seconds, 359_999))) : 0
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
    }
}

struct NativeAdvancedMenu: View {
    @Bindable var playback: Playback
    let settings: (Int) -> Void
    var interaction: (Bool) -> Void = { _ in }
    var body: some View {
        PlayerAdvancedMenu(entries: entries, interaction: interaction)
            .frame(width: 40, height: 36).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
    private var entries: [PlayerMenuEntry] {
        let preferences = playback.preferences
        let subtitles: [PlayerMenuEntry] = [
            .action("无", selected: playback.nativeSubtitleID == -1) { playback.selectNativeSubtitle(-1) },
            .action("自动", selected: playback.nativeSubtitleID == Playback.automaticNativeSubtitle) { playback.selectNativeSubtitle(Playback.automaticNativeSubtitle) }
        ] + playback.nativeSubtitles.map { track in
            .action(track.title, selected: playback.nativeSubtitleID == track.id) { playback.selectNativeSubtitle(track.id) }
        }
        let audio: [PlayerMenuEntry] = [.action("自动", selected: playback.nativeAudioID == -1) { playback.selectNativeAudio(-1) }] + playback.nativeAudio.map { track in
            .action(track.title, selected: playback.nativeAudioID == track.id) { playback.selectNativeAudio(track.id) }
        }
        return [
            .heading("高级选项"),
            .submenu("字幕", subtitles + [.separator, .action("字幕设置…") { settings(2) }]),
            .submenu("音频", audio + [.separator, .action("音频设置…") { settings(1) }]),
            .submenu("播放速度", [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].map { speed in
                .action("\(speed.formatted())×", selected: abs(preferences.options.speed - speed) < 0.001) { preferences.options.speed = speed }
            }),
            .submenu("声音增强", [.action("切换增强播放器以启用…") { playback.useEnhancedPlayer() }]),
            .separator, .action("更多播放设置…", key: "s") { settings(0) }
        ]
    }
}
