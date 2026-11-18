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
