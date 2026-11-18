import SwiftUI
import AVFoundation

struct PlayerSettingsView: View {
    @Bindable var playback: Playback
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Int
    init(playback: Playback, initialTab: Int = 0) { self.playback = playback; _tab = State(initialValue: initialTab) }
    var body: some View {
        @Bindable var preferences = playback.preferences
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("播放设置").font(.title2.weight(.semibold))
                    Text(playback.media?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Picker("设置分类", selection: $tab) {
                Text("视频").tag(0); Text("音频").tag(1); Text("字幕").tag(2); Text("播放").tag(3)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            Form {
                switch tab {
                case 0:
                    Section("画面") {
                        Picker("显示模式", selection: $preferences.options.sizing) { ForEach(VideoSizing.allCases) { Text($0.title).tag($0) } }
                        Picker("播放速度", selection: $preferences.options.speed) {
                            ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { Text("\($0.formatted())×").tag($0) }
                        }
                        if playback.mpv != nil {
                            Picker("画面比例", selection: $preferences.options.aspect) { ForEach(VideoAspect.allCases) { Text($0.title).tag($0) } }
                            Picker("旋转", selection: $preferences.options.rotation) { ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) } }
                        }
                    }
                    Section("HDR 与 Dolby Vision") {
                        Picker("动态范围", selection: Binding(get: { preferences.options.hdrMode }, set: { preferences.options.hdrOutput = $0 })) {
                            ForEach(HDRPlaybackMode.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("HDR / Atmos 优先使用系统播放器", isOn: Binding(get: { preferences.options.nativeHDRPreferred }, set: { preferences.options.preferNativeHDR = $0 }))
                        LabeledContent("片源", value: playback.technicalInfo?.hdrLabel ?? "SDR / 未标记")
                        LabeledContent("系统 HDR 显示能力", value: AVPlayer.eligibleForHDRPlayback ? "可用" : "当前不可用")
                        LabeledContent("当前画面输出", value: playback.mpv?.hdrOutputDescription ?? (preferences.options.hdrMode == .sdr ? "系统 SDR 色调映射" : "系统自动 HDR / Dolby Vision"))
                        if let technical = playback.technicalInfo, technical.dolbyVisionProfile != nil, playback.mpv != nil {
                            Text("增强引擎输出 HDR 兼容层，不是 Dolby Vision 动态元数据原样输出；Profile 7 FEL 不保证。兼容的 MP4 / MOV 使用系统链路。").font(.caption).foregroundStyle(.secondary)
                        }
                        if playback.technicalInfo?.dolbyVisionProfile != nil, playback.media?.url.pathExtension.lowercased() == "mkv" {
                            Button("创建系统兼容 MP4 副本…") { playback.exportNativeCompatibleCopy() }.disabled(playback.exportingCompatibility)
                            if !playback.compatibilityMessage.isEmpty { Text(playback.compatibilityMessage).font(.caption) }
                        }
                        Text("自动模式根据播放窗口所在屏幕启用 HDR；SDR 显示器使用色调映射。播放器优先选项在下次打开视频时生效。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let engine = playback.mpv {
                        Section("章节") {
                            if engine.chapters.isEmpty { Text("当前视频没有章节信息").foregroundStyle(.secondary) }
                            else {
                                Picker("跳转到章节", selection: Binding(get: { engine.currentChapter }, set: { index in if let chapter = engine.chapters.first(where: { $0.id == index }) { engine.seek(chapter.time) } })) {
                                    Text("选择章节").tag(-1)
                                    ForEach(engine.chapters) { Text($0.title).tag($0.id) }
                                }
                            }
                        }
                        Section("视频信息") {
                            LabeledContent("解码", value: engine.decoder.isEmpty ? "正在读取" : engine.decoder.uppercased())
                            if engine.videoWidth > 0 { LabeledContent("分辨率", value: "\(engine.videoWidth) × \(engine.videoHeight)") }
                            LabeledContent("硬件解码", value: engine.hardwareDecoder.isEmpty || engine.hardwareDecoder == "no" ? "软件解码" : engine.hardwareDecoder)
                        }
                    } else { enhancedPlayerSection }
                case 1:
                    Section("音频") {
                        Toggle("静音", isOn: $preferences.options.muted)
                        HStack { Text("音量"); Slider(value: $preferences.options.volume, in: 0...100).accessibilityLabel("音量"); Text("\(Int(preferences.options.volume))%").monospacedDigit().frame(width: 44) }
                        if let engine = playback.mpv {
                            Picker("音轨", selection: Binding(get: { engine.selectedAudio }, set: { engine.selectAudio($0) })) {
                                Text("自动").tag("auto")
                                ForEach(engine.audio) { Text($0.title).tag($0.id) }
                            }
                            Picker("声音增强", selection: $preferences.audioBoost) {
                                Text("关闭").tag(0); ForEach([3, 6, 9], id: \.self) { Text("+\($0) dB").tag($0) }
                            }
                            .disabled(preferences.options.audioMode == .passthrough)
                            delayControl("音画同步", value: Binding(get: { engine.audioDelay }, set: { engine.setAudioDelay($0) }), step: 0.1, bounds: -10...10)
                        } else if !playback.nativeAudio.isEmpty {
                            Picker("音轨", selection: Binding(get: { playback.nativeAudioID }, set: { playback.selectNativeAudio($0) })) {
                                Text("系统自动").tag(-1)
                                ForEach(playback.nativeAudio) { Text($0.title).tag($0.id) }
                            }
                        }
                    }
                    Section("Dolby Atmos 与输出") {
                        if playback.technicalInfo?.hasAtmos == true, playback.mpv != nil, playback.media?.url.pathExtension.lowercased() == "mkv" {
                            Button("使用系统 Atmos 链路（创建 MP4 副本）…") { playback.exportNativeCompatibleCopy() }.disabled(playback.exportingCompatibility)
                            if !playback.compatibilityMessage.isEmpty { Text(playback.compatibilityMessage).font(.caption) }
                        }
                        Picker("音频输出", selection: Binding(get: { preferences.options.audioMode }, set: { preferences.options.audioOutput = $0 })) {
                            ForEach(AudioOutputMode.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("允许系统多声道空间音频", isOn: Binding(get: { preferences.options.allowsSpatialAudio }, set: { preferences.options.spatialAudio = $0 }))
                        if let audio = playback.technicalInfo?.audio { ForEach(Array(audio.enumerated()), id: \.offset) { _, track in Text(track.title).font(.caption) } }
                        if let engine = playback.mpv {
                            LabeledContent("实际输出格式", value: engine.outputAudioFormat.isEmpty ? "正在读取" : engine.outputAudioFormat)
                            LabeledContent("实际输出声道", value: engine.outputChannels.isEmpty ? "正在读取" : engine.outputChannels)
                            Text(preferences.options.audioMode == .passthrough ? "请求压缩音频直通；能否输出 E-AC-3 / TrueHD 由 macOS、接口和功放共同决定。直通时声音增强不生效。" : "增强播放器解码为 PCM；TrueHD 可解码，但不会保留 Atmos 对象音效。").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("系统播放器负责兼容的 Dolby Digital Plus / Atmos 与空间音频，效果取决于当前声卡、HDMI 或耳机。格式标签表示片源，不表示已输出 Atmos。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("语言偏好") {
                        Picker("首选音频语言", selection: $preferences.options.audioLanguage) { ForEach(TrackLanguage.allCases) { Text($0.title).tag($0) } }
                        Text("为当前视频选过的音轨会在下次播放时恢复。").font(.caption).foregroundStyle(.secondary)
                    }
                    if playback.mpv == nil { enhancedPlayerSection }
                case 2:
                    Section("字幕轨道") {
                        if let engine = playback.mpv {
                            Picker("字幕", selection: Binding(get: { engine.selectedSubtitle }, set: { engine.selectSubtitle($0) })) {
                                Text("自动").tag("auto"); Text("关闭字幕").tag("no")
                                ForEach(engine.subtitles) { Text($0.title).tag($0.id) }
                            }
                            Button("加载外部字幕…") { engine.addSubtitle() }
                            delayControl("字幕同步", value: Binding(get: { engine.subtitleDelay }, set: { engine.setSubtitleDelay($0) }), step: 0.5, bounds: -30...30)
                        } else {
                            Picker("字幕", selection: Binding(get: { playback.nativeSubtitleID }, set: { playback.selectNativeSubtitle($0) })) {
                                Text("自动").tag(Playback.automaticNativeSubtitle); Text("关闭字幕").tag(-1)
                                ForEach(playback.nativeSubtitles) { Text($0.title).tag($0.id) }
                            }
                        }
                    }
                    if playback.mpv != nil {
                        Section("字幕外观") {
                            HStack { Text("大小"); Slider(value: $preferences.options.subtitleScale, in: 0.5...2, step: 0.05).accessibilityLabel("字幕大小"); Text("\(Int(preferences.options.subtitleScale * 100))%").monospacedDigit().frame(width: 44) }
                            HStack { Text("垂直位置"); Slider(value: $preferences.options.subtitlePosition, in: 50...100, step: 1).accessibilityLabel("字幕垂直位置"); Text("\(Int(preferences.options.subtitlePosition))%").monospacedDigit().frame(width: 44) }
                            Picker("颜色", selection: $preferences.options.subtitleColor) { ForEach(SubtitleColor.allCases) { Text($0.title).tag($0) } }
                            Toggle("覆盖 ASS 内置样式", isOn: $preferences.options.overrideSubtitleStyle)
                            Text("图形字幕不支持修改文字颜色；ASS 默认保留内置样式。显示控制栏时字幕会自动上移。").font(.caption).foregroundStyle(.secondary)
                        }
                    } else { enhancedPlayerSection }
                    Section("语言偏好") {
                        Toggle("默认开启字幕", isOn: $preferences.options.subtitlesEnabled)
                        Picker("首选字幕语言", selection: $preferences.options.subtitleLanguage) { ForEach(TrackLanguage.allCases) { Text($0.title).tag($0) } }
                        Text("选过的字幕会在下次播放当前视频时恢复。增强播放器也会记住字幕同步偏移。").font(.caption).foregroundStyle(.secondary)
                    }
                default:
                    Section("片头片尾") {
                        Toggle("自动识别片头片尾", isOn: $playback.autoSkipEnabled)
                        Text("优先读取章节标记；无标记时用同季三集的重复音频交叉确认，只有单一可信候选才显示“跳过重复片段”。片尾显示下一集按钮，保留彩蛋选择。首次分析会读取三集的部分音频。")
                            .font(.caption).foregroundStyle(.secondary)
                        if !playback.skipAnalysis.isEmpty { Text(playback.skipAnalysis).font(.caption).foregroundStyle(.secondary) }
                    }
                    Section("连续播放") {
                        Toggle("自动播放下一集", isOn: $playback.autoAdvance).disabled(preferences.options.repeatOne)
                        Toggle("循环播放当前视频", isOn: $preferences.options.repeatOne)
                    }
                    Section("播放器") {
                        Toggle("默认使用增强播放器", isOn: $preferences.options.preferEnhancedPlayer)
                        Text("增强播放器支持画面旋转、比例、字幕外观与时间同步；系统播放器支持画中画。默认选项在下次打开视频时应用。").font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Text("倍速、画面和字幕偏好会自动记忆；音画与字幕同步偏移仅作用于当前视频。").font(.caption).foregroundStyle(.secondary)
                        Button("恢复默认设置") { playback.resetSettings() }
                    }
                }
                if let engine = playback.mpv, let error = engine.settingsError {
                    Section { Text(error).foregroundStyle(.orange); Button("清除提示") { engine.settingsError = nil } }
                }
            }.formStyle(.grouped)
        }.frame(width: 600, height: 650)
    }
    private var enhancedPlayerSection: some View {
        Section {
            Button("切换到增强播放器") { playback.useEnhancedPlayer() }
            Text("保留当前进度，开启更多画面、音频和字幕设置。增强播放器暂不支持画中画。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func delayControl(_ title: String, value: Binding<Double>, step: Double, bounds: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: value, in: bounds, step: step) { Text(String(format: "%+.1f 秒", value.wrappedValue)).monospacedDigit() }.fixedSize().accessibilityLabel(title)
            Button("重置") { value.wrappedValue = 0 }.disabled(value.wrappedValue == 0)
        }
    }
}
