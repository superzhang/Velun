import Foundation

struct SkipSegment: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let source: String
    func contains(_ time: Double) -> Bool { time >= start && time < end - 0.5 }
}
struct SkipDetection: Codable, Sendable {
    var intro: SkipSegment?
    var credits: SkipSegment?
}

enum AutoSkip {
    struct Chapter: Sendable { let title: String; let time: Double }
    static func chapters(_ chapters: [Chapter], duration: Double) -> SkipDetection {
        guard duration.isFinite, duration > 0 else { return SkipDetection() }
        let ordered = chapters.filter { $0.time.isFinite && $0.time >= 0 && $0.time < duration }.sorted { $0.time < $1.time }
        var result = SkipDetection()
        for (index, chapter) in ordered.enumerated() {
            let title = chapter.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let words = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            let end = index + 1 < ordered.count ? ordered[index + 1].time : duration
            let intro = title.contains("片头") || title.contains("オープニング") || words.contains("intro") || words.contains("opening") || words.contains("op")
            let postCredits = title.contains("post") || title.contains("彩蛋") || title.contains("after")
            let credits = !postCredits && (title.contains("片尾") || title.contains("エンディング") || words.contains("credits") || words.contains("outro") || words.contains("ending") || words.contains("ed"))
            if intro, chapter.time < min(600, duration * 0.35), (5...240).contains(end - chapter.time) {
                result.intro = SkipSegment(start: chapter.time, end: end, source: "章节标记")
            }
            if credits, chapter.time > duration * 0.6, duration - chapter.time < 600 {
                result.credits = SkipSegment(start: chapter.time, end: end, source: "章节标记")
            }
        }
        return result
    }

