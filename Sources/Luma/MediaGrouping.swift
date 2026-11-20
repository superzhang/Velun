import Foundation

struct EpisodeCode: Comparable, Hashable, Sendable {
    private static let standard = FilenamePattern(#"(?i)S\d{1,2}E\d{1,3}"#)
    private static let alternative = FilenamePattern(#"\b\d{1,2}x\d{1,3}\b"#)
    private static let chineseSeason = FilenamePattern("第[一二三四五六七八九十百零〇两0-9]+季")
    private static let chineseEpisode = FilenamePattern("第[一二三四五六七八九十百零〇两0-9]+集")
    let season: Int
    let episode: Int
    init(_ filename: String) {
        if let range = Self.standard.range(in: filename) {
            let parts = filename[range].lowercased().dropFirst().split(separator: "e")
            season = Int(parts[0]) ?? 1; episode = Int(parts[1]) ?? 0
        } else if let range = Self.alternative.range(in: filename) {
            let parts = filename[range].split(separator: "x"); season = Int(parts[0]) ?? 1; episode = Int(parts[1]) ?? 0
        } else {
            func number(before unit: String, fallback: Int) -> Int {
                guard let range = (unit == "季" ? Self.chineseSeason : Self.chineseEpisode).range(in: filename) else { return fallback }
                let text = String(filename[range].dropFirst().dropLast())
                if let value = Int(text) { return value }
                let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
                var total = 0; var pending = 0
                for character in text {
                    if character == "十" { total += max(1, pending) * 10; pending = 0 }
                    else if character == "百" { total += max(1, pending) * 100; pending = 0 }
                    else { pending = digits[character] ?? 0 }
                }
                return total + pending
            }
            season = number(before: "季", fallback: 1)
            episode = number(before: "集", fallback: 0)
        }
    }
    init(_ media: Media) {
        let record = media.localMetadata?.episode
        let fallback = Self(media.url.lastPathComponent)
        season = record?.season ?? fallback.season
        episode = record?.episode ?? fallback.episode
    }
    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.season, lhs.episode) < (rhs.season, rhs.episode) }
}

struct EpisodeSlot: Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case numbered(EpisodeCode)
        case unnumbered(UUID)
    }

    let id: ID
    let code: EpisodeCode
    let files: [Media]
    var isWatched: Bool { files.contains(where: \.isWatched) }

    func preferredFile(favoring selectedID: UUID? = nil) -> Media {
        if let selectedID, let selected = files.first(where: { $0.id == selectedID }) { return selected }
        return files.lazy.filter { $0.sourceMissing != true && $0.isContinuing }
            .max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
            ?? files.first { $0.sourceMissing != true } ?? files[0]
    }

    static func make(_ items: [Media], codes: [UUID: EpisodeCode]? = nil) -> [Self] {
        var order: [(ID, EpisodeCode)] = []
        var buckets: [ID: [Media]] = [:]
        for item in items {
            let code = codes?[item.id] ?? EpisodeCode(item)
            let key: ID = code.episode > 0 ? .numbered(code) : .unnumbered(item.id)
            if buckets[key] == nil { order.append((key, code)) }
            buckets[key, default: []].append(item)
        }
        return order.map { id, code in Self(id: id, code: code, files: buckets[id]!) }
    }
}

