import Foundation
import Network

/// Streams authenticated server files in bounded chunks; never buffers a full movie.
final class HTTPMediaBridge: @unchecked Sendable {
    private let listener: NWListener
    private let origin: URL
    private let header: (String, String)
    private let prefix = UUID().uuidString
    private let lock = NSLock()
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private let queue = DispatchQueue(label: "local.luma.media-bridge")
    init(source: LibrarySource, credentials: SourceCredentials) throws {
        origin = source.url
        header = MediaServerClient.header(kind: source.kind, token: credentials.token)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): self?.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                case .cancelled: self?.listener.stateUpdateHandler = nil; continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
        guard let port = listener.port else { throw SourceWorker.failure("无法创建媒体播放端口。") }
        return URL(string: "http://127.0.0.1:\(port.rawValue)/\(prefix)/")!
    }
    func stop() {
        lock.lock(); stopped = true
        let active = Array(connections.values), running = Array(tasks.values)
        connections.removeAll(); tasks.removeAll(); lock.unlock()
        listener.cancel(); for task in running { task.cancel() }; for connection in active { connection.cancel() }
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { connection.cancel(); return }
        connections[id] = connection
        connection.start(queue: queue)
        tasks[id] = Task { [weak self] in
            guard let self else { connection.cancel(); return }
            await self.serve(connection)
            self.finish(id, connection: connection)
        }
    }
    private func finish(_ id: UUID, connection: NWConnection) {
        connection.cancel(); lock.lock(); connections[id] = nil; tasks[id] = nil; lock.unlock()
    }
    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: SourceWorker.failure(complete ? "连接结束。" : "空请求。")) }
            }
        }
    }
    private func send(_ data: Data, to connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func serve(_ connection: NWConnection) async {
        var sentHeaders = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var input = Data()
            while input.range(of: Data("\r\n\r\n".utf8)) == nil {
                input.append(try await receive(connection))
                guard input.count <= 65_536 else { throw SourceWorker.failure("请求过长。") }
            }
            let lines = String(decoding: input, as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])),
                  let url = URL(string: "http://localhost" + first[1]), url.path.hasPrefix("/\(prefix)/") else { throw SourceWorker.failure("无效播放请求。") }
            let path = String(url.path.dropFirst(prefix.count + 2))
            guard RemoteSources.safePath(path), url.query == nil else { throw SourceWorker.failure("无效媒体路径。") }
            let upstream = path.split(separator: "/").reduce(origin) { $0.appending(path: String($1)) }
            var request = URLRequest(url: upstream); request.httpMethod = "HEAD"
            request.setValue(header.1, forHTTPHeaderField: header.0)
            let (_, head) = try await session.data(for: request)
            guard let head = head as? HTTPURLResponse, (200..<300).contains(head.statusCode),
                  let length = head.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), length > 0 else { throw SourceWorker.failure("服务器未提供原始文件大小。") }
            let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }?.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
            var lower: Int64 = 0, upper = length - 1
            if let range {
                guard range.hasPrefix("bytes="), !range.contains(",") else { throw SourceWorker.failure("无效读取范围。") }
                let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw SourceWorker.failure("无效读取范围。") }
                if parts[0].isEmpty, let suffix = Int64(parts[1]), suffix > 0 { lower = max(0, length - suffix) }
                else {
                    guard let start = Int64(parts[0]) else { throw SourceWorker.failure("无效读取范围。") }; lower = start
                    if !parts[1].isEmpty { guard let end = Int64(parts[1]) else { throw SourceWorker.failure("无效读取范围。") }; upper = min(upper, end) }
                }
            }
            guard lower >= 0, lower <= upper, lower < length else {
                try await send(Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(length)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection); return
            }
            var headers = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\nContent-Length: \(upper - lower + 1)\r\nAccept-Ranges: bytes\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n"
            if range != nil { headers += "Content-Range: bytes \(lower)-\(upper)/\(length)\r\n" }
            headers += "\r\n"
            try await send(Data(headers.utf8), to: connection); sentHeaders = true
            guard first[0] != "HEAD" else { return }
            request.httpMethod = "GET"
            while lower <= upper {
                try Task.checkCancellation()
                let end = min(upper, lower + 1_048_575)
                request.setValue("bytes=\(lower)-\(end)", forHTTPHeaderField: "Range")
                let bytes = try await BoundedRangeRequest.read(request, lower: lower, upper: end, length: length, session: session)
                try await send(bytes, to: connection); lower = end + 1
            }
        } catch {
            if !sentHeaders { try? await send(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection) }
        }
    }
}