    // 32-bit spectral/temporal fingerprints at 15.625 Hz. No video decoding.
    static let step = 256.0 / 4000
    struct Print: Sendable { let bits: UInt32; let audible: Bool }
    @concurrent static func fingerprints(_ pcm: Data) async throws -> [Print] {
        let samples = pcm.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - raw.count % 4, by: 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
        }
        let frequencies = (0..<17).map { 90 * pow(1800.0 / 90, Double($0) / 16) }
        let coefficients = frequencies.map { 2 * cos(2 * Double.pi * $0 / 4000) }
        let window = (0..<512).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 511) }
        var output: [Print] = [], previous = [Double](repeating: 0, count: 17)
        guard samples.count >= 512 else { return [] }
        for start in stride(from: 0, through: samples.count - 512, by: 256) {
            if start % 16384 == 0 { try Task.checkCancellation() }
            var powers = [Double](repeating: 0, count: 17), energy = 0.0
            for i in 0..<512 { energy += Double(samples[start + i]) * Double(samples[start + i]) }
            for band in 0..<17 {
                var a = 0.0, b = 0.0
                for i in 0..<512 {
                    let next = Double(samples[start + i]) * window[i] + coefficients[band] * a - b
                    b = a; a = next
                }
                powers[band] = log1p(max(0, a * a + b * b - coefficients[band] * a * b))
            }
            var bits: UInt32 = 0
            for band in 0..<16 {
                if powers[band] > powers[band + 1] { bits |= 1 << band }
                if powers[band] - powers[band + 1] > previous[band] - previous[band + 1] { bits |= 1 << (band + 16) }
            }
            output.append(Print(bits: bits, audible: energy / 512 > 0.00001))
            previous = powers
        }
        return output
    }
    /// Return distinct repeated regions; repetition alone does not establish an opening.
    @concurrent static func commonCandidates(_ a: [Print], _ b: [Print], minimum: Double = 25) async throws -> [Range<Double>] {
        let required = max(1, Int(minimum / step))
        guard a.count >= required, b.count >= required,
              Set(a.map { $0.bits >> 16 }).count >= 24, Set(b.map { $0.bits >> 16 }).count >= 24 else { return [] }
        var matches: [Range<Int>] = []
        for offset in (-(b.count - required))...(a.count - required) {
            if offset % 64 == 0 { try Task.checkCancellation() }
            var start: Int?, lastGood = 0, good = 0, badStreak = 0
            func record() {
                guard let start, lastGood - start >= required,
                      Double(good) / Double(lastGood - start) >= 0.9,
                      Set(a[start..<lastGood].map { $0.bits >> 16 }).count >= 24 else { return }
                matches.append(start..<lastGood)
            }
            for i in max(0, offset)..<min(a.count, b.count + offset) {
                let j = i - offset
                if a[i].audible && b[j].audible && (a[i].bits ^ b[j].bits).nonzeroBitCount <= 7 {
                    if start == nil { start = i }
                    good += 1; lastGood = i + 1; badStreak = 0
                } else {
                    badStreak += 1
                    if badStreak > 6 { record(); start = nil; good = 0; badStreak = 0 }
                }
            }
            record()
        }
        matches.sort { $0.count > $1.count }
        var distinct: [Range<Int>] = []
        for match in matches {
            let duplicate = distinct.contains { other in
                Double(max(0, min(match.upperBound, other.upperBound) - max(match.lowerBound, other.lowerBound))) / Double(min(match.count, other.count)) > 0.8
            }
            if !duplicate { distinct.append(match) }
            if distinct.count == 16 { break }
        }
        return distinct.map { Double($0.lowerBound) * step..<Double($0.upperBound) * step }
    }
    @concurrent static func common(_ a: [Print], _ b: [Print], minimum: Double = 25) async throws -> Range<Double>? {
        try await commonCandidates(a, b, minimum: minimum).first
    }
    static func consistentCandidate(_ first: [Range<Double>], _ confirmation: [Range<Double>], maximum: Double) -> Range<Double>? {
        var candidates: [Range<Double>] = []
        for a in first {
            for b in confirmation {
                let start = max(a.lowerBound, b.lowerBound), end = min(a.upperBound, b.upperBound)
                let overlap = end - start, shorter = min(a.upperBound - a.lowerBound, b.upperBound - b.lowerBound)
                guard overlap >= 25, overlap <= maximum, overlap / shorter >= 0.85 else { continue }
                if !candidates.contains(where: { abs($0.lowerBound - start) < 2 && abs($0.upperBound - end) < 2 }) { candidates.append(start..<end) }
            }
        }
        // Multiple repeated sections are ambiguous (e.g. a recap plus an opening).
        return candidates.count == 1 ? candidates[0] : nil
    }
    static func references(for media: Media, in group: MediaGroup) -> [Media] {
        let current = EpisodeCode(media)
        var seen = Set([current.episode])
        return group.items.filter { EpisodeCode($0).season == current.season }
            .sorted { abs(EpisodeCode($0).episode - current.episode) < abs(EpisodeCode($1).episode - current.episode) }
            .filter { seen.insert(EpisodeCode($0).episode).inserted }
            .prefix(2).map { $0 }
    }
    static var executable: URL {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/ffmpeg")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : URL(filePath: "/opt/homebrew/bin/ffmpeg")
    }
    @concurrent static func audio(_ url: URL, start: Double, length: Double, fromEnd: Bool = false) async throws -> Data {
        let process = Process(); process.executableURL = executable; process.qualityOfService = .utility
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-threads", "1", "-rw_timeout", "15000000", fromEnd ? "-sseof" : "-ss", String(fromEnd ? -length : max(0, start)), "-i", url.isFileURL ? url.path : url.absoluteString, "-t", String(length), "-map", "0:a:0", "-vn", "-sn", "-dn", "-ac", "1", "-ar", "4000", "-f", "f32le", "pipe:1"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); try process.run()
            defer { if process.isRunning { process.terminate() } }
            let deadline = Task { try await Task.sleep(for: .seconds(60)); if process.isRunning { process.terminate() } }
            defer { deadline.cancel() }
            var data = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                guard data.count <= 8_000_000 else { throw SourceWorker.failure("音频分析超过大小限制。") }
                try Task.checkCancellation()
            }
            process.waitUntilExit(); try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw SourceWorker.failure("此视频暂不能分析片头片尾。") }
            return data
        } onCancel: { if process.isRunning { process.terminate() } }
    }
    static func compare(current: URL, reference: URL, confirmation: URL, duration: Double, analyzeIntro: Bool = true, analyzeCredits: Bool = true) async throws -> SkipDetection {
        let headLength = min(480, duration * 0.3), tailLength = min(240, duration * 0.2)
        var result = SkipDetection()
        if analyzeIntro {
            let a = try await fingerprints(audio(current, start: 0, length: headLength))
            let b = try await fingerprints(audio(reference, start: 0, length: headLength))
            let c = try await fingerprints(audio(confirmation, start: 0, length: headLength))
            let first = try await commonCandidates(a, b), third = try await commonCandidates(a, c)
            if let match = consistentCandidate(first, third, maximum: 180) {
                result.intro = SkipSegment(start: match.lowerBound + 0.5, end: match.upperBound - 0.5, source: "三集重复音频（非章节标记）")
            }
        }
        if analyzeCredits {
            let a = try await fingerprints(audio(current, start: duration - tailLength, length: tailLength))
            let b = try await fingerprints(audio(reference, start: 0, length: tailLength, fromEnd: true))
            let c = try await fingerprints(audio(confirmation, start: 0, length: tailLength, fromEnd: true))
            let first = try await commonCandidates(a, b), third = try await commonCandidates(a, c)
            if let match = consistentCandidate(first, third, maximum: 240) {
                result.credits = SkipSegment(start: duration - tailLength + match.lowerBound + 0.5, end: duration - tailLength + match.upperBound, source: "三集重复音频（非章节标记）")
            }
        }
        return result
    }

}

