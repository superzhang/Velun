import Foundation

enum NativeCompatibleCopy {
    static func audioIndex(_ info: MediaTechnicalInfo) -> Int? {
        let supported = ["eac3", "ac3", "aac", "alac", "mp3"]
        return info.audio.firstIndex { $0.codec == "eac3" && $0.atmos } ?? info.audio.firstIndex { supported.contains($0.codec) }
    }
    @concurrent static func save(_ source: URL, to destination: URL, info: MediaTechnicalInfo) async throws {
        if let profile = info.dolbyVisionProfile, ![5, 8].contains(profile) { throw SourceWorker.failure("系统兼容封装支持 Dolby Vision Profile 5 / 8；Profile 7 使用 HDR 兼容层播放。") }
        guard ["hevc", "h264"].contains(info.videoCodec) else { throw SourceWorker.failure("此兼容封装入口支持 HEVC / H.264 视频。") }
        guard info.dimensions != nil else { throw SourceWorker.failure("未找到可以封装的视频轨道。") }
        let audio = audioIndex(info)
        guard info.audio.isEmpty || audio != nil else { throw SourceWorker.failure("此文件只有系统不支持的音轨，仅重新封装不能保留其原音轨并交给系统播放。") }
        let staging = destination.deletingLastPathComponent().appending(path: ".luma-compatible-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: staging) }
        let process = Process(); process.executableURL = AutoSkip.executable; process.qualityOfService = .utility
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-rw_timeout", "15000000", "-i", source.isFileURL ? source.path : source.absoluteString, "-map", "0:V:0"]
        if let audio { arguments += ["-map", "0:a:\(audio)"] }
        arguments += ["-c", "copy", "-tag:v", info.videoCodec == "h264" ? "avc1" : info.dolbyVisionProfile == nil ? "hvc1" : "dvh1", "-strict", "unofficial", "-movflags", "+faststart", "-map_metadata", "0", "-f", "mp4", staging.path]
        process.arguments = arguments; process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        let errors = Pipe(); process.standardError = errors
        try await withTaskCancellationHandler {
            try Task.checkCancellation(); try process.run()
            defer { if process.isRunning { process.terminate() } }
            _ = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw SourceWorker.failure("无损封装失败，原文件未改变。") }
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
            else { try FileManager.default.moveItem(at: staging, to: destination) }
        } onCancel: { if process.isRunning { process.terminate() } }
    }
}
