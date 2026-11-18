import Foundation
import Testing
import CMPV

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_MKV_FIXTURE"] != nil))
func decodesRealMKVContainer() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["LUMA_MKV_FIXTURE"])
    let handle = try #require(luma_create(1))
    defer { luma_destroy(handle) }
    #expect(luma_load(handle, path, 0) >= 0)
    var loaded = false
    for _ in 0..<100 {
        var value = 0.0; var message: UnsafePointer<CChar>?
        for _ in 0..<100 {
            let event = luma_event(handle, &value, &message)
            if event == 0 { break }
            if event == 1 { loaded = true }
            if event == 2 { let detail = message.map { String(cString: $0) } ?? "decoder failure"; Issue.record("\(detail)") }
        }
        if loaded { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(loaded)
    func property(_ name: String) -> String {
        guard let text = luma_get(handle, name) else { return "" }
        defer { luma_free(text) }; return String(cString: text)
    }
    #expect((Double(property("duration")) ?? 0) > 0)
    #expect((Int(property("track-list/count")) ?? 0) >= 2)
    #expect(!property("video-codec").isEmpty)
    #expect(luma_command(handle, "seek", "5", "absolute+exact") >= 0)
    try await Task.sleep(for: .milliseconds(300))
    #expect((Double(property("time-pos")) ?? 0) >= 5)
    if (Int(property("track-list/count")) ?? 0) >= 4 { #expect(property("sub-text").contains("Luma")) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_MKV_FIXTURE"] != nil))
func explicitlySelectedExternalSubtitleStillLoads() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["LUMA_MKV_FIXTURE"])
    let handle = try #require(luma_create(1)); defer { luma_destroy(handle) }
    let subtitle = FileManager.default.temporaryDirectory.appending(path: "Luma-Explicit-\(UUID()).srt")
    defer { try? FileManager.default.removeItem(at: subtitle) }
    try Data("1\n00:00:00,000 --> 00:00:15,000\nExplicit subtitle fixture\n".utf8).write(to: subtitle)
    #expect(luma_load(handle, path, 0) >= 0)
    var loaded = false
    for _ in 0..<100 {
        var value = 0.0; var message: UnsafePointer<CChar>?
        for _ in 0..<100 { let event = luma_event(handle, &value, &message); if event == 0 { break }; if event == 1 { loaded = true } }
        if loaded { break }; try await Task.sleep(for: .milliseconds(50))
    }
    #expect(loaded)
    #expect(luma_command(handle, "sub-add", subtitle.path, "select") >= 0)
    #expect(luma_command(handle, "seek", "5", "absolute+exact") >= 0)
    var selected = false
    for _ in 0..<40 {
        if let text = luma_get(handle, "sub-text") { selected = String(cString: text).contains("Explicit subtitle fixture"); luma_free(text) }
        if selected { break }; try await Task.sleep(for: .milliseconds(50))
    }
    #expect(selected)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_MKV_FIXTURE"] != nil))
func mpvLoadsIndexedExternalSubtitlesBeforePlayback() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["LUMA_MKV_FIXTURE"])
    let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let subtitles = [folder.appending(component: "电影 #1, 测试 %.zh.srt"), folder.appending(component: "电影 #1.en.srt")]
    for (index, subtitle) in subtitles.enumerated() {
        try Data("1\n00:00:00,000 --> 00:00:10,000\nExternal fixture \(index)\n".utf8).write(to: subtitle)
    }
    let handle = try #require(luma_create(1))
    defer { luma_destroy(handle) }
    for subtitle in subtitles { #expect(luma_add_external_subtitle(handle, subtitle.path) >= 0) }
    #expect(luma_load(handle, path, 1) >= 0)
    func property(_ name: String) -> String {
        guard let result = luma_get(handle, name) else { return "" }
        defer { luma_free(result) }
        return String(cString: result)
    }
    var loaded = false
    for _ in 0..<100 {
        var value = 0.0; var message: UnsafePointer<CChar>?
        for _ in 0..<100 {
            let event = luma_event(handle, &value, &message)
            if event == 0 { break }
            if event == 1 { loaded = true }
        }
        if loaded { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    try #require(loaded)
    #expect(luma_prefer_external_subtitle(handle, subtitles[0].path) != 0)
    #expect(luma_command(handle, "seek", "5", "absolute+exact") >= 0)
    var caption = ""
    for _ in 0..<100 {
        caption = property("sub-text")
        if caption.contains("External fixture 0") { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let count = Int(property("track-list/count")) ?? 0
    let filenames = (0..<count).map { property("track-list/\($0)/external-filename") }
    #expect(subtitles.allSatisfy { filenames.contains($0.path) })
    #expect(caption.contains("External fixture 0"))
}
