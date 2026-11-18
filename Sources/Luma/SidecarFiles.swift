import Foundation

struct MediaSidecars: Codable, Equatable, Sendable {
    var poster: URL?
    var backdrop: URL?
    var subtitles: [URL] = []

    var isEmpty: Bool { poster == nil && backdrop == nil && subtitles.isEmpty }
}

struct SidecarIndex {
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "m2ts", "mpg", "mpeg", "webm"]
    static let remoteVideoExtensions = videoExtensions.union(["wmv", "flv", "iso"])
    static let imageExtensions = ["jpg", "jpeg", "png", "webp"]
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "sup", "idx"]
    private var nfo: [String: URL] = [:]
    private var videoCount = 0
    private var artwork: [String: URL] = [:]
    private var subtitles: [String: [URL]] = [:]

    static func supports(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext) || subtitleExtensions.contains(ext) || ext == "nfo"
    }

    mutating func insert(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if Self.remoteVideoExtensions.contains(ext) {
            videoCount += 1
        } else if ext == "nfo" {
            if nfo[stem].map({ $0.absoluteString > url.absoluteString }) ?? true { nfo[stem] = url }
        } else if Self.imageExtensions.contains(ext) {
            let key = "\(stem).\(ext)"
            if artwork[key].map({ $0.absoluteString > url.absoluteString }) ?? true { artwork[key] = url }
        } else if Self.subtitleExtensions.contains(ext) {
            subtitles[stem, default: []].append(url)
            var base = stem
            while let dot = base.lastIndex(of: "."), Self.isSubtitleSuffix(base[base.index(after: dot)...]) {
                base = String(base[..<dot])
                subtitles[base, default: []].append(url)
            }
        }
    }

    private static func isSubtitleSuffix(_ suffix: Substring) -> Bool {
        if ["forced", "sdh", "hi", "cc", "default", "chs", "cht", "简体", "繁體", "中字",
            "chinese", "english", "japanese", "korean"].contains(suffix) { return true }
        let parts = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first, (2...3).contains(language.count) else { return false }
        return parts.allSatisfy { part in
            (2...8).contains(part.count) && part.utf8.allSatisfy { (97...122).contains($0) }
        }
    }

    func sidecars(for video: URL) -> MediaSidecars? {
        let stem = video.deletingPathExtension().lastPathComponent.lowercased()
        var tracks = subtitles[stem, default: []]
        let indexed = Set(tracks.filter { $0.pathExtension.lowercased() == "idx" }.map { $0.deletingPathExtension().absoluteString.lowercased() })
        tracks.removeAll { $0.pathExtension.lowercased() == "sub" && indexed.contains($0.deletingPathExtension().absoluteString.lowercased()) }
        tracks.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let value = MediaSidecars(
            poster: image(named: ["\(stem)-poster", stem, "poster", "folder"]),
            backdrop: image(named: ["\(stem)-fanart", "\(stem)-backdrop", "fanart", "backdrop"]),
            subtitles: tracks
        )
        return value.isEmpty ? nil : value
    }

    private func image(named names: [String]) -> URL? {
        for name in names {
            for ext in Self.imageExtensions {
                if let url = artwork["\(name).\(ext)"] { return url }
            }
        }
        return nil
    }

    static func prioritizedSubtitles(_ subtitles: [URL], for video: URL, language: TrackLanguage) -> [URL] {
        let codes: Set<Substring> = switch language {
        case .automatic: []
        case .chinese: ["zh", "chi", "zho", "chs", "cht", "chinese", "简体", "繁體", "中字"]
        case .english: ["en", "eng", "english"]
        case .japanese: ["ja", "jpn", "japanese"]
        case .korean: ["ko", "kor", "korean"]
        }
        guard !codes.isEmpty else { return subtitles }
        let prefix = video.deletingPathExtension().lastPathComponent.lowercased() + "."
        var preferred: [URL] = []
        var other: [URL] = []
        for subtitle in subtitles {
            let stem = subtitle.deletingPathExtension().lastPathComponent.lowercased()
            let suffix = stem.hasPrefix(prefix) ? stem.dropFirst(prefix.count) : ""
            if suffix.split(whereSeparator: { $0 == "." || $0 == "-" }).contains(where: codes.contains) {
                preferred.append(subtitle)
            } else {
                other.append(subtitle)
            }
        }
        return preferred + other
    }

    static func attach(_ indices: [URL: Self], to files: inout [ScannedFile]) {
        for i in files.indices {
            let video = files[i].url
            let directory = video.deletingLastPathComponent()
            let index = indices[directory]
            files[i].sidecars = index?.sidecars(for: video)
            let stem = video.deletingPathExtension().lastPathComponent.lowercased()
            let parent = directory.deletingLastPathComponent()
            let show = index?.nfo["tvshow"] ?? indices[parent]?.nfo["tvshow"]
            let direct = index?.nfo[stem] ?? (index?.videoCount == 1 ? index?.nfo["movie"] : nil)
            if direct != nil || show != nil { files[i].nfo = NFOCandidates(video: direct, show: show) }
        }
    }

    static func directory(_ directory: URL) throws -> Self {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
        var index = Self()
        for url in entries where supports(url) || videoExtensions.contains(url.pathExtension.lowercased()) {
            let values = try url.resourceValues(forKeys: keys)
            if values.isRegularFile == true && values.isSymbolicLink != true { index.insert(url) }
        }
        return index
    }

    @concurrent static func local(for video: URL) async -> MediaSidecars? {
        guard video.isFileURL, let index = try? directory(video.deletingLastPathComponent()) else { return nil }
        return index.sidecars(for: video)
    }

    @concurrent static func localFiles(for videos: [URL]) async throws -> [ScannedFile] {
        let directories = Set(videos.map { $0.deletingLastPathComponent() })
        var indices: [URL: Self] = [:]
        for directory in directories {
            try Task.checkCancellation()
            indices[directory] = try? Self.directory(directory)
            let parent = directory.deletingLastPathComponent()
            if indices[parent] == nil {
                let url = parent.appending(component: "tvshow.nfo")
                if FileManager.default.fileExists(atPath: url.path),
                   let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                   values.isRegularFile == true, values.isSymbolicLink != true {
                    indices[parent, default: Self()].insert(url)
                }
            }
        }
        var files = videos.filter { indices[$0.deletingLastPathComponent()] != nil }
            .map { ScannedFile(url: $0, relativePath: $0.lastPathComponent) }
        attach(indices, to: &files)
        return try await NFOReader.enrich(files)
    }
}
