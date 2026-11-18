import Foundation

// Requests retain credentials only for the configured origin, including redirects.
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        var request = request
        guard let original = task.originalRequest?.url, let target = request.url else { completionHandler(nil); return }
        if original.scheme == "https" && target.scheme != "https" { completionHandler(nil); return }
        if original.host != target.host || original.port != target.port || original.scheme != target.scheme {
            if !["GET", "HEAD"].contains(task.originalRequest?.httpMethod ?? "GET") { completionHandler(nil); return }
            for name in ["Authorization", "X-Emby-Token", "X-Plex-Token"] { request.setValue(nil, forHTTPHeaderField: name) }
        }
        completionHandler(request)
    }
}

enum MediaServerClient {
    struct HTTPFailure: LocalizedError {
        let status: Int
        var errorDescription: String? { "服务器返回 HTTP \(status)。请检查地址、账号权限和访问令牌。" }
    }
    static func header(kind: SourceKind, token: String) -> (String, String) {
        if kind == .plex { return ("X-Plex-Token", token) }
        if kind == .jellyfin { return ("Authorization", "MediaBrowser Client=\"Velun\", Device=\"Mac\", DeviceId=\"local.luma.player\", Version=\"0.16\", Token=\"\(token)\"") }
        return ("X-Emby-Token", token)
    }
    static func endpoint(_ base: URL, path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: base.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        return parts.url!
    }
    static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: SameOriginRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw HTTPFailure(status: code)
        }
        return data
    }
    static func scan(_ source: LibrarySource, credentials original: SourceCredentials) async throws -> (result: ScanResult, credentials: SourceCredentials) {
        do { return try await scanAuthenticated(source, credentials: original) }
        catch let error as HTTPFailure {
            guard error.status == 401, [.jellyfin, .emby].contains(source.kind),
                  !original.token.isEmpty, !original.username.isEmpty else { throw error }
            try Task.checkCancellation()
            var refreshed = original; refreshed.token = ""; refreshed.userID = ""
            // Exactly one fresh login; a second 401 is returned to the user.
            return try await scanAuthenticated(source, credentials: refreshed)
        }
    }
    private static func scanAuthenticated(_ source: LibrarySource, credentials original: SourceCredentials) async throws -> (result: ScanResult, credentials: SourceCredentials) {
        var credentials = original
        if source.kind == .plex {
            guard !credentials.token.isEmpty else { throw SourceWorker.failure("Plex 需要 X-Plex-Token。") }
            let files = try await plex(source, token: credentials.token)
            return (ScanResult(files: files, unreadable: 0), credentials)
        }
        if credentials.token.isEmpty {
            guard !credentials.username.isEmpty else { throw SourceWorker.failure("请填写服务器账号密码或访问令牌。") }
            let auth = "MediaBrowser Client=\"Velun\", Device=\"Mac\", DeviceId=\"local.luma.player\", Version=\"0.16\""
            let body = try JSONSerialization.data(withJSONObject: ["Username": credentials.username, "Pw": credentials.password])
            let data = try await request(endpoint(source.url, path: "Users/AuthenticateByName"), method: "POST", headers: ["Authorization": auth, "X-Emby-Authorization": auth, "Content-Type": "application/json"], body: body)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let token = json?["AccessToken"] as? String, !token.isEmpty else { throw SourceWorker.failure("服务器没有返回访问令牌。") }
            credentials.token = token; credentials.userID = (json?["User"] as? [String: Any])?["Id"] as? String ?? ""
        }
        let (key, value) = header(kind: source.kind, token: credentials.token)
        let path = credentials.userID.isEmpty ? "Items" : "Users/\(credentials.userID)/Items"
        var start = 0; var files: [ScannedFile] = []; var seen = Set<String>()
        while start < 200_000 {
            try Task.checkCancellation()
            let query = ["Recursive": "true", "IncludeItemTypes": "Movie,Episode", "Fields": "MediaSources,Path", "StartIndex": String(start), "Limit": "500"].map { URLQueryItem(name: $0.key, value: $0.value) }
            let data = try await request(endpoint(source.url, path: path, query: query), headers: [key: value])
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let items = json["Items"] as? [[String: Any]] else { throw SourceWorker.failure("服务器媒体列表格式不正确。") }
            if items.isEmpty { break }
            var newItems = 0
            for item in items {
                guard let id = item["Id"] as? String, seen.insert(id).inserted, let name = item["Name"] as? String else { continue }
                newItems += 1
                let series = item["SeriesName"] as? String
                let season = item["ParentIndexNumber"] as? Int ?? 1, episode = item["IndexNumber"] as? Int ?? 0
                let year = item["ProductionYear"] as? Int
                let sources = item["MediaSources"] as? [[String: Any]]
                let suffix = (sources?.first?["Container"] as? String ?? item["Container"] as? String ?? "mkv").lowercased()
                let title = series.map { "\($0).S\(String(format: "%02d", season))E\(String(format: "%02d", episode)).\(name)" } ?? name + (year.map { ".\($0)" } ?? "")
                let relative = "\(safeName(series ?? "电影"))/\(safeName(title)).\(id).\(safeName(suffix))"
                files.append(ScannedFile(url: RemoteSources.virtualURL(source: source.id, path: relative), relativePath: relative, remotePath: "Items/\(id)/Download", displayTitle: title))
            }
            start += items.count
            if newItems == 0 { throw SourceWorker.failure("服务器分页结果重复，已停止以避免重复导入。") }
            if start >= (json["TotalRecordCount"] as? Int ?? start) { break }
        }
        return (ScanResult(files: files, unreadable: 0), credentials)
    }
    static func safeName(_ name: String) -> String { name.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: "\0", with: "") }
    private static func plex(_ source: LibrarySource, token: String) async throws -> [ScannedFile] {
        let headers = ["X-Plex-Token": token]
        let data = try await request(endpoint(source.url, path: "library/sections"), headers: headers)
        let sections = try PlexXML.parse(data).directories
        var files: [ScannedFile] = []
        for section in sections where ["movie", "show"].contains(section["type"] ?? "") {
            guard let key = section["key"], key.allSatisfy(\.isNumber) else { continue }
            var offset = 0
            while offset < 200_000 {
                let query = [URLQueryItem(name: "type", value: section["type"] == "show" ? "4" : "1"), URLQueryItem(name: "X-Plex-Container-Start", value: String(offset)), URLQueryItem(name: "X-Plex-Container-Size", value: "500")]
                let data = try await request(endpoint(source.url, path: "library/sections/\(key)/all", query: query), headers: headers)
                let page = try PlexXML.parse(data)
                for record in page.videos {
                    guard let part = record["part"], let partURL = URL(string: part), partURL.scheme == nil, !part.contains(".."), let name = record["title"] else { continue }
                    let series = record["grandparentTitle"]
                    let title = series.map { "\($0).S\(String(format: "%02d", Int(record["parentIndex"] ?? "1") ?? 1))E\(String(format: "%02d", Int(record["index"] ?? "0") ?? 0)).\(name)" } ?? name + (record["year"].map { ".\($0)" } ?? "")
                    let suffix = URL(filePath: record["file"] ?? "video.mkv").pathExtension
                    let relative = "\(safeName(series ?? "电影"))/\(safeName(title)).\(record["ratingKey"] ?? UUID().uuidString).\(suffix.isEmpty ? "mkv" : suffix)"
                    files.append(ScannedFile(url: RemoteSources.virtualURL(source: source.id, path: relative), relativePath: relative, remotePath: part.trimmingCharacters(in: CharacterSet(charactersIn: "/")), displayTitle: title))
                }
                offset += page.videos.count
                if page.videos.isEmpty || offset >= page.total { break }
            }
        }
        return files
    }
}

private final class PlexXML: NSObject, XMLParserDelegate {
    var directories: [[String: String]] = []; var videos: [[String: String]] = []; var current: [String: String]?
    var total = 0
    static func parse(_ data: Data) throws -> PlexXML {
        let delegate = PlexXML(); let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw SourceWorker.failure("Plex XML 列表无法解析。") }; return delegate
    }
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if element == "MediaContainer" { total = Int(attributes["totalSize"] ?? attributes["size"] ?? "0") ?? 0 }
        if element == "Directory" { directories.append(attributes) }
        if element == "Video" { current = attributes }
        if element == "Part", current?["part"] == nil { current?["part"] = attributes["key"]; current?["file"] = attributes["file"] }
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) { if element == "Video", let item = current { videos.append(item); current = nil } }
}
