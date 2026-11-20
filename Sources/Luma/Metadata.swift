import Foundation
import Security
import Observation

struct MovieInfo: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    let kind: String
    let title: String
    let year: String
    let overview: String
    let poster: URL?
    var originalTitle: String?
    var backdrop: URL?
    var rating: Double?
    var genres: [String]?
    var runtime: Int?
    var cast: [CastMember]?
    var detailsLoaded: Bool?
    var detailVersion: Int?
    var logo: URL?
    var imdbID: String?
    var certification: String?
    var releaseDate: String?
    static func automaticMatch(_ results: [MovieInfo], name: MediaName) -> MovieInfo? {
        func normalize(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).filter { $0.isLetter || $0.isNumber } }
        let wanted = Set(name.searchTitles.map(normalize))
        let exact = results.filter { candidate in
            let titles = [candidate.title, candidate.originalTitle ?? ""]
            let matches = titles.contains { title in
                wanted.contains(normalize(title)) || wanted.contains(normalize(String(title.split(whereSeparator: { $0 == ":" || $0 == "：" }).first ?? "")))
            }
            return matches && (name.year == nil || candidate.year == name.year)
        }
        return exact.count == 1 ? exact.first : nil
    }
    var creditURL: URL { URL(string: "https://www.themoviedb.org/\(kind)/\(id)")! }
}

struct EpisodeInfo: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let episode: Int
    let name: String
    let overview: String
    let still: URL?
    let runtime: Int?
    var airDate: String?
    var rating: Double?
}

struct CastMember: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    let name: String
    let character: String
    let photo: URL?
}

struct TMDBTitleID: Hashable, Sendable, Decodable {
    let id: Int
    let kind: String

    private enum CodingKeys: String, CodingKey {
        case id
        case kind = "media_type"
    }
}

