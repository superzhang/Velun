import Foundation

enum HDRPlaybackMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, sdr
    var id: String { rawValue }
    var title: String { self == .automatic ? "自动 HDR / EDR" : "映射为 SDR" }
}
enum AudioOutputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, stereo, passthrough
    var id: String { rawValue }
    var title: String { switch self { case .automatic: "自动（多声道 PCM）"; case .stereo: "立体声"; case .passthrough: "HDMI / S/PDIF 直通" } }
    var mpvProperties: [String: String] {
        ["audio-channels": self == .stereo ? "stereo" : "auto-safe", "audio-spdif": self == .passthrough ? "ac3,eac3,truehd,dts,dts-hd" : ""]
    }
}

struct MediaTechnicalInfo: Codable, Equatable, Sendable {
    struct Audio: Codable, Equatable, Sendable {
        let codec: String
        let profile: String
        let channels: Int
        let layout: String
        var atmos: Bool { profile.localizedCaseInsensitiveContains("atmos") }
        var title: String {
            let name: String = switch codec { case "eac3": "Dolby Digital Plus"; case "ac3": "Dolby Digital"; case "truehd": "Dolby TrueHD"; default: codec.uppercased() }
            return (atmos ? "Dolby Atmos · " : "") + name + (channels > 0 ? " · \(channels) 声道" : "")
        }
    }
    let videoCodec: String
    let dimensions: VideoDimensions?
    let transfer: String
    let primaries: String
    let dolbyVisionProfile: Int?
    let dolbyVisionCompatibility: Int?
    let hdr10Plus: Bool
    let audio: [Audio]
    var isHDR: Bool { dolbyVisionProfile != nil || ["smpte2084", "arib-std-b67", "pq", "hlg"].contains(transfer) }
    var requiresNativeDolbyVision: Bool { dolbyVisionProfile == 5 || (dolbyVisionProfile == 8 && (dolbyVisionCompatibility ?? 0) == 0) }
    var hasAtmos: Bool { audio.contains { $0.atmos } }
    var hasSystemCompatibleAudio: Bool {
        audio.isEmpty || audio.contains { ["aac", "ac3", "eac3", "alac", "mp3", "flac", "opus"].contains($0.codec) || $0.codec.hasPrefix("pcm_") }
    }
    var hdrLabel: String? {
        if let profile = dolbyVisionProfile { return "Dolby Vision P\(profile)" }
        if transfer == "arib-std-b67" || transfer == "hlg" { return "HLG" }
        if transfer == "smpte2084" || transfer == "pq" { return hdr10Plus ? "HDR10+" : "HDR10" }
        return nil
    }
    static func decode(_ data: Data) throws -> Self {
        struct Response: Decodable {
            let streams: [Stream]
            struct Stream: Decodable {
                let codec_type: String?
                let codec_name: String?
                let profile: String?
                let width: Int?
                let height: Int?
                let color_transfer: String?
                let color_primaries: String?
                let channels: Int?
                let channel_layout: String?
                let side_data_list: [Side]?
                let disposition: Disposition?
                struct Disposition: Decodable { let attached_pic: Int? }
            }
            struct Side: Decodable { let side_data_type: String?; let dv_profile: Int?; let dv_bl_signal_compatibility_id: Int? }
        }
        let streams = try JSONDecoder().decode(Response.self, from: data).streams
        let video = streams.first { $0.codec_type == "video" && $0.disposition?.attached_pic != 1 }
        let side = video?.side_data_list ?? []
        let dovi = side.first { $0.dv_profile != nil }
        let dimensions: VideoDimensions?
        if let width = video?.width, let height = video?.height, width > 0, height > 0 { dimensions = VideoDimensions(width: width, height: height) } else { dimensions = nil }
        return Self(videoCodec: video?.codec_name ?? "", dimensions: dimensions, transfer: video?.color_transfer ?? "", primaries: video?.color_primaries ?? "", dolbyVisionProfile: dovi?.dv_profile, dolbyVisionCompatibility: dovi?.dv_bl_signal_compatibility_id,
                    hdr10Plus: side.contains { $0.side_data_type?.contains("2094-40") == true },
                    audio: streams.filter { $0.codec_type == "audio" }.map { Audio(codec: $0.codec_name ?? "", profile: $0.profile ?? "", channels: $0.channels ?? 0, layout: $0.channel_layout ?? "") })
    }
}

struct HDROutputPlan: Equatable, Sendable {
    enum Output: Equatable, Sendable { case standard, toneMapped, extended }
    let output: Output
    let primaries: String
    var enabled: Bool { output == .extended }

    static func make(transfer: String, primaries: String, headroom: Double, floatSurface: Bool, mode: HDRPlaybackMode) -> Self {
        guard ["pq", "hlg"].contains(transfer) else { return Self(output: .standard, primaries: "") }
        let supportedGamut = ["bt.2020", "display-p3"].contains(primaries)
        if supportedGamut && headroom > 1 && floatSurface && mode == .automatic {
            return Self(output: .extended, primaries: primaries)
        }
        return Self(output: .toneMapped, primaries: "bt.709")
    }

    var properties: [String: String] {
        switch output {
        case .standard:
            // Match the sRGB color space of the composited video layer.
            return ["target-prim": "bt.709", "target-trc": "srgb", "target-peak": "auto",
                    "tone-mapping": "auto", "hdr-compute-peak": "auto"]
        case .toneMapped:
            return ["target-prim": primaries, "target-trc": "srgb", "target-peak": "100",
                    "tone-mapping": "bt.2390", "hdr-compute-peak": "no"]
        case .extended:
            return ["target-prim": primaries, "target-trc": "pq", "target-peak": "auto",
                    "tone-mapping": "bt.2390", "hdr-compute-peak": "no"]
        }
    }
}
