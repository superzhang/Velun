import Foundation

struct VideoDimensions: Equatable, Sendable, Codable {
    let width: Int
    let height: Int
    var badge: String {
        let longest = max(width, height), shortest = min(width, height)
        if longest >= 7000 || shortest >= 4000 { return "8K" }
        if longest >= 3800 || shortest >= 2100 { return "4K" }
        if longest >= 1900 || shortest >= 1000 { return "1080p" }
        if longest >= 1200 || shortest >= 700 { return "720p" }
        return "SD"
    }
    static func decode(_ data: Data) throws -> Self? {
        struct Response: Decodable {
            let streams: [Stream]
            struct Stream: Decodable { let width: Int?; let height: Int? }
        }
        let stream = try JSONDecoder().decode(Response.self, from: data).streams.first
        guard let width = stream?.width, let height = stream?.height, width > 0, height > 0 else { return nil }
        return Self(width: width, height: height)
    }
}

actor VideoProbe {
    static let shared = VideoProbe()
    private var cache: [String: (Date, MediaTechnicalInfo)] = [:]
    func dimensions(_ media: Media) async throws -> VideoDimensions? { try await information(media).dimensions }
    func information(_ media: Media) async throws -> MediaTechnicalInfo {
        let stamp = media.url.isFileURL ? (try? media.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0 : 0
        let key = "\(media.url.absoluteString)|\(stamp)"
        if let entry = cache[key], Date().timeIntervalSince(entry.0) < 600 { return entry.1 }
        let url = try await RemoteSourceResolver.resolve(media)
        let result = try await Self.inspectInformation(url)
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = (Date(), result)
        return result
    }
    static func inspect(_ url: URL) async throws -> VideoDimensions? { try await inspectInformation(url).dimensions }
    @concurrent static func inspectInformation(_ url: URL) async throws -> MediaTechnicalInfo {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/ffprobe")
        let process = Process()
        process.executableURL = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : URL(filePath: "/opt/homebrew/bin/ffprobe")
        process.arguments = ["-v", "error", "-rw_timeout", "10000000", "-analyzeduration", "3000000", "-probesize", "3000000", "-show_entries", "stream=codec_type,codec_name,profile,width,height,color_transfer,color_primaries,channels,channel_layout:stream_disposition=attached_pic:stream_side_data", "-of", "json", url.isFileURL ? url.path : url.absoluteString]
        process.qualityOfService = .utility
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); try process.run()
            let deadline = Task { try await Task.sleep(for: .seconds(15)); if process.isRunning { process.terminate() } }
            defer { deadline.cancel(); if process.isRunning { process.terminate() } }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw URLError(.cannotDecodeContentData) }
            return try MediaTechnicalInfo.decode(data)
        } onCancel: { if process.isRunning { process.terminate() } }
    }
}

struct IMDbRating: Equatable, Sendable {
    let score: Double
    let votes: Int
    static func validID(_ id: String) -> Bool { id.hasPrefix("tt") && id.count >= 9 && id.count <= 12 && id.dropFirst(2).allSatisfy { $0.isASCII && $0.isNumber } }
    static func find(_ id: String, in data: Data) -> Self? {
        guard validID(id), let range = data.range(of: Data("\n\(id)\t".utf8)) else { return nil }
        let start = range.upperBound
        let end = data[start...].firstIndex(of: 10) ?? data.endIndex
        let columns = String(decoding: data[start..<end], as: UTF8.self).split(separator: "\t")
        guard columns.count == 2, let score = Double(columns[0]), score.isFinite, (0...10).contains(score), let votes = Int(columns[1]), votes > 0 else { return nil }
        return Self(score: score, votes: votes)
    }
}

/// Personal, non-commercial IMDb dataset. No API key or per-title request is sent.
actor IMDbRatings {
    static let shared = IMDbRatings()
    private let file = URL.cachesDirectory.appending(path: "Luma/IMDb/title.ratings.tsv")
    private var snapshot: Data?
    private var loadedAt = Date.distantPast
    private var loading: Task<Data, Error>?
    private var retryAfter = Date.distantPast
    func rating(_ id: String) async throws -> IMDbRating? {
        guard IMDbRating.validID(id) else { return nil }
        if let snapshot, Date().timeIntervalSince(loadedAt) < 86400 { return IMDbRating.find(id, in: snapshot) }
        if Date() < retryAfter { return snapshot.flatMap { IMDbRating.find(id, in: $0) } }
        if loading == nil {
            let file = file
            loading = Task { try await Self.load(file) }
        }
        do {
            let data = try await loading!.value
            snapshot = data; loadedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(); loading = nil
            return IMDbRating.find(id, in: data)
        } catch {
            loading = nil; retryAfter = Date().addingTimeInterval(3600)
            if let old = try? Data(contentsOf: file, options: .mappedIfSafe) { snapshot = old; return IMDbRating.find(id, in: old) }
            throw error
        }
    }
    @concurrent private static func load(_ file: URL) async throws -> Data {
        if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < 86400 { return try Data(contentsOf: file, options: .mappedIfSafe) }
        var request = URLRequest(url: URL(string: "https://datasets.imdbws.com/title.ratings.tsv.gz")!)
        request.timeoutInterval = 60
        let (download, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: download) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let size = try download.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 25_000_000 else { throw URLError(.badServerResponse) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = file.deletingLastPathComponent().appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        FileManager.default.createFile(atPath: staging.path, contents: nil)
        let output = try FileHandle(forWritingTo: staging); defer { try? output.close() }
        let process = Process(); process.executableURL = URL(filePath: "/usr/bin/gzip"); process.arguments = ["-dc", download.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.qualityOfService = .utility
        try process.run(); process.waitUntilExit(); try output.close()
        let data = try Data(contentsOf: staging, options: .mappedIfSafe)
        guard process.terminationStatus == 0, data.count < 100_000_000,
              data.starts(with: Data("tconst\taverageRating\tnumVotes\n".utf8)) else { throw URLError(.cannotDecodeContentData) }
        if FileManager.default.fileExists(atPath: file.path) { _ = try FileManager.default.replaceItemAt(file, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: file) }
        return data
    }
}
