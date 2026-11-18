import Foundation
import Network

/// Checks only hosts already advertised on the LAN; an NFS NULL RPC reads no files.
enum NFSDiscovery {
    static let xid: UInt32 = 0x4c554d41
    static var request: Data {
        let words: [UInt32] = [0x80000028, xid, 0, 2, 100003, 3, 0, 0, 0, 0, 0]
        return words.reduce(into: Data()) { result, word in var value = word.bigEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
    }
    static func acceptsReply(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        func word(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard let marker = word(0), marker & 0x80000000 != 0, marker & 0x7fffffff >= 24,
              Int(marker & 0x7fffffff) + 4 <= bytes.count, word(4) == xid, word(8) == 1, word(12) == 0,
              let verifierLength = word(20), verifierLength <= 400 else { return false }
        let offset = 24 + ((Int(verifierLength) + 3) / 4 * 4)
        return word(offset) == 0 || word(offset) == 2 // success or supported program with a different NFS version
    }
    static func probe(host: String, port: UInt16 = 2049) async -> Bool {
        let probe = NFSProbe(host: host, port: port)
        return await withTaskCancellationHandler { await probe.result() } onCancel: { probe.cancel() }
    }
}

private final class NFSProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.luma.nfs-discovery")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false
    private var buffer = Data()
    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }
    func result() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.finished { continuation.resume(returning: false); return }
                self.continuation = continuation
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.connection.send(content: NFSDiscovery.request, completion: .contentProcessed { error in
                            if error != nil { self.finish(false) } else { self.receive() }
                        })
                    case .failed, .cancelled: self.finish(false)
                    default: break
                    }
                }
                self.queue.asyncAfter(deadline: .now() + 1.5) { self.finish(false) }
                self.connection.start(queue: self.queue)
            }
        }
    }
    func cancel() { queue.async { self.finish(false) } }
    private func receive() {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
            if let data { self.buffer.append(data) }
            if NFSDiscovery.acceptsReply(self.buffer) { self.finish(true) }
            else if error != nil || complete || self.buffer.count >= 4096 { self.finish(false) }
            else { self.receive() }
        }
    }
    private func finish(_ value: Bool) {
        guard !finished else { return }; finished = true
        connection.stateUpdateHandler = nil; connection.cancel()
        continuation?.resume(returning: value); continuation = nil
    }
}
