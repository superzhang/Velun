import Foundation
import Testing
import CMPV
import AppKit
import QuartzCore
import AVFoundation
@testable import Luma

@Test func hdrPolicyMatchesDisplayAndKeepsSDRSafe() {
    let hdr = HDROutputPlan.make(transfer: "pq", primaries: "bt.2020", headroom: 4, floatSurface: true, mode: .automatic)
    #expect(hdr.enabled)
    #expect(hdr.properties["target-trc"] == "pq")
    for plan in [
        HDROutputPlan.make(transfer: "hlg", primaries: "bt.2020", headroom: 1, floatSurface: true, mode: .automatic),
        HDROutputPlan.make(transfer: "pq", primaries: "bt.2020", headroom: 4, floatSurface: false, mode: .automatic),
        HDROutputPlan.make(transfer: "pq", primaries: "bt.2020", headroom: 4, floatSurface: true, mode: .sdr)
    ] { #expect(!plan.enabled); #expect(plan.properties["target-trc"] == "srgb") }

    for transfer in ["bt.1886", ""] {
        let sdr = HDROutputPlan.make(transfer: transfer, primaries: "", headroom: 4, floatSurface: true, mode: .automatic)
        #expect(sdr.output == .standard)
        #expect(sdr.properties["target-prim"] == "bt.709")
        #expect(sdr.properties["target-trc"] == "srgb")
        #expect(sdr.properties["target-peak"] == "auto")
    }
}

@Test func dolbyMetadataRequiresEvidenceAndRecognizesProfiles() throws {
    let payload = Data(#"{"streams":[{"codec_type":"video","codec_name":"hevc","width":3840,"height":2160,"color_transfer":"smpte2084","color_primaries":"bt2020","side_data_list":[{"side_data_type":"DOVI configuration record","dv_profile":8,"dv_bl_signal_compatibility_id":1}]},{"codec_type":"audio","codec_name":"eac3","profile":"Dolby Digital Plus + Dolby Atmos","channels":6,"channel_layout":"5.1"}]}"#.utf8)
    let info = try MediaTechnicalInfo.decode(payload)
    #expect(info.hdrLabel == "Dolby Vision P8")
    #expect(info.dolbyVisionCompatibility == 1)
    #expect(info.hasAtmos)
    #expect(info.audio.first?.title.contains("Dolby Atmos") == true)
    let plain = try MediaTechnicalInfo.decode(Data(#"{"streams":[{"codec_type":"audio","codec_name":"eac3","channels":6}]}"#.utf8))
    #expect(!plain.hasAtmos)
    #expect(!plain.isHDR)
    #expect(plain.hasSystemCompatibleAudio)
    let trueHD = try MediaTechnicalInfo.decode(Data(#"{"streams":[{"codec_type":"audio","codec_name":"truehd","profile":"Dolby TrueHD + Dolby Atmos","channels":8}]}"#.utf8))
    #expect(trueHD.hasAtmos)
    #expect(!trueHD.hasSystemCompatibleAudio) // Decoding goes to mpv, not a silent AVPlayer track.

}

@Test func oldSettingsLoadWithoutDiscardingAndNewAudioModesPersist() throws {
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(PlayerOptions())) as? [String:Any])
    for key in ["hdrOutput", "audioOutput", "spatialAudio", "preferNativeHDR"] { legacy.removeValue(forKey: key) }
    legacy["speed"] = 1.5
    let options = try JSONDecoder().decode(PlayerOptions.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(options.speed == 1.5)
    #expect(options.hdrMode == .automatic)
    #expect(options.allowsSpatialAudio)
    #expect(AudioOutputMode.passthrough.mpvProperties["audio-spdif"]?.contains("eac3") == true)
    #expect(AudioOutputMode.automatic.mpvProperties["audio-spdif"] == "")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_HDR_FIXTURE"] != nil))
func hdrProbeReadsRealTenBitHEVCAndDolbyDigitalPlus() async throws {
    let file = URL(filePath: try #require(ProcessInfo.processInfo.environment["LUMA_HDR_FIXTURE"]))
    let info = try await VideoProbe.inspectInformation(file)
    #expect(info.hdrLabel == "HDR10")
    #expect(info.transfer == "smpte2084")
    #expect(info.audio.first?.codec == "eac3")
    #expect(!info.hasAtmos) // Dolby Digital Plus is not automatically Atmos.
    let handle = try #require(luma_create(1)); defer { luma_destroy(handle) }
    #expect(luma_load(handle, file.path, 0) >= 0)
    var gamma = ""
    for _ in 0..<100 {
        for _ in 0..<100 {
            var number = 0.0; var text: UnsafePointer<CChar>?
            let event = luma_event(handle, &number, &text)
            if event == 0 { break }
            if event == 20 { gamma = text.map { String(cString: $0) } ?? "" }
            if event == 2 || event == 19 { let detail = text.map { String(cString: $0) } ?? "Decoder error"; Issue.record("\(detail)") }
        }
        if gamma == "pq" { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(gamma == "pq")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_HDR_FIXTURE"] != nil))
func nativeHDRCopyPreservesTransferAndDolbyAudio() async throws {
    let source = URL(filePath: try #require(ProcessInfo.processInfo.environment["LUMA_HDR_FIXTURE"]))
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let destination = folder.appending(path: "compatible.mp4")
    let info = try await VideoProbe.inspectInformation(source)
    try await NativeCompatibleCopy.save(source, to: destination, info: info)
    let result = try await VideoProbe.inspectInformation(destination)
    #expect(result.dimensions == info.dimensions)
    #expect(result.hdrLabel == "HDR10")
    #expect(result.audio.first?.codec == "eac3")
    #expect(try await AVURLAsset(url: destination).load(.isPlayable))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_HDR_FIXTURE"] != nil)) @MainActor
func hdrOpenGLSurfaceUsesFloatBackingAndColorManagedLayer() async throws {
    _ = NSApplication.shared
    let source = URL(filePath: try #require(ProcessInfo.processInfo.environment["LUMA_HDR_FIXTURE"]))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    var options = PlayerOptions(); options.hdrOutput = .sdr
    let engine = MPVEngine(url: source, resume: 0, options: options, paused: true)
    let view = try #require(MPVSurfaceView(engine: engine))
    window.contentView = view
    defer { engine.stop(); window.close() }
    #expect(view.floatingSurface)
    #expect(view.layer is CAOpenGLLayer)
    view.prepareOpenGL()
    for _ in 0..<100 {
        if engine.videoTransfer == "pq" { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(engine.videoTransfer == "pq")
    #expect(!engine.hdrOutputActive)
    #expect(engine.error == nil)
    #expect(engine.settingsError == nil)
    options.hdrOutput = .automatic
    engine.apply(options); view.updateHDROutput()
    let displaySupportsHDR = (window.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    #expect(engine.hdrOutputActive == displaySupportsHDR)
    let colorLayer = try #require(view.layer as? CAOpenGLLayer)
    #expect(colorLayer.wantsExtendedDynamicRangeContent == displaySupportsHDR)
    if displaySupportsHDR { #expect(colorLayer.colorspace?.name == CGColorSpace.itur_2100_PQ) }

}
