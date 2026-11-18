import Foundation
import Testing
import AVFoundation
@testable import Luma

@Test func playbackMemoryFindsReorderedAndReconnectedTracks() {
    let german = EnhancedTrackReference(id: "1", language: "deu", title: "German", codec: "aac")
    let newGerman = EnhancedTrackReference(id: "2", language: "deu", title: "German", codec: "aac")
    let other = EnhancedTrackReference(id: "1", language: "eng", title: "English", codec: "aac")
    let tracks = [
        MPVTrack(id: "1", title: "English", reference: other, externalURL: nil),
        MPVTrack(id: "2", title: "German", reference: newGerman, externalURL: nil)
    ]
    #expect(german.matchingID(in: tracks) == "2")
    #expect(german.matchingID(in: [tracks[0]]) == nil)
    let subtitle = EnhancedTrackReference(id: "5", externalName: "影片.zh.srt")
    let updated = MPVTrack(id: "8", title: "中文", reference: subtitle, externalURL: URL(string: "http://127.0.0.1:57313/new/影片.zh.srt"))
    #expect(subtitle.matchingID(in: [updated]) == "8")
}

@Test @MainActor func playbackMemoryIsSavedByFileAndClearedWhenSetToAutomatic() throws {
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let database = folder.appending(component: "library.json")
    let library = Library(file: database)
    library.add([folder.appending(component: "One.mp4"), folder.appending(component: "Two.mp4")])
    let first = try #require(library.items.first)
    let second = try #require(library.items.last)
    let enhanced = EnhancedPlaybackMemory(audio: EnhancedTrackReference(id: "2"), subtitles: .off, subtitleDelay: -1.5)
    library.updatePlaybackMemory(for: first.id) { $0.nativeSubtitles = .off; $0.enhanced = enhanced }

    let reopened = Library(file: database)
    #expect(reopened.playbackMemory(for: first.id).enhanced == enhanced)
    #expect(reopened.playbackMemory(for: first.id).nativeSubtitles == .off)
    #expect(reopened.playbackMemory(for: second.id) == FilePlaybackMemory())
    reopened.updatePlaybackMemory(for: first.id) { $0.nativeSubtitles = nil; $0.enhanced = EnhancedPlaybackMemory() }
    #expect(Library(file: database).items.first?.playbackMemory == nil)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VELUN_TRACK_MEMORY_MKV"] != nil)) @MainActor
func enhancedPlayerRestoresAudioManualSubtitleAndDelay() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VELUN_TRACK_MEMORY_MKV"])
    let video = URL(filePath: path)
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let previousVolume = UserDefaults.standard.object(forKey: "playback.volume")
    defer {
        UserDefaults.standard.set(previousVolume, forKey: "playback.volume")
        try? FileManager.default.removeItem(at: folder)
    }
    let subtitle = folder.appending(component: "手动 #1.zh.srt")
    try Data("1\n00:00:00,000 --> 00:00:10,000\n手动字幕\n".utf8).write(to: subtitle)
    var remembered = EnhancedPlaybackMemory()
    var options = PlayerOptions()
    options.muted = true
    let engine = MPVEngine(url: video, resume: 0, options: options, paused: true, headless: true) { remembered = $0 }
    defer { engine.stop() }
    engine.start()
    try await waitForPlaybackMemory { !engine.loading && engine.audio.count == 2 }
    let target = try #require(engine.audio.last)
    engine.selectAudio(target.id)
    engine.loadExternalSubtitle(subtitle)
    engine.setSubtitleDelay(-1.5)
    try await waitForPlaybackMemory { engine.subtitles.contains { $0.externalURL?.lastPathComponent == subtitle.lastPathComponent } }
    #expect(remembered.subtitles == .track(EnhancedTrackReference(externalName: subtitle.lastPathComponent, localSubtitleURL: subtitle)))

    options.subtitlesEnabled = false
    let reopened = MPVEngine(url: video, resume: 0, options: options, paused: true, memory: remembered, headless: true) { remembered = $0 }
    defer { reopened.stop() }
    reopened.start()
    try await waitForPlaybackMemory {
        !reopened.loading && reopened.selectedAudio == target.id && reopened.subtitles.contains {
            $0.id == reopened.selectedSubtitle && $0.externalURL?.lastPathComponent == subtitle.lastPathComponent
        }
    }
    #expect(reopened.subtitleDelay == -1.5)
    reopened.selectSubtitle("no")
    #expect(remembered.subtitles == .off)
    options.subtitlesEnabled = true
    let disabled = MPVEngine(url: video, resume: 0, options: options, paused: true, memory: remembered, headless: true)
    defer { disabled.stop() }
    disabled.start()
    try await waitForPlaybackMemory { !disabled.loading && disabled.selectedSubtitle == "no" }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VELUN_TRACK_MEMORY_MP4"] != nil)) @MainActor
func systemPlayerRestoresAudioSubtitleAndExplicitOff() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VELUN_TRACK_MEMORY_MP4"])
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    let suiteName = "Velun-TrackMemory-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }
    let library = Library(file: folder.appending(component: "library.json"))
    library.add([URL(filePath: path)])
    let media = try #require(library.items.first)
    let prefs = PlaybackPreferences(defaults: defaults)
    prefs.options.muted = true
    let playback = Playback(library: library, preferences: prefs)
    defer { playback.close() }

    playback.open(media)
    try await waitForPlaybackMemory { !playback.loading && playback.nativeAudio.count == 2 && playback.nativeSubtitles.count >= 2 }
    let audio = try #require(playback.nativeAudio.first { $0.id != playback.nativeAudioID })
    let subtitle = try #require(playback.nativeSubtitles.first { $0.id != playback.nativeSubtitleID && !$0.title.contains("Forced") })
    playback.selectNativeAudio(audio.id)
    playback.selectNativeSubtitle(subtitle.id)
    #expect(library.playbackMemory(for: media.id).nativeAudio != nil)
    #expect(library.playbackMemory(for: media.id).nativeSubtitles != nil)

    playback.open(media)
    try await waitForPlaybackMemory { !playback.loading && playback.nativeAudioID == audio.id && playback.nativeSubtitleID == subtitle.id }
    playback.selectNativeSubtitle(-1)
    playback.open(media)
    try await waitForPlaybackMemory { !playback.loading && playback.nativeAudioID == audio.id && playback.nativeSubtitleID == -1 }
    playback.selectNativeSubtitle(Playback.automaticNativeSubtitle)
    #expect(library.playbackMemory(for: media.id).nativeSubtitles == nil)
}

@MainActor private func waitForPlaybackMemory(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
    try #require(ready())
}
