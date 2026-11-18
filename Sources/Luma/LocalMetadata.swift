import Foundation

struct LocalMetadata: Codable, Equatable, Sendable {
    var work: NFORecord?
    var episode: NFORecord?
    var showFile: URL?
}

struct NFORecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case movie, tvshow, episodedetails }
    let kind: Kind
    var title: String?
    var originalTitle: String?
    var overview: String?
    var year: String?
    var releaseDate: String?
    var runtime: Int?
    var genres: [String] = []
    var certification: String?
    var season: Int?
    var episode: Int?
    var showTitle: String?
    var imdbID: String?
}

struct NFOCandidates: Sendable {
    var video: URL?
    var show: URL?
}

enum NFOReader {
    private static let byteLimit = 512 * 1024
    private enum Outcome: Sendable {
        case parsed(NFORecord?)
        case unreadable

        var record: NFORecord? {
            if case .parsed(let record) = self { return record }
            return nil
        }
        var failed: Bool {
            if case .unreadable = self { return true }
            return false
        }
    }

    @concurrent static func enrich(
        _ input: [ScannedFile],
        resolve: @escaping @Sendable (URL) async throws -> URL = { $0 }
    ) async throws -> [ScannedFile] {
        let urls = Array(Set(input.flatMap { [$0.nfo?.video, $0.nfo?.show].compactMap { $0 } }))
        guard !urls.isEmpty else { return input }
        var outcomes: [URL: Outcome] = [:]
        for start in stride(from: 0, to: urls.count, by: 8) {
            try Task.checkCancellation()
            await withTaskGroup(of: (URL, Outcome).self) { group in
                for url in urls[start..<min(start + 8, urls.count)] {
                    group.addTask {
                        do { return (url, .parsed(try await read(try await resolve(url)))) }
                        catch { return (url, .unreadable) }
                    }
                }
                for await (url, outcome) in group { outcomes[url] = outcome }
            }
        }
        try Task.checkCancellation()
        return input.map { original in
            guard let candidates = original.nfo else { return original }
            var file = original
            let video = candidates.video.flatMap { outcomes[$0] }
            let show = candidates.show.flatMap { outcomes[$0] }
            file.nfoReadFailed = video?.failed == true || show?.failed == true
            if let record = video?.record, record.kind == .movie {
                file.localMetadata = LocalMetadata(work: record)
            } else {
                let episode = video?.record.flatMap { $0.kind == .episodedetails ? $0 : nil }
                let work = show?.record.flatMap { $0.kind == .tvshow ? $0 : nil }
                if episode != nil || work != nil {
                    file.localMetadata = LocalMetadata(work: work, episode: episode, showFile: work == nil ? nil : candidates.show)
                }
            }
            return file
        }
    }

    private static func read(_ url: URL) async throws -> NFORecord? {
        let data: Data
        if url.isFileURL {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        } else {
            let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 10))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            guard response.expectedContentLength <= byteLimit else { return nil }
            var buffer = Data()
            for try await byte in bytes {
                guard buffer.count < byteLimit else { return nil }
                buffer.append(byte)
            }
            data = buffer
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> NFORecord? {
        guard data.count <= byteLimit else { return nil }
        let encoding: String.Encoding = data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE]) ? .utf16 : .utf8
        guard let text = String(data: data, encoding: encoding), !text.contains("\0"),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { return nil }
        let delegate = NFOParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.record
    }
}

private final class NFOParser: NSObject, XMLParserDelegate {
    private(set) var record: NFORecord?
    private var path: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if path.isEmpty, let kind = NFORecord.Kind(rawValue: element.lowercased()) { record = NFORecord(kind: kind) }
        path.append(element.lowercased())
        if path.count == 2 { text = "" }
        if path.count > 16 { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if path.count >= 2 { text.append(string) }
        if text.utf8.count > 64 * 1024 { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let text = String(data: data, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard !path.isEmpty else { return }
        defer { path.removeLast() }
        guard path.count == 2 else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch path[1] {
        case "title": record?.title = value
        case "originaltitle": record?.originalTitle = value
        case "plot": record?.overview = value
        case "year": if value.count == 4, Int(value) != nil { record?.year = value }
        case "premiered", "aired", "releasedate":
            if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                if record?.releaseDate == nil || (record?.kind == .episodedetails && path[1] == "aired") { record?.releaseDate = value }
            }
        case "runtime": if let runtime = Int(value), (1...1440).contains(runtime) { record?.runtime = runtime }
        case "genre": if record?.genres.contains(value) == false { record?.genres.append(value) }
        case "mpaa": record?.certification = value
        case "season": if let season = Int(value), (0...999).contains(season) { record?.season = season }
        case "episode": if let episode = Int(value), (0...9999).contains(episode) { record?.episode = episode }
        case "showtitle": record?.showTitle = value
        case "uniqueid", "imdbid": if IMDbRating.validID(value) { record?.imdbID = value }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        parser.abortParsing()
    }
}
