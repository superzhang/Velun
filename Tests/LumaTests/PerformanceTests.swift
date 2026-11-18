import Foundation
import Testing
@testable import Luma

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMA_PERF"] == "1")) @MainActor
func measuresRealLibraryHotPaths() async throws {
    let source = ProcessInfo.processInfo.environment["LUMA_PERF_FILE"].map { URL(filePath: $0) } ?? URL.applicationSupportDirectory.appending(path: "Luma/library.json")
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "library.json")
    try FileManager.default.copyItem(at: source, to: file)
    func measure(_ work: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now; try work()
        let duration = start.duration(to: .now).components
        return Double(duration.attoseconds) / 1e15 + Double(duration.seconds) * 1000
    }
    var library: Library!
    let load = measure { library = Library(file: file) }
    let grouping = measure { _ = library.groupedItems }
    let groups = library.groupedItems
    var count = 0
    let cache = LibraryQueryCache()
    let query = measure {
        for _ in 0..<10 { count = cache.groups(in: library, destination: .all, search: "a").count }
    }
    let id = try #require(library.items.first?.id)
    let updates = measure {
        for i in 0..<5 {
            library.update(id, position: Double(30+i), duration: 100)
            _ = library.groupedItems
        }
    }
    let backgroundLibrary = Library(file: file, backgroundSaving: true)
    _ = backgroundLibrary.groupedItems
    let backgroundUpdates = measure {
        for i in 0..<5 {
            backgroundLibrary.update(id, position: Double(40+i), duration: 100)
            _ = backgroundLibrary.groupedItems
        }
    }
    let largestGroup = try #require(backgroundLibrary.groupedItems.max { $0.items.count < $1.items.count })
    let episodeID = largestGroup.items[0].id
    let largeGroupUpdates = measure {
        for i in 0..<5 { backgroundLibrary.update(episodeID, position: Double(40+i), duration: 100); _ = backgroundLibrary.groupedItems }
    }
    let flushStart = ContinuousClock.now
    await backgroundLibrary.flush()
    let flushDuration = flushStart.duration(to: .now).components
    let flushMS = Double(flushDuration.attoseconds) / 1e15 + Double(flushDuration.seconds) * 1000
    #expect(Library(file: file).items.first?.position == 44)
    print("LUMA_BACKGROUND update5_main_ms=\(backgroundUpdates) largest_group_update5_main_ms=\(largeGroupUpdates) largest_group_files=\(largestGroup.items.count) flush_ms=\(flushMS)")
    print("LUMA_PERF " + "load_ms=\(load) grouping_ms=\(grouping) query10_ms=\(query) update5_ms=\(updates) videos=\(library.items.count) groups=\(groups.count) hits=\(count)")
}