actor AutoSkipCache {
    private struct Record: Codable { let key: String; let date: Date; let result: SkipDetection }
    @concurrent static func key(media: Media, reference: Media, confirmation: Media, duration: Double, sourcesFile: URL = URL.applicationSupportDirectory.appending(path: "Luma/sources.json")) async -> String {
        var records: [UUID: LibrarySource] = [:]
        if let data = try? Data(contentsOf: sourcesFile), let sources = try? JSONDecoder().decode([LibrarySource].self, from: data) {
            for source in sources { records[source.id] = source }
        }
        func identity(_ item: Media) -> String {
            let source = item.sourceID.flatMap { records[$0] }
            let version = item.url.isFileURL ? MediaFileVersion.local(item.url) : item.fileVersion
            let fingerprint = version.map { "\($0.size)|\($0.modified)" }
                ?? "scan:\(source?.lastScan?.timeIntervalSince1970 ?? 0)"
            return "\(item.url.absoluteString)|\(source?.url.absoluteString ?? "")|\(source?.connectionRevision?.uuidString ?? "legacy")|\(fingerprint)"
        }
        return "v4|\(identity(media))|\(identity(reference))|\(identity(confirmation))|\(Int(duration))"
    }
    private static func file(_ id: UUID) -> URL { URL.applicationSupportDirectory.appending(path: "Luma/skip-markers-v1/\(id.uuidString).json") }
    @concurrent static func read(id: UUID, key: String) async -> SkipDetection? {
        guard let data = try? Data(contentsOf: file(id)), let record = try? JSONDecoder().decode(Record.self, from: data),
              record.key == key, Date().timeIntervalSince(record.date) < 604800 else { return nil }
        return record.result
    }
    @concurrent static func save(id: UUID, key: String, result: SkipDetection) async {
        let url = file(id)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Record(key: key, date: Date(), result: result)).write(to: url, options: .atomic)
        } catch { }
    }
}
