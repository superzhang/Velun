import Foundation

struct EpisodeCode: Comparable, Sendable {
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
    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.season, lhs.episode) < (rhs.season, rhs.episode) }
}

struct MediaGroup: Identifiable, Sendable {
    let id: String
    let items: [Media]
    let representative: Media
    let info: MovieInfo?
    let isTV: Bool
    let title: String
    let subtitle: String
    let isWatched: Bool
    let hasFavorite: Bool
    let lastPlayed: Date
    let added: Date
    let resume: Media
    let searchIndex: String
    init(id: String, items: [Media], codes: [UUID: EpisodeCode]? = nil, template: MediaGroup? = nil) {
        precondition(!items.isEmpty)
        self.id = id; self.items = items; representative = items[0]
        let info = items.lazy.compactMap(\.metadata).first
        self.info = info
        let parsed = info == nil ? MediaName(items[0].url.deletingPathExtension().lastPathComponent) : nil
        isTV = info.map { $0.kind == "tv" } ?? parsed!.isTV
        title = info?.title ?? (isTV ? parsed!.title : items[0].title)
        if let template { subtitle = template.subtitle }
        else if isTV {
            let seasons = Set(items.map { codes?[$0.id]?.season ?? EpisodeCode($0.url.lastPathComponent).season })
            subtitle = "\(seasons.count) 季 · \(items.count) 集"
        } else if items.count > 1 { subtitle = "\(items.count) 项内容" }
        else { subtitle = info?.year.isEmpty == false ? info!.year : items[0].format }
        isWatched = items.allSatisfy(\.isWatched)
        hasFavorite = items.contains(where: \.favorite)
        lastPlayed = items.compactMap(\.lastPlayed).max() ?? .distantPast
        added = items.map(\.added).max() ?? .distantPast
        resume = items.filter { $0.isContinuing || $0.watchlisted == true }.max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) } ?? items.first(where: { !$0.isWatched }) ?? items[0]
        searchIndex = template?.searchIndex ?? Self.searchKey(([title] + items.map(\.title)).joined(separator: "\n"))
    }
    static func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func make(_ items: [Media]) -> [Self] {
        var order: [String] = []
        var buckets: [String: [Media]] = [:]
        for item in items {
            let key: String
            if let info = item.metadata { key = "\(info.kind):\(info.id)" }
            else {
                let parsed = MediaName(item.url.deletingPathExtension().lastPathComponent)
                key = parsed.isTV && !parsed.title.isEmpty ? "tv-name:\(parsed.title.lowercased())" : item.id.uuidString
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        var result: [Self] = []; result.reserveCapacity(order.count)
        for key in order {
            var files = buckets.removeValue(forKey: key)!
            let codes = Dictionary(uniqueKeysWithValues: files.map { ($0.id, EpisodeCode($0.url.lastPathComponent)) })
            files.sort { a, b in
                let left = codes[a.id]!; let right = codes[b.id]!
                return left == right ? a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending : left < right
            }
            result.append(Self(id: key, items: files, codes: codes))
        }
        return result
    }
}
