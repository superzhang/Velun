import Foundation
import Testing
@testable import Luma

@Test func validatesStreamAddresses() {
    #expect(Media.streamURL(" https://example.com/movie.mp4 ") != nil)
    #expect(Media.streamURL("http://localhost:8080/live.m3u8") != nil)
    for value in ["file:///tmp/a.mp4", "https://", "hello", "ftp://host/a", "https://user:secret@example.com/a"] {
        #expect(Media.streamURL(value) == nil)
    }
}
@Test @MainActor func persistsLibraryAndProgress() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "library.json")
    let library = Library(file: file)
    let url = URL(filePath: "/tmp/Film.mp4")
    library.add([url, url])
    #expect(library.items.count == 1)
    let id = try #require(library.items.first?.id)
    library.update(id, position: 30, duration: 100)
    library.favorite(id)
    let restored = Library(file: file)
    #expect(restored.items.first?.isContinuing == true)
    #expect(restored.items.first?.favorite == true)
    #expect(restored.items.first?.progress == 0.3)
    restored.update(id, position: .nan, duration: 100)
    #expect(restored.items.first?.position == 30)
    restored.reset(id)
    #expect(restored.items.first?.isContinuing == false)
    restored.remove(id)
    #expect(Library(file: file).items.isEmpty)
}
@Test @MainActor func protectsCorruptLibrary() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let original = Data("invalid json".utf8)
    try original.write(to: file)
    let library = Library(file: file)
    #expect(library.error != nil)
    library.add([URL(filePath: "/tmp/a.mp4")])
    #expect(try Data(contentsOf: file) == original)
}
