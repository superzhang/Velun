import Foundation
import Testing
import CMPV
import AVFoundation
@testable import Luma

@Test @MainActor func playbackPreferencesPersistAndRecoverFromInvalidData() throws {
    let name = "Luma.Settings.Tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(38.0, forKey: "playback.volume")
    let preferences = PlaybackPreferences(defaults: defaults)
    #expect(preferences.options.volume == 38)
    preferences.audioBoost = 6
    preferences.options.speed = 1.5
    preferences.options.sizing = .fill
    preferences.options.subtitleScale = 1.25
    preferences.options.subtitleColor = .yellow
    let restored = PlaybackPreferences(defaults: defaults)
    #expect(restored.options == preferences.options)
    #expect(restored.audioBoost == 6)
    restored.reset()
    #expect(PlaybackPreferences(defaults: defaults).audioBoost == 0)
    #expect(PlaybackPreferences(defaults: defaults).options == PlayerOptions())
    defaults.set(Data("invalid json".utf8), forKey: "playback.options.v1")
    #expect(PlaybackPreferences(defaults: defaults).options.speed == 1)
}

@Test func playbackOptionsClampCorruptNumbersAndRestoreOriginalAspect() {
    var options = PlayerOptions()
    options.speed = .infinity; options.volume = -12; options.subtitleScale = 50
    options.subtitlePosition = .nan; options.rotation = 75
    let checked = options.sanitized()
    #expect(checked.speed == 1)
    #expect(checked.volume == 0)
    #expect(checked.subtitleScale == 2)
    #expect(checked.subtitlePosition == 100)
    #expect(checked.rotation == 0)
    #expect(checked.mpvProperties["video-aspect-override"] == "no")
    #expect(checked.mpvProperties["keepaspect"] == "yes")
    options.sizing = .stretch
    #expect(options.mpvProperties["keepaspect"] == "no")
    options.sizing = .fill
    #expect(options.mpvProperties["panscan"] == "1")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_SETTINGS_FIXTURE"] != nil))
func realDecoderAppliesSettingsTracksAndChapters() async throws {
    let file = try #require(ProcessInfo.processInfo.environment["LUMA_SETTINGS_FIXTURE"])
    let handle = try #require(luma_create(1)); defer { luma_destroy(handle) }
    #expect(luma_load(handle, file, 0) >= 0)
    var loaded = false; var chapterTimes: [Double] = []
    func poll() {
        for _ in 0..<100 {
            var number = 0.0; var data: UnsafePointer<CChar>?
            let event = luma_event(handle, &number, &data)
            if event == 0 { break }
            if event == 1 { loaded = true }
            if event == 2 || event == 19 { let message = data.map { String(cString: $0) } ?? "Engine failed"; Issue.record("\(message)") }
            if event == 14, let data {
                let node = UnsafeRawPointer(data)
                chapterTimes = (0..<Int(luma_track_count(node))).map { luma_node_number(node, Int32($0), "time") }
            }
        }
    }
    for _ in 0..<100 { poll(); if loaded && chapterTimes.count >= 2 { break }; try await Task.sleep(for: .milliseconds(50)) }
    #expect(loaded)
    #expect(chapterTimes.count == 2)
    #expect(chapterTimes.last == 20)
    func property(_ name: String) -> String {
        guard let value = luma_get(handle, name) else { return "" }
        defer { luma_free(value) }; return String(cString: value)
    }
    var options = PlayerOptions()
    options.speed = 1.25; options.volume = 42; options.muted = true; options.sizing = .fill
    options.aspect = .standard; options.rotation = 90; options.subtitleScale = 1.4
    options.subtitleColor = .yellow; options.overrideSubtitleStyle = true
    for (name, value) in options.mpvProperties { #expect(luma_set(handle, name, value) >= 0) }
    #expect(luma_set(handle, "af", "lavfi=[volume=6dB]") >= 0)
    #expect(luma_set(handle, "sub-delay", "0.5") >= 0)
    #expect(luma_set(handle, "audio-delay", "0.1") >= 0)
    #expect(luma_set(handle, "aid", "2") >= 0)
    #expect(luma_set(handle, "sid", "1") >= 0)
    try await Task.sleep(for: .milliseconds(200)); poll()
    #expect(Double(property("speed")) == 1.25)
    #expect(Double(property("volume")) == 42)
    #expect(property("mute") == "yes")
    #expect(Double(property("panscan")) == 1)
    #expect(Int(property("video-rotate")) == 90)
    #expect(abs((Double(property("video-aspect-override")) ?? 0) - 4.0 / 3) < 0.001)
    #expect(Double(property("sub-scale")) == 1.4)
    #expect(Double(property("sub-delay")) == 0.5)
    #expect(Double(property("audio-delay")) == 0.1)
    #expect(property("aid") == "2")
    #expect(property("sid") == "1")
    #expect(luma_command(handle, "seek", "20", "absolute+exact") >= 0)
    try await Task.sleep(for: .milliseconds(150)); poll()
    #expect((Double(property("time-pos")) ?? 0) >= 20)
    #expect(Int(property("chapter")) == 1)
    // A new video resets per-file track IDs and time offsets by creating a new engine.
    let fresh = try #require(luma_create(1)); defer { luma_destroy(fresh) }
    let delay = try #require(luma_get(fresh, "sub-delay")); defer { luma_free(delay) }
    #expect(Double(String(cString: delay)) == 0)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_NATIVE_FIXTURE"] != nil)) @MainActor
func nativeSettingsAndEnhancedSwitchPreservePlayback() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["LUMA_NATIVE_FIXTURE"])
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let name = "Luma.Native.Settings.Tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: folder) }
    let preferences = PlaybackPreferences(defaults: defaults)
    preferences.options.volume = 35; preferences.options.muted = true; preferences.options.speed = 1.25
    let library = Library(file: folder.appending(path: "library.json"))
    library.add([URL(filePath: path)])
    let playback = Playback(library: library, preferences: preferences)
    defer { playback.close() }
    playback.open(try #require(library.items.first))
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while (playback.loading || playback.player.currentItem?.status != .readyToPlay) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(playback.error == nil)
    #expect(!playback.loading)
    #expect(playback.mpv == nil)
    #expect(!playback.nativeAudio.isEmpty)
    #expect(playback.player.volume == 0.35)
    #expect(playback.player.defaultRate == 1.25)
    #expect(playback.player.isMuted)
    playback.player.volume = 0.6
    let volumeDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while abs(preferences.options.volume - 60) > 0.01 && ContinuousClock.now < volumeDeadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(abs(preferences.options.volume - 60) < 0.01)
    playback.player.pause()
    await playback.player.seek(to: CMTime(seconds: 6, preferredTimescale: 600))
    playback.useEnhancedPlayer()
    #expect(playback.mpv != nil)
    #expect(abs((playback.media?.position ?? 0) - 6) < 0.1)
    #expect(abs((library.items.first?.position ?? 0) - 6) < 0.1)
    #expect(playback.nativeAudio.isEmpty)
}
