import Foundation

// NSRegularExpression is immutable and thread-safe. Compile filename patterns
// once rather than rebuilding the same expressions for every video in a NAS.
struct FilenamePattern: Sendable {
    let expression: NSRegularExpression
    init(_ pattern: String) { expression = try! NSRegularExpression(pattern: pattern) }
    func range(in text: String) -> Range<String.Index>? {
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return Range(match.range, in: text)
    }
    func replacing(in text: String, with replacement: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}