struct MediaGroup: Identifiable, Sendable {
    let id: String
    let items: [Media]
    let representative: Media
    let info: MovieInfo?
    let nfo: NFORecord?
    var hasLocalTitle: Bool { nfo?.title != nil }
    var originalTitle: String? { nfo?.originalTitle ?? info?.originalTitle }
    var overview: String? { nfo?.overview ?? info?.overview }
    var releaseDate: String? { nfo?.releaseDate ?? info?.releaseDate }
    var certification: String? { nfo?.certification ?? info?.certification }
    var runtime: Int? { nfo?.runtime ?? info?.runtime }
    var imdbID: String? { nfo?.imdbID ?? info?.imdbID }
    var year: String? { nfo?.year ?? nfo?.releaseDate.map { String($0.prefix(4)) } ?? info?.year }
    var genres: [String] { nfo.map(\.genres).flatMap { $0.isEmpty ? nil : $0 } ?? info?.genres ?? [] }
    let isTV: Bool
    let episodes: [EpisodeSlot]
    let title: String
    let subtitle: String
    let isWatched: Bool
    let hasFavorite: Bool
    let lastPlayed: Date
    let added: Date
    let resume: Media
    let searchIndex: String
    var localPoster: URL? { items.lazy.filter { $0.sourceMissing != true }.compactMap { $0.sidecars?.poster }.first }
    var localBackdrop: URL? { items.lazy.filter { $0.sourceMissing != true }.compactMap { $0.sidecars?.backdrop }.first }
    var poster: URL? { localPoster ?? info?.poster }
    init(id: String, items: [Media], codes: [UUID: EpisodeCode]? = nil, template: MediaGroup? = nil) {
        precondition(!items.isEmpty)
        self.id = id; self.items = items; representative = items[0]
        let info = items.lazy.compactMap(\.metadata).first
        self.info = info
        nfo = items.lazy.compactMap { $0.localMetadata?.work }.first
        let episode = items.lazy.compactMap { $0.localMetadata?.episode }.first
        let knownTitle = nfo?.title ?? episode?.showTitle ?? info?.title
        let parsed = knownTitle == nil ? MediaName(items[0].url.deletingPathExtension().lastPathComponent) : nil
        let localKind = nfo?.kind ?? episode?.kind
        isTV = localKind.map { $0 != .movie } ?? info.map { $0.kind == "tv" } ?? parsed?.isTV ?? false
        episodes = isTV ? EpisodeSlot.make(items, codes: codes) : []
        title = knownTitle ?? (isTV ? parsed.flatMap { $0.title.isEmpty ? nil : $0.title } : nil) ?? items[0].title
        if let template { subtitle = template.subtitle }
        else if isTV {
            let seasons = Set(episodes.map { $0.code.season })
            subtitle = "\(seasons.count) 季 · \(episodes.count) 集"
        } else if items.count > 1 { subtitle = "\(items.count) 项内容" }
        else {
            let year = nfo?.year ?? nfo?.releaseDate.map { String($0.prefix(4)) } ?? info?.year
            subtitle = year.flatMap { $0.isEmpty ? nil : $0 } ?? items[0].format
        }
        isWatched = isTV ? episodes.allSatisfy(\.isWatched) : items.allSatisfy(\.isWatched)
        hasFavorite = items.contains(where: \.favorite)
        lastPlayed = items.compactMap(\.lastPlayed).max() ?? .distantPast
        added = items.map(\.added).max() ?? .distantPast
        let available = items.filter { $0.sourceMissing != true }
        let playable = available.isEmpty ? items : available
        let unfinishedEpisode = episodes.first { !$0.isWatched && $0.files.contains { $0.sourceMissing != true } }
        resume = playable.filter { $0.isContinuing || $0.watchlisted == true }
            .max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
            ?? unfinishedEpisode?.preferredFile()
            ?? (isTV ? nil : playable.first { !$0.isWatched })
            ?? playable[0]
        if let template { searchIndex = template.searchIndex }
        else {
            let searchable = items.flatMap { [$0.title, $0.localMetadata?.episode?.title].compactMap { $0 } }
            searchIndex = Self.searchKey(([title] + searchable).joined(separator: "\n"))
        }
    }

    func episode(containing id: UUID) -> EpisodeSlot? {
        episodes.first { $0.files.contains { $0.id == id } }
    }

    func playbackItems(favoring selectedID: UUID? = nil) -> [Media] {
        guard isTV else { return items }
        return episodes.compactMap { slot in
            let preferred = slot.preferredFile(favoring: selectedID)
            if preferred.sourceMissing != true { return preferred }
            let available = slot.preferredFile()
            return available.sourceMissing == true ? nil : available
        }
    }
    static func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func make(_ items: [Media]) -> [Self] {
        var order: [String] = []
        var buckets: [String: [Media]] = [:]
        for item in items {
            let key: String
            if let show = item.localMetadata?.showFile { key = "tv-nfo:\(show.absoluteString)" }
            else if let info = item.metadata, item.localMetadata?.work?.kind != .movie || info.kind == "movie" { key = "\(info.kind):\(info.id)" }
            else if let name = item.localMetadata?.episode?.showTitle {
                key = "tv-nfo-title:\(item.sourceID?.uuidString ?? ""):\(Self.searchKey(name))"
            }
            else {
                let parsed = MediaName(item.url.deletingPathExtension().lastPathComponent)
                key = item.localMetadata?.work?.kind != .movie && parsed.isTV && !parsed.title.isEmpty ? "tv-name:\(parsed.title.lowercased())" : item.id.uuidString
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        var result: [Self] = []; result.reserveCapacity(order.count)
        for key in order {
            var files = buckets.removeValue(forKey: key)!
            let codes = Dictionary(uniqueKeysWithValues: files.map { ($0.id, EpisodeCode($0)) })
            files.sort { a, b in
                let left = codes[a.id]!; let right = codes[b.id]!
                return left == right ? a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending : left < right
            }
            result.append(Self(id: key, items: files, codes: codes))
        }
        return result
    }
}
