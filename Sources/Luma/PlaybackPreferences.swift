import Foundation
import Observation

enum VideoSizing: String, Codable, CaseIterable, Identifiable {
    case fit, fill, stretch
    var id: String { rawValue }
    var title: String { switch self { case .fit: "适应画面"; case .fill: "填满屏幕"; case .stretch: "拉伸铺满" } }
}
enum VideoAspect: String, Codable, CaseIterable, Identifiable {
    case original = "no", widescreen = "16:9", standard = "4:3", cinema = "2.35:1"
    var id: String { rawValue }
    var title: String { self == .original ? "原始比例" : rawValue }
}
enum SubtitleColor: String, Codable, CaseIterable, Identifiable {
    case white = "#FFFFFF", yellow = "#FFFF00", green = "#80FF80"
    var id: String { rawValue }
    var title: String { switch self { case .white: "白色"; case .yellow: "黄色"; case .green: "浅绿色" } }
}
enum TrackLanguage: String, Codable, CaseIterable, Identifiable {
    case automatic, chinese, english, japanese, korean
    var id: String { rawValue }
    var title: String { switch self { case .automatic: "自动"; case .chinese: "中文"; case .english: "英语"; case .japanese: "日语"; case .korean: "韩语" } }
    var mpvValue: String { switch self { case .automatic: ""; case .chinese: "zh-CN,zh,chi,zho"; case .english: "en,eng"; case .japanese: "ja,jpn"; case .korean: "ko,kor" } }
}

struct PlayerOptions: Codable, Equatable, Sendable {
    var speed = 1.0
    var sizing = VideoSizing.fit
    var aspect = VideoAspect.original
    var rotation = 0
    var volume = 100.0
    var muted = false
    var repeatOne = false
    var subtitlesEnabled = true
    var subtitleScale = 1.0
    var subtitlePosition = 100.0
    var subtitleColor = SubtitleColor.white
    var overrideSubtitleStyle = false
    var audioLanguage = TrackLanguage.automatic
    var subtitleLanguage = TrackLanguage.chinese
    var preferEnhancedPlayer = false
    // Optional fields keep saved pre-HDR settings compatible with synthesized Codable.
    var hdrOutput: HDRPlaybackMode?
    var audioOutput: AudioOutputMode?
    var spatialAudio: Bool?
    var preferNativeHDR: Bool?
    var hdrMode: HDRPlaybackMode { hdrOutput ?? .automatic }
    var audioMode: AudioOutputMode { audioOutput ?? .automatic }
    var allowsSpatialAudio: Bool { spatialAudio ?? true }
    var nativeHDRPreferred: Bool { preferNativeHDR ?? true }
    func sanitized() -> Self {
        var value = self
        func bounded(_ number: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double { number.isFinite ? min(range.upperBound, max(range.lowerBound, number)) : fallback }
        value.speed = bounded(speed, 0.5...2, fallback: 1)
        value.volume = bounded(volume, 0...100, fallback: 100)
        value.subtitleScale = bounded(subtitleScale, 0.5...2, fallback: 1)
        value.subtitlePosition = bounded(subtitlePosition, 50...100, fallback: 100)
        if ![0, 90, 180, 270].contains(rotation) { value.rotation = 0 }
        return value
    }
    var mpvProperties: [String: String] {
        let value = sanitized()
        var result = ["speed": String(value.speed), "volume": String(value.volume), "mute": value.muted ? "yes" : "no",
                "keepaspect": value.sizing == .stretch ? "no" : "yes", "panscan": value.sizing == .fill ? "1" : "0",
                "video-aspect-override": value.aspect.rawValue, "video-rotate": String(value.rotation),
                "loop-file": value.repeatOne ? "inf" : "no", "sub-scale": String(value.subtitleScale),
                "sub-color": value.subtitleColor.rawValue, "sub-ass-override": value.overrideSubtitleStyle ? "force" : "no",
                "sid": value.subtitlesEnabled ? "auto" : "no", "alang": value.audioLanguage.mpvValue, "slang": value.subtitleLanguage.mpvValue]
        result.merge(value.audioMode.mpvProperties) { _, new in new }
        if value.audioMode == .passthrough { result["speed"] = "1" }
        return result
    }
}

@MainActor @Observable final class PlaybackPreferences {
    private let defaults: UserDefaults
    private let key = "playback.options.v1"
    var audioBoost: Int {
        didSet { defaults.set(audioBoost, forKey: "playback.audioBoost") }
    }
    var options: PlayerOptions {
        didSet { if let data = try? JSONEncoder().encode(options.sanitized()) { defaults.set(data, forKey: key) } }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        audioBoost = defaults.integer(forKey: "playback.audioBoost")
        if let data = defaults.data(forKey: "playback.options.v1"), let saved = try? JSONDecoder().decode(PlayerOptions.self, from: data) { options = saved.sanitized() }
        else { var initial = PlayerOptions(); initial.volume = defaults.object(forKey: "playback.volume") as? Double ?? 100; options = initial.sanitized() }
    }
    func reset() { options = PlayerOptions(); audioBoost = 0 }
}
