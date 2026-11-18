import SwiftUI

/// Technical badges wrap as whole tokens instead of pushing outside the detail column.
struct MetadataFlowLayout: Layout {
    var spacing: CGFloat = 13
    var lineSpacing: CGFloat = 8
    private func arrangement(width: CGFloat, subviews: Subviews) -> (CGSize, [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var positions: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + lineSpacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), positions)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangement(width: proposal.width ?? .infinity, subviews: subviews).0
        return CGSize(width: proposal.width ?? result.width, height: result.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrangement(width: bounds.width, subviews: subviews).1
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + positions[index].x, y: bounds.minY + positions[index].y), proposal: .unspecified)
        }
    }
}