struct MediaName: Sendable {
    private static let prefixPattern = FilenamePattern(#"^\[[^\]]+\]\s*"#)
    private static let episodePattern = FilenamePattern(#"(?i)(?<![A-Za-z0-9])S\d{1,2}(?:E\d{1,3})?(?![A-Za-z0-9])|\b\d{1,2}x\d{1,3}\b|第[一二三四五六七八九十\d]+[季集]"#)
    private static let yearPattern = FilenamePattern(#"(?<![0-9])(?:19|20)\d{2}(?![0-9])"#)
    private static let releasePattern = FilenamePattern(#"(?i)\b(?:2160p|1080p|720p|480p|4k|WEB[- ]?DL|WEBRip|BluRay|BDRip|HDR|DVDRip|HEVC|x26[45])\b"#)
    private static let languagePattern = FilenamePattern(#"(?:韩语|日语|英语|国语|粤语|国粤|中英|简繁|简体|繁体)(?:中字|双字|字幕|配音|版)?(?=\s|$)|中文字幕|双语字幕|中字(?=\s|$)"#)
    private static let spacePattern = FilenamePattern(#"\s+"#)
    let title: String
    let year: String?
    let isTV: Bool
    var searchTitles: [String] {
        var values = [title]
        if title.unicodeScalars.contains(where: { (0x3400...0x9fff).contains(Int($0.value)) }),
           let range = title.range(of: #"[A-Za-z\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]"#, options: .regularExpression) {
            let chinese = title[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if chinese.count >= 2 { values.append(chinese) }
        }
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    init(_ filename: String) {
        var name = filename.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        name = Self.prefixPattern.replacing(in: name, with: "")
        let episode = Self.episodePattern.range(in: name)
        isTV = episode != nil
        if let episode { name = String(name[..<episode.lowerBound]) }
        let releaseYear = Self.yearPattern.expression.matches(in: name, range: NSRange(name.startIndex..., in: name)).last(where: { $0.range.location > 0 })
        if let match = releaseYear, let range = Range(match.range, in: name) {
            year = String(name[range]); name = String(name[..<range.lowerBound])
        } else { year = nil }
        if let range = Self.releasePattern.range(in: name) { name = String(name[..<range.lowerBound]) }
        name = Self.languagePattern.replacing(in: name, with: " ")
        name = Self.spacePattern.replacing(in: name, with: " ")
        title = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-()[]")))
    }
}

enum KeychainToken {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.luma.tmdb", kSecAttrAccount as String: "read-token-v2", kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail] }
    static func isConfigured() -> Bool {
        var q = query
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let result = SecItemCopyMatching(q as CFDictionary, nil)
        if result == errSecSuccess || result == errSecInteractionNotAllowed { return true }
        q[kSecAttrAccount as String] = "read-token"
        let legacy = SecItemCopyMatching(q as CFDictionary, nil)
        return legacy == errSecSuccess || legacy == errSecInteractionNotAllowed
    }
    @concurrent static func readAsync() async throws -> String { try read() }
    static func read() throws -> String {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        var status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound {
            q[kSecAttrAccount as String] = "read-token"
            status = SecItemCopyMatching(q as CFDictionary, &result)
        }
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw failure(status) }
        return text
    }
    static func save(_ token: String) throws {
        let q = query
        if token.isEmpty {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }; return
        }
        let values = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var entry = q; entry.removeValue(forKey: kSecUseAuthenticationUI as String); entry.merge(values) { _, new in new }; entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(entry as CFDictionary, nil)
            guard add == errSecSuccess else { throw failure(add) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> NSError { NSError(domain: "Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "无法读取已保存的 TMDB 凭据（\(status)）。升级后请在 TMDB 设置中重新保存 Token。"] ) }
}

actor TMDBClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    private let transport: Transport
    init(transport: @escaping Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }) { self.transport = transport }
    func request(_ path: String, query: [URLQueryItem] = [], token: String) async throws -> Data {
        guard !token.isEmpty else { throw Self.failure("请先在 TMDB 设置中填写读取访问令牌。") }
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await transport(request)
        switch status {
        case 200...299: return data
        case 401, 403: throw Self.failure("TMDB 令牌无效或没有访问权限，请检查设置。")
        case 429: throw Self.failure("TMDB 请求过于频繁，请稍后重试。")
        default: throw Self.failure("TMDB 请求失败（HTTP \(status)）。")
        }
    }
    private var imageBase: String?
    private struct Configuration: Decodable { let images: Images; struct Images: Decodable { let secure_base_url: String; let poster_sizes: [String] } }
    private struct Response: Decodable { let results: [Entry] }
    private struct Entry: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let original_title: String?
        let original_name: String?
        let release_date: String?
        let first_air_date: String?
        let overview: String?
        let poster_path: String?
        let backdrop_path: String?
        let vote_average: Double?
    }
    func search(title: String, year: String?, isTV: Bool, token: String) async throws -> [MovieInfo] {
        if imageBase == nil {
            let config = try JSONDecoder().decode(Configuration.self, from: await request("configuration", token: token))
            let size = config.images.poster_sizes.contains("w500") ? "w500" : (config.images.poster_sizes.first ?? "original")
            guard let base = URL(string: config.images.secure_base_url), base.scheme == "https", base.host == "image.tmdb.org" else { throw Self.failure("TMDB 图片配置异常。") }
            imageBase = base.absoluteString + size
        }
        var query = [URLQueryItem(name: "query", value: title), URLQueryItem(name: "language", value: "zh-CN"), URLQueryItem(name: "include_adult", value: "false")]
        if let year, !year.isEmpty { query.append(URLQueryItem(name: isTV ? "first_air_date_year" : "year", value: year)) }
        let response = try JSONDecoder().decode(Response.self, from: await request("search/\(isTV ? "tv" : "movie")", query: query, token: token))
        return response.results.map { entry in
            MovieInfo(id: entry.id, kind: isTV ? "tv" : "movie", title: entry.title ?? entry.name ?? title, year: String((entry.release_date ?? entry.first_air_date ?? "").prefix(4)), overview: entry.overview ?? "", poster: entry.poster_path.flatMap { URL(string: (imageBase ?? "") + $0) }, originalTitle: entry.original_title ?? entry.original_name, backdrop: entry.backdrop_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w780" + $0) }, rating: entry.vote_average)
        }
    }
    private struct Details: Decodable {
        let runtime: Int?
        let genres: [Genre]
        let credits: Credits?
        let external_ids: ExternalIDs?
        let images: Images?
        let content_ratings: ContentRatings?
        let release_dates: ReleaseDates?
        let release_date: String?
        let first_air_date: String?
        struct ExternalIDs: Decodable { let imdb_id: String? }
        struct Images: Decodable {
            let logos: [Logo]?
            struct Logo: Decodable { let file_path: String; let iso_639_1: String?; let vote_average: Double? }
        }
        struct ContentRatings: Decodable {
            let results: [Entry]
            struct Entry: Decodable { let iso_3166_1: String; let rating: String }
        }
        struct ReleaseDates: Decodable {
            let results: [Entry]
            struct Entry: Decodable {
                let iso_3166_1: String
                let release_dates: [Certification]
                struct Certification: Decodable { let certification: String }
            }
        }
        struct Genre: Decodable { let name: String }
        struct Credits: Decodable { let cast: [Person] }
        struct Person: Decodable { let id: Int; let name: String; let character: String?; let profile_path: String? }
    }
    private var detailCache: [String: MovieInfo] = [:]
    private var castCreditsCache: [Int: Set<TMDBTitleID>] = [:]
    func castCredits(personID: Int, token: String) async throws -> Set<TMDBTitleID> {
        if let cached = castCreditsCache[personID] { return cached }
        struct Credits: Decodable { let cast: [TMDBTitleID] }
        let data = try await request("person/\(personID)/combined_credits", token: token)
        let credits = Set(try JSONDecoder().decode(Credits.self, from: data).cast)
        castCreditsCache[personID] = credits
        return credits
    }

    func details(_ info: MovieInfo, token: String) async throws -> MovieInfo {
        let key = "\(info.kind):\(info.id)"
        if let cached = detailCache[key] { return cached }
        let data = try await request("\(info.kind)/\(info.id)", query: [URLQueryItem(name: "language", value: "zh-CN"), URLQueryItem(name: "append_to_response", value: info.kind == "tv" ? "credits,external_ids,images,content_ratings" : "credits,external_ids,images,release_dates"), URLQueryItem(name: "include_image_language", value: "zh,en,null")], token: token)
        let detail = try JSONDecoder().decode(Details.self, from: data)
        var result = info
        result.genres = detail.genres.map(\.name); result.runtime = detail.runtime
        result.cast = detail.credits?.cast.prefix(20).map { person in
            CastMember(id: person.id, name: person.name, character: person.character ?? "", photo: person.profile_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w185" + $0) })
        }
        result.imdbID = detail.external_ids?.imdb_id
        result.releaseDate = detail.release_date ?? detail.first_air_date
        let logos = detail.images?.logos ?? []
        let logo = logos.sorted { a, b in
            func rank(_ language: String?) -> Int { language == "zh" ? 0 : language == "en" ? 1 : 2 }
            if rank(a.iso_639_1) != rank(b.iso_639_1) { return rank(a.iso_639_1) < rank(b.iso_639_1) }
            return (a.vote_average ?? 0) > (b.vote_average ?? 0)
        }.first
        result.logo = logo.flatMap { URL(string: "https://image.tmdb.org/t/p/w500" + $0.file_path) }
        for region in ["CN", "US", "GB"] {
            let tv = detail.content_ratings?.results.first { $0.iso_3166_1 == region }?.rating
            let movie = detail.release_dates?.results.first { $0.iso_3166_1 == region }?.release_dates.first { !$0.certification.isEmpty }?.certification
            if let rating = tv ?? movie, !rating.isEmpty { result.certification = rating; break }
        }
        result.detailsLoaded = true; result.detailVersion = 2; detailCache[key] = result
        return result
    }
    private struct SeasonResponse: Codable {
        let episodes: [Episode]
        struct Episode: Codable { let id: Int; let episode_number: Int; let name: String; let overview: String?; let still_path: String?; let runtime: Int?; var air_date: String?; var vote_average: Double? }
    }
    func season(series: Int, number: Int, token: String, cacheDirectory: URL? = nil) async throws -> [EpisodeInfo] {
        let directory = cacheDirectory ?? URL.cachesDirectory.appending(path: "Luma/Seasons")
        let file = directory.appending(path: "\(series)-\(number)-zh-CN-v2.json")
        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let response: SeasonResponse
        if let modified, Date().timeIntervalSince(modified) < 86400, let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(SeasonResponse.self, from: data) { response = cached }
        else {
            let data = try await request("tv/\(series)/season/\(number)", query: [URLQueryItem(name: "language", value: "zh-CN")], token: token)
            response = try JSONDecoder().decode(SeasonResponse.self, from: data)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return response.episodes.map { episode in
            EpisodeInfo(id: episode.id, episode: episode.episode_number, name: episode.name, overview: episode.overview ?? "", still: episode.still_path.flatMap { URL(string: "https://image.tmdb.org/t/p/w500" + $0) }, runtime: episode.runtime, airDate: episode.air_date, rating: episode.vote_average)
        }
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "TMDB", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

struct MatchOutcome: Sendable {
    let ids: [UUID]
    let info: MovieInfo?
}

@MainActor @Observable final class MetadataStore {
    var configured = false
    var status = ""
    var busy = false
    var needsAttention = false
    var completed = 0
    var total = 0
    var autoMatch: Bool { didSet { defaults.set(autoMatch, forKey: "tmdb.autoMatch") } }
    let client: TMDBClient
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var queued = false
    init(client: TMDBClient = TMDBClient(), defaults: UserDefaults = .standard) {
        self.client = client; self.defaults = defaults
        autoMatch = defaults.object(forKey: "tmdb.autoMatch") == nil ? true : defaults.bool(forKey: "tmdb.autoMatch")
        configured = KeychainToken.isConfigured()
    }
    func saveToken(_ value: String) throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainToken.save(token); configured = !token.isEmpty; needsAttention = false
    }
    func matchMissing(_ library: Library, retryReviewed: Bool = false) {
        guard configured else { return }
        if busy { queued = true; return }
        let groups = library.groupedItems.filter { $0.info == nil && !$0.hasLocalTitle && (retryReviewed || $0.items.contains { $0.matchState != "needs-review" }) }.sorted { $0.added > $1.added }
        let jobs = groups.map { group in MatchJob(ids: group.items.map(\.id), filename: group.representative.remotePath != nil ? group.representative.title : URL(filePath: group.representative.relativePath ?? group.representative.url.lastPathComponent).deletingPathExtension().lastPathComponent) }
        guard !jobs.isEmpty else { status = "待处理项目已检查完成；可在“待匹配”中手动纠正。"; return }
        busy = true; needsAttention = false; completed = 0; total = jobs.count; status = "正在读取 TMDB 凭据…"
        task = Task { [self] in
            defer {
                busy = false; task = nil
                if queued { queued = false; matchMissing(library) }
            }
            var matched = 0; var skipped = 0
            do {
                let token = try await KeychainToken.readAsync()
                for start in stride(from: 0, to: jobs.count, by: 3) {
                    try Task.checkCancellation()
                    let batch = Array(jobs[start..<min(start + 3, jobs.count)])
                    let results = try await withThrowingTaskGroup(of: MatchOutcome.self) { group in
                        for job in batch { group.addTask { try await Self.match(job, client: self.client, token: token) } }
                        var values: [MatchOutcome] = []
                        for try await value in group { values.append(value) }
                        return values
                    }
                    try Task.checkCancellation()
                    library.applyMatchBatch(results)
                    for result in results { if result.info == nil { skipped += 1 } else { matched += 1 } }
                    completed += results.count
                    status = "正在匹配海报 \(completed) / \(total) · 已匹配 \(matched) · 待确认 \(skipped)"
                    try await Task.sleep(for: .milliseconds(300))
                }
                status = "匹配完成：\(matched) 个作品已匹配，\(skipped) 个作品需在“待匹配”中确认。"
            } catch is CancellationError { status = "已停止；下次将继续未完成的项目。" }
            catch { needsAttention = true; status = error.localizedDescription + " 已完成的结果已保存，可继续未完成项目。" }
        }
    }
    private struct MatchJob: Sendable { let ids: [UUID]; let filename: String }
    nonisolated private static func match(_ job: MatchJob, client: TMDBClient, token: String) async throws -> MatchOutcome {
        let name = MediaName(job.filename)
        for title in name.searchTitles where !title.isEmpty {
            try Task.checkCancellation()
            let results = try await client.search(title: title, year: name.year, isTV: name.isTV, token: token)
            if let info = MovieInfo.automaticMatch(results, name: name) {
                return MatchOutcome(ids: job.ids, info: try await client.details(info, token: token))
            }
        }
        return MatchOutcome(ids: job.ids, info: nil)
    }
    func cancel() { queued = false; task?.cancel() }
}

actor PosterCache {
    static let shared = PosterCache()
    private let folder = URL.cachesDirectory.appending(path: "Luma/Posters")
    private let memory = NSCache<NSURL, NSData>()
    private var pending: [URL: Task<Data, Error>] = [:]
    func cachedData(for url: URL) -> Data? {
        guard url.scheme == "https", url.host == "image.tmdb.org" else { return nil }
        if let cached = memory.object(forKey: url as NSURL) { return cached as Data }
        let file = folder.appending(path: url.pathComponents.filter { $0 != "/" }.joined(separator: "_"))
        let legacy = folder.appending(path: url.lastPathComponent)
        guard let data = (try? Data(contentsOf: file)) ?? (try? Data(contentsOf: legacy)) else { return nil }
        memory.totalCostLimit = 64 * 1024 * 1024
        memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }
    func data(for url: URL) async throws -> Data {
        if (url.isFileURL || url.scheme == "luma-source"), SidecarIndex.imageExtensions.contains(url.pathExtension.lowercased()) {
            return try await sidecarData(for: url)
        }
        guard url.scheme == "https", url.host == "image.tmdb.org", !url.lastPathComponent.isEmpty else { throw TMDBClient.failure("无效的海报地址。") }
        if let cached = memory.object(forKey: url as NSURL) { return cached as Data }
        if let task = pending[url] { return try await task.value }
        let file = folder.appending(path: url.pathComponents.filter { $0 != "/" }.joined(separator: "_"))
        let legacy = folder.appending(path: url.lastPathComponent)
        if let data = (try? Data(contentsOf: file)) ?? (try? Data(contentsOf: legacy)) {
            memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count); return data
        }
        let folder = folder
        let task = Task {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 20_000_000 else { throw TMDBClient.failure("海报下载失败。") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return data
        }
        pending[url] = task
        defer { pending[url] = nil }
        let data = try await task.value
        memory.totalCostLimit = 64 * 1024 * 1024
        memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }

    private func sidecarData(for url: URL) async throws -> Data {
        if let task = pending[url] { return try await task.value }
        let task = Task { try await Self.readSidecar(url) }
        pending[url] = task
        defer { pending[url] = nil }
        return try await task.value
    }

    @concurrent private static func readSidecar(_ url: URL) async throws -> Data {
        let limit = 20_000_000
        if url.isFileURL {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            if let data = try file.read(upToCount: limit + 1), data.count <= limit { return data }
        } else {
            let resolved = try await RemoteSourceResolver.resolveSidecar(url)
            let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: resolved, timeoutInterval: 20))
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= limit else {
                throw TMDBClient.failure("无法读取来源图片。")
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw TMDBClient.failure("来源图片超过 20 MB。") }
                data.append(byte)
            }
            return data
        }
        throw TMDBClient.failure("无法读取来源图片，或图片超过 20 MB。")
    }
}
