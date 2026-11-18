import AppKit
import Testing
@testable import Luma

@Test @MainActor func playerMenuKeepsSnapshotAndDispatchesNestedSelection() async throws {
    let coordinator = PlayerAdvancedMenu.Coordinator()
    var chosen = ""
    var interaction: [Bool] = []
    coordinator.interaction = { interaction.append($0) }
    coordinator.entries = [.heading("高级选项"), .submenu("播放速度", [
        .action("1×", selected: true) { chosen = "original-normal" },
        .action("1.25×") { chosen = "original-fast" }
    ])]
    let menu = NSMenu()
    coordinator.menuNeedsUpdate(menu)
    let submenu = try #require(menu.items.last?.submenu)
    #expect(submenu.items[0].state == .on)
    #expect(submenu.items[1].state == .off)
    coordinator.menuWillOpen(menu)
    // A playback redraw updates future content, leaving the tracking menu intact.
    coordinator.entries = [.action("replacement") { chosen = "replacement" }]
    let item = submenu.items[1]
    let action = try #require(item.action)
    #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
    coordinator.menuDidClose(menu)
    try await Task.sleep(for: .milliseconds(10))
    #expect(chosen == "original-fast")
    #expect(interaction == [true, false])
    coordinator.menuNeedsUpdate(menu)
    #expect(menu.items.last?.title == "replacement")
}
