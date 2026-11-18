import Foundation

/// Cancels before reading a non-range response or a body larger than the requested chunk.
private final class RangeReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var body = Data()
    private var failure: (any Error)?
    private let expected: Int
    private let range: String
    private let ownsSession: Bool
    private var continuation: CheckedContinuation<Data, any Error>?
    init(expected: Int, range: String, ownsSession: Bool) { self.expected = expected; self.range = range; self.ownsSession = ownsSession }
    func run(_ request: URLRequest, session supplied: URLSession?) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                let session = supplied ?? URLSession(configuration: configuration)
                let task = session.dataTask(with: request)
                task.delegate = self
                lock.lock(); self.task = task; let cancelled = self.cancelled; lock.unlock()
                task.resume(); if cancelled { task.cancel() }
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock(); task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 206,
              response.value(forHTTPHeaderField: "Content-Range") == range,
              response.expectedContentLength <= expected else {
            failure = SourceWorker.failure("服务器不支持原始文件分段读取。")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= expected else { failure = SourceWorker.failure("服务器返回内容超过请求范围。"); dataTask.cancel(); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock(); self.task = nil; lock.unlock()
        defer { if ownsSession { session.invalidateAndCancel() } }
        if let error = failure ?? error { continuation?.resume(throwing: error) }
        else if body.count != expected { continuation?.resume(throwing: SourceWorker.failure("远程文件读取不完整。")) }
        else { continuation?.resume(returning: body) }
        continuation = nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        SameOriginRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
}

enum BoundedRangeRequest {
    static func read(_ request: URLRequest, lower: Int64, upper: Int64, length: Int64, session: URLSession? = nil) async throws -> Data {
        try await RangeReceiver(expected: Int(upper - lower + 1), range: "bytes \(lower)-\(upper)/\(length)", ownsSession: session == nil).run(request, session: session)
    }
}
