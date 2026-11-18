import Foundation

enum FinderLocation {
    static func isAvailable(for media: Media, source: LibrarySource?) -> Bool {
        media.url.isFileURL || (source?.kind.mounted == true && media.url.scheme == "luma-source")
    }

    @concurrent static func resolve(
        _ media: Media,
        source: LibrarySource?,
        mount: @Sendable (URL) async throws -> URL = SourceWorker.mount
    ) async throws -> URL {
        if media.url.isFileURL && isFile(media.url) { return media.url }
        guard let source, let path = media.relativePath ?? media.remotePath, RemoteSources.safePath(path) else {
            throw SourceWorker.failure("找不到影片文件。请确认文件仍在原处，或重新连接来源后扫描。")
        }
        let parts = path.split(separator: "/").map(String.init)
        let root: URL
        if source.url.isFileURL {
            root = source.url
        } else if source.kind.mounted {
            let shares = await MountedShareScanner.scan()
            for share in shares {
                guard let directory = MountedShareScanner.directory(for: source.url, on: share) else { continue }
                let candidate = parts.reduce(directory) { $0.appending(component: $1) }
                guard isFile(candidate) else { continue }
                return candidate
            }
            root = try await mount(source.url)
        } else {
            throw SourceWorker.failure("此来源没有可在 Finder 中显示的文件路径。")
        }
        try Task.checkCancellation()
        let file = parts.reduce(root) { $0.appending(component: $1) }
        guard isFile(file) else {
            throw SourceWorker.failure("在来源中找不到影片文件。文件可能已移动，请重新扫描。")
        }
        return file
    }

    private static func isFile(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }
}
