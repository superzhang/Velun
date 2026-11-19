import SwiftUI
import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" } }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}

enum LumaTheme {
    static let canvas = adaptive(light: 0.975, dark: 0.115)
    static let sidebar = adaptive(light: 0.935, dark: 0.14)
    static let surface = adaptive(light: 1, dark: 0.18)
    static let ink = Color.primary
    static let navigationAccent = Color.orange
    static let warningText = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 1, green: 0.67, blue: 0.38, alpha: 1)
        }
        return NSColor(srgbRed: 0.64, green: 0.29, blue: 0.04, alpha: 1)
    })
    private static func adaptive(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        })
    }
}
