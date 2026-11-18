import AppKit
import SwiftUI
import OpenGL.GL3
import UniformTypeIdentifiers
import CMPV
import Observation
import QuartzCore

struct MPVTrack: Identifiable, Sendable {
    let id: String
    let title: String
    let reference: EnhancedTrackReference
    let externalURL: URL?
}
struct MPVChapter: Identifiable { let id: Int; let title: String; let time: Double }

@MainActor @Observable final class MPVEngine {
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var paused = false
    private(set) var loading = true
    private(set) var audio: [MPVTrack] = []
    private(set) var subtitles: [MPVTrack] = []
    private(set) var chapters: [MPVChapter] = []
    private(set) var currentChapter = -1
    private(set) var videoWidth = 0
    private(set) var videoHeight = 0
    private(set) var hardwareDecoder = ""
    private(set) var videoTransfer = ""
    private(set) var videoPrimaries = ""
    private(set) var audioCodec = ""
    private(set) var outputChannels = ""
    private(set) var outputAudioFormat = ""
    private(set) var dolbyVisionProfile = 0
    var hdrOutputActive = false
    var hdrMode: HDRPlaybackMode { initialOptions.hdrMode }
    var hdrOutputDescription: String {
        guard ["pq", "hlg"].contains(videoTransfer) || dolbyVisionProfile > 0 else { return "SDR" }
        return hdrOutputActive ? "HDR / EDR（PQ）" : "HDR → SDR 色调映射"
    }
    var settingsError: String?
    var audioDelay = 0.0
    private(set) var subtitleDelay = 0.0
    private var appliedBoost: Int?
    private var appliedProperties: [String: String] = [:]
    private var controlsVisible = true
    private var subtitlePosition = 100.0
    private let initialPaused: Bool
    private var initialOptions: PlayerOptions
    var decoder = ""
    var refreshTicks = 0
    var ended = false
    var selectedAudio = "auto"
    var selectedSubtitle = "auto"
    private var requestedSubtitle = "auto"
    private var memory: EnhancedPlaybackMemory
    private let memoryChanged: (EnhancedPlaybackMemory) -> Void
    private var didLoadFile = false
    private var restoredAudio = false
    private var restoredSubtitle = false
    var volume = UserDefaults.standard.object(forKey: "playback.volume") as? Double ?? 100
    var error: String?
    private(set) var handle: UnsafeMutableRawPointer?
    weak var surface: MPVSurfaceView?
    private var timer: Timer?
    private let url: URL
    private let resume: Double
    private let externalSubtitles: [String]
    private let indexedSubtitles: [String]
    init(url: URL, resume: Double, options: PlayerOptions = PlayerOptions(), paused: Bool = false,
         externalSubtitles: [URL] = [], memory: EnhancedPlaybackMemory = EnhancedPlaybackMemory(),
         headless: Bool = false, memoryChanged: @escaping (EnhancedPlaybackMemory) -> Void = { _ in }) {
        self.url = url; self.resume = resume; initialOptions = options; initialPaused = paused
        self.memory = memory
        self.memoryChanged = memoryChanged
        indexedSubtitles = externalSubtitles.map { $0.isFileURL ? $0.path : $0.absoluteString }
        var subtitles = externalSubtitles
        if case .track(let reference) = memory.subtitles, let local = reference.localSubtitleURL, local.isFileURL,
           !subtitles.contains(where: { $0.isFileURL && $0.standardizedFileURL == local.standardizedFileURL }) {
            subtitles.append(local)
        }
        self.externalSubtitles = subtitles.map { $0.isFileURL ? $0.path : $0.absoluteString }
        if let config = Bundle.module.url(forResource: "fonts", withExtension: "conf", subdirectory: "Resources") {
            setenv("FONTCONFIG_FILE", config.path, 1)
            setenv("XDG_CACHE_HOME", URL.cachesDirectory.appending(path: "Luma").path, 1)
        }
        handle = luma_create(headless ? 1 : 0)
        if handle == nil { error = "无法初始化 MKV 播放引擎。"; loading = false }
    }
    func start() {
        guard let handle else { return }
        apply(initialOptions)
        applySubtitleDelay(memory.subtitleDelay ?? 0)
        if memory.subtitles == .off { set("sid", "no") }
        set("pause", initialPaused ? "yes" : "no")
        for subtitle in externalSubtitles {
            _ = luma_add_external_subtitle(handle, subtitle)
        }
        let code = luma_load(handle, url.isFileURL ? url.path : url.absoluteString, resume)
        if code < 0 { error = "无法打开视频（\(code)）。"; loading = false; return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func poll() {
        guard let handle else { return }
        for _ in 0..<100 {
            var value = 0.0; var message: UnsafePointer<CChar>?
            let event = luma_event(handle, &value, &message)
            switch event {
            case 0: return
            case 1:
                loading = false
                didLoadFile = true
                restoreTracks()
                if !restoredSubtitle, requestedSubtitle == "auto" { autoSelectSidecar() }
            case 2: error = message.map { String(cString: $0) } ?? "视频解码失败"; loading = false
            case 3: if value.isFinite { position = max(0, value); refreshTicks = 12; surface?.needsDisplay = true }
            case 4: if value.isFinite { duration = max(0, value) }
            case 5: paused = value != 0
            case 6: loading = value != 0
            case 7:
                if let message { readTracks(UnsafeRawPointer(message)) }
                if didLoadFile { restoreTracks() }
            case 11: selectedAudio = message.map { String(cString: $0) } ?? "auto"
            case 12: selectedSubtitle = message.map { String(cString: $0) } ?? "no"
            case 13: decoder = message.map { String(cString: $0) } ?? ""
            case 14: if let message { readChapters(UnsafeRawPointer(message)) }
            case 15: currentChapter = Int(value)
            case 16: if value.isFinite { videoWidth = Int(value) }
            case 17: if value.isFinite { videoHeight = Int(value) }
            case 18: hardwareDecoder = message.map { String(cString: $0) } ?? ""
            case 19: settingsError = "此设置未能生效：" + (message.map { String(cString: $0) } ?? "播放器未接受设置")
            case 20: videoTransfer = message.map { String(cString: $0) } ?? ""; surface?.updateHDROutput()
            case 21: videoPrimaries = message.map { String(cString: $0) } ?? ""; surface?.updateHDROutput()
            case 22: audioCodec = message.map { String(cString: $0) } ?? ""
            case 23: outputChannels = message.map { String(cString: $0) } ?? ""
            case 24: outputAudioFormat = message.map { String(cString: $0) } ?? ""
            case 25: dolbyVisionProfile = Int(value)
            case 10: ended = value != 0
            default: break
            }
        }
    }
    private func readTracks(_ node: UnsafeRawPointer) {
        audio = []; subtitles = []
        let count = min(Int(luma_track_count(node)), 200)
        for i in 0..<count {
            func field(_ key: String) -> String { luma_track_string(node, Int32(i), key).map { String(cString: $0) } ?? "" }
            let id = String(luma_track_id(node, Int32(i)))
            let kind = field("type")
            let external = field("external-filename")
            let url = external.isEmpty ? nil : (external.hasPrefix("/") ? URL(filePath: external) : URL(string: external))
            let name = field("title")
            let language = field("lang")
            let codec = field("codec")
            let title = [name.isEmpty ? (url?.lastPathComponent ?? "") : name, language, codec].filter { !$0.isEmpty }.joined(separator: " · ")
            let reference = EnhancedTrackReference(id: id, language: language, title: name, codec: codec, externalName: url?.lastPathComponent)
            let track = MPVTrack(id: id, title: title.isEmpty ? "轨道 \(id)" : title, reference: reference, externalURL: url)
            if kind == "audio" { audio.append(track) }
            if kind == "sub" { subtitles.append(track) }
        }
    }
    private func restoreTracks() {
        if !restoredAudio, let id = memory.audio?.matchingID(in: audio) {
            restoredAudio = true
            set("aid", id)
        }
        if !restoredSubtitle, case .track(let reference) = memory.subtitles,
           let id = reference.matchingID(in: subtitles) {
            restoredSubtitle = true
            set("sid", id)
        }
    }

    private func autoSelectSidecar() {
        guard let handle else { return }
        for subtitle in indexedSubtitles {
            if luma_prefer_external_subtitle(handle, subtitle) != 0 { break }
        }
    }

    func selectAudio(_ id: String) {
        let track = audio.first { $0.id == id }
        guard id == "auto" || track != nil else { return }
        restoredAudio = true
        memory.audio = track?.reference
        set("aid", id)
        memoryChanged(memory)
    }

    func selectSubtitle(_ id: String) {
        switch id {
        case "auto": memory.subtitles = nil
        case "no": memory.subtitles = .off
        default:
            guard let track = subtitles.first(where: { $0.id == id }) else { return }
            var reference = track.reference
            if let file = track.externalURL, file.isFileURL, !indexedSubtitles.contains(file.path) {
                reference.localSubtitleURL = file
            }
            memory.subtitles = .track(reference)
        }
        restoredSubtitle = true
        set("sid", id == "auto" && !initialOptions.subtitlesEnabled ? "no" : id)
        memoryChanged(memory)
        if id == "auto", initialOptions.subtitlesEnabled, didLoadFile { autoSelectSidecar() }
    }

    func forgetFileChoices(options: PlayerOptions) {
        memory = EnhancedPlaybackMemory()
        restoredAudio = true
        restoredSubtitle = true
        apply(options)
        set("aid", "auto")
        set("sid", options.subtitlesEnabled ? "auto" : "no")
        applySubtitleDelay(0)
        if options.subtitlesEnabled, didLoadFile { autoSelectSidecar() }
        memoryChanged(memory)
    }

    private func readChapters(_ node: UnsafeRawPointer) {
        chapters = (0..<min(Int(luma_track_count(node)), 1000)).map { index in
            let title = luma_track_string(node, Int32(index), "title").map { String(cString: $0) } ?? ""
            return MPVChapter(id: index, title: title.isEmpty ? "章节 \(index + 1)" : title, time: luma_node_number(node, Int32(index), "time"))
        }
    }
    func apply(_ options: PlayerOptions) {
        initialOptions = options
        for (name, value) in options.mpvProperties where appliedProperties[name] != value {
            if name != "sid" || appliedProperties.isEmpty || memory.subtitles == nil { set(name, value) }
        }
        appliedProperties = options.mpvProperties
        subtitlePosition = options.sanitized().subtitlePosition
        updateSubtitlePosition()
        surface?.updateHDROutput()
    }
    func setControlsVisible(_ visible: Bool) { controlsVisible = visible; updateSubtitlePosition() }
    private func updateSubtitlePosition() { set("sub-pos", String(controlsVisible ? min(80, subtitlePosition) : subtitlePosition)) }
    func setAudioBoost(_ gain: Int) {
        let gain = initialOptions.audioMode == .passthrough ? 0 : gain
        guard appliedBoost != gain else { return }; appliedBoost = gain
        set("af", gain == 0 ? "" : "lavfi=[volume=\(gain)dB]")
    }
    func setAudioDelay(_ value: Double) { guard value.isFinite else { return }; audioDelay = min(10, max(-10, value)); set("audio-delay", String(audioDelay)) }
    func setSubtitleDelay(_ value: Double) {
        guard value.isFinite else { return }
        applySubtitleDelay(value)
        memory.subtitleDelay = subtitleDelay == 0 ? nil : subtitleDelay
        memoryChanged(memory)
    }
    private func applySubtitleDelay(_ value: Double) {
        subtitleDelay = value.isFinite ? min(30, max(-30, value)) : 0
        set("sub-delay", String(subtitleDelay))
    }
    func set(_ name: String, _ value: String) {
        refreshTicks = 12
        if name == "aid" { selectedAudio = value }
        if name == "sid" { requestedSubtitle = value; selectedSubtitle = value }
        if name == "volume", let number = Double(value) { volume = number; UserDefaults.standard.set(number, forKey: "playback.volume") }
        if let handle { _ = luma_set(handle, name, value) }
    }
    func command(_ name: String, _ value: String, _ second: String? = nil) {
        guard let handle else { return }
        if let second { _ = luma_command(handle, name, value, second) } else { _ = luma_command(handle, name, value, nil) }
    }
    func togglePause() { set("pause", paused ? "no" : "yes") }
    func seek(_ seconds: Double) { command("seek", String(max(0, seconds)), "absolute+exact") }
    func addSubtitle() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt", "sub", "sup"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "选择 SRT、ASS 或其他字幕文件。"
        if panel.runModal() == .OK, let url = panel.url { loadExternalSubtitle(url) }
    }
    func loadExternalSubtitle(_ url: URL) {
        guard url.isFileURL, let handle, luma_command(handle, "sub-add", url.path, "cached") >= 0 else { return }
        restoredSubtitle = true
        let local = indexedSubtitles.contains(url.path) ? nil : url
        memory.subtitles = .track(EnhancedTrackReference(externalName: url.lastPathComponent, localSubtitleURL: local))
        memoryChanged(memory)
    }
    func stop() {
        timer?.invalidate(); timer = nil
        surface?.shutdown()
        if let handle { luma_destroy(handle) }; handle = nil
    }
}

@MainActor final class MPVSurfaceView: NSView {
    let engine: MPVEngine
    private let videoLayer: MPVColorLayer
    private var timer: Timer?
    private var started = false
    var floatingSurface: Bool { videoLayer.resources?.floating ?? false }
    private var outputPlan: HDROutputPlan?
    private var screenObservers: [NSObjectProtocol] = []
    init?(engine: MPVEngine) {
        guard let handle = engine.handle, let resources = MPVGLResources(handle: handle) else { return nil }
        self.engine = engine
        videoLayer = MPVColorLayer(resources: resources)
        super.init(frame: .zero)
        layer = videoLayer; wantsLayer = true
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        engine.surface = self
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in screenObservers { NotificationCenter.default.removeObserver(observer) }; screenObservers = []
        if let window {
            for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeScreenProfileNotification] {
                screenObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.outputPlan = nil; self?.updateHDROutput() }
                })
            }
            videoLayer.contentsScale = window.backingScaleFactor
            updateHDROutput(); prepareOpenGL()
        }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
        outputPlan = nil; updateHDROutput()
    }
    override func layout() {
        super.layout()
        videoLayer.frame = bounds; videoLayer.setNeedsDisplay()
    }
    func prepareOpenGL() {
        guard !started else { return }; started = true
        engine.start()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshFrame() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func updateHDROutput() {
        let plan = HDROutputPlan.make(transfer: engine.videoTransfer, primaries: engine.videoPrimaries,
                                     headroom: Double(window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1),
                                     floatSurface: floatingSurface, mode: engine.hdrMode)
        guard outputPlan != plan else { return }; outputPlan = plan
        videoLayer.wantsExtendedDynamicRangeContent = plan.enabled
        switch plan.output {
        case .standard, .toneMapped:
            videoLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        case .extended:
            let colorName = plan.primaries == "display-p3" ? CGColorSpace.displayP3_PQ : CGColorSpace.itur_2100_PQ
            videoLayer.colorspace = CGColorSpace(name: colorName)
        }
        for (name, value) in plan.properties { engine.set(name, value) }
        engine.hdrOutputActive = plan.enabled
        videoLayer.setNeedsDisplay()
    }
    private func refreshFrame() {
        guard started else { return }
        if !engine.paused || engine.loading || engine.refreshTicks > 0 {
            videoLayer.setNeedsDisplay(); videoLayer.displayIfNeeded()
            engine.refreshTicks = max(0, engine.refreshTicks - 1)
        }
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { window?.toggleFullScreen(nil) }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: engine.togglePause()
        case 123: engine.command("seek", "-10", "relative+exact")
        case 124: engine.command("seek", "10", "relative+exact")
        case 125: engine.set("volume", String(max(0, engine.volume - 5)))
        case 126: engine.set("volume", String(min(100, engine.volume + 5)))
        case 53: if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        case 3: window?.toggleFullScreen(nil)
        default: super.keyDown(with: event)
        }
    }
    func shutdown() {
        for observer in screenObservers { NotificationCenter.default.removeObserver(observer) }; screenObservers = []
        timer?.invalidate(); timer = nil
        videoLayer.resources?.shutdown()
    }

}

struct MPVSurface: NSViewRepresentable {
    let engine: MPVEngine
    func makeNSView(context: Context) -> NSView {
        if let view = MPVSurfaceView(engine: engine) { return view }
        engine.error = "无法创建 OpenGL 视频窗口。"
        return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) { }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 1000, height: proposal.height ?? 600)
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) { (nsView as? MPVSurfaceView)?.shutdown() }
}
