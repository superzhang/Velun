import Foundation
import Darwin

enum DLNAClient {
    @concurrent static func discover() async throws -> [URL] {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { throw SourceWorker.failure("无法创建局域网发现连接。") }; defer { Darwin.close(socket) }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(1900).bigEndian; address.sin_addr.s_addr = inet_addr("239.255.255.250")
        let request = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n".utf8)
        let sent = request.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socket, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard sent >= 0 else { throw SourceWorker.failure("局域网发现未能发送，请检查本地网络访问权限。") }
        var found = Set<URL>(); var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = ContinuousClock.now + .seconds(2)
        for _ in 0..<100 {
            if ContinuousClock.now >= deadline { break }
            try Task.checkCancellation()
            let count = recv(socket, &buffer, buffer.count, 0); if count <= 0 { continue }
            for line in String(decoding: buffer.prefix(count), as: UTF8.self).components(separatedBy: "\r\n") {
                guard line.lowercased().hasPrefix("location:"), let colon = line.firstIndex(of: ":") else { continue }
                if let url = SourceKind.dlna.validatedURL(String(line[line.index(after: colon)...])) { found.insert(url) }
            }
        }
        return found.sorted { $0.absoluteString < $1.absoluteString }
    }
    static func scan(_ source: LibrarySource) async throws -> ScanResult {
        let description = try RemoteXML.parse(await MediaServerClient.request(source.url))
        guard let service = description.descendants("service").first(where: { $0.child("serviceType")?.text.contains("ContentDirectory") == true }),
              let type = service.child("serviceType")?.text, let path = service.child("controlURL")?.text else { throw SourceWorker.failure("此地址不是可浏览的 DLNA 媒体服务器描述地址。") }
        let base = description.descendants("URLBase").first.flatMap { URL(string: $0.text) } ?? source.url
        guard let control = URL(string: path, relativeTo: base)?.absoluteURL, ["http", "https"].contains(control.scheme ?? "") else { throw SourceWorker.failure("DLNA 控制地址无效。") }
        var pending = [("0", "")]; var visited = Set<String>(); var files: [ScannedFile] = []; var unreadable = 0
        while !pending.isEmpty {
            try Task.checkCancellation()
            let (objectID, parent) = pending.removeLast()
            guard visited.insert(objectID).inserted else { continue }
            guard visited.count <= 20_000 else { throw SourceWorker.failure("DLNA 目录数量超过扫描上限。") }
            var offset = 0
            do {
                while offset < 200_000 {
                    let xml = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:Browse xmlns:u=\"\(type)\"><ObjectID>\(escape(objectID))</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>\(offset)</StartingIndex><RequestedCount>500</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>"
                    let data = try await MediaServerClient.request(control, method: "POST", headers: ["Content-Type": "text/xml; charset=utf-8", "SOAPAction": "\"\(type)#Browse\""], body: Data(xml.utf8))
                    let response = try RemoteXML.parse(data)
                    guard let result = response.descendants("Result").first else { throw SourceWorker.failure("DLNA 未返回目录内容。") }
                    let listing = try RemoteXML.parse(Data(result.text.utf8))
                    let nodes = listing.descendants("container") + listing.descendants("item")
                    if nodes.isEmpty { break }
                    for node in nodes {
                        let name = node.child("title")?.text ?? "未命名"
                        let relative = parent + MediaServerClient.safeName(name)
                        if node.name == "container", let id = node.attributes["id"] { pending.append((id, relative + "/")); continue }
                        let resources = node.children.filter { $0.name == "res" }
                        guard let resource = resources.first(where: { $0.attributes["protocolInfo"]?.contains("video/") == true }) ?? (node.child("class")?.text.contains("videoItem") == true ? resources.first : nil),
                              let url = URL(string: resource.text), ["http", "https"].contains(url.scheme ?? "") else { continue }
                        let suffix = url.pathExtension.isEmpty ? "mkv" : url.pathExtension
                        let id = node.attributes["id"] ?? UUID().uuidString
                        let filePath = relative + "." + MediaServerClient.safeName(id) + "." + suffix
                        files.append(ScannedFile(url: url, relativePath: filePath, displayTitle: name))
                    }
                    let returned = Int(response.descendants("NumberReturned").first?.text ?? "") ?? nodes.count
                    let total = Int(response.descendants("TotalMatches").first?.text ?? "") ?? offset + returned
                    guard returned > 0 else { break }; offset += returned
                    if offset >= total { break }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { if objectID == "0" { throw error }; unreadable += 1 }
        }
        return ScanResult(files: files, unreadable: unreadable)
    }
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
}

private final class RemoteXML: NSObject, XMLParserDelegate {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [RemoteXML] = []
    private var stack: [RemoteXML] = []
    init(name: String = "root", attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
    func child(_ name: String) -> RemoteXML? { children.first { $0.name == name } }
    func descendants(_ name: String) -> [RemoteXML] { children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) } }
    static func parse(_ data: Data) throws -> RemoteXML {
        let root = RemoteXML(); root.stack = [root]
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = root
        guard parser.parse() else { throw SourceWorker.failure("服务器 XML 响应无法解析。") }; root.stack = []; return root
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let child = RemoteXML(name: String(name.split(separator: ":").last ?? ""), attributes: attributes)
        stack.last?.children.append(child); stack.append(child)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { stack.last?.text = stack.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; _ = stack.popLast() }
}
