import SwiftUI

/// Packs tags in source order, wrapping only when the next tag no longer fits.
struct DictionaryTagLayout: Layout {
    var spacing: CGFloat = 8
    var maximumTagWidth: CGFloat = 180

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangement(proposal: proposal, subviews: subviews)
        return CGSize(width: result.width, height: result.frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(proposal: ProposedViewSize, subviews: Subviews) -> (width: CGFloat, frames: [CGRect]) {
        let idealWidth = subviews.reduce(CGFloat.zero) { $0 + min($1.sizeThatFits(.unspecified).width, maximumTagWidth) }
            + CGFloat(max(0, subviews.count - 1)) * spacing
        let proposedWidth = proposal.width ?? idealWidth
        let width = max(0, proposedWidth.isFinite ? proposedWidth : idealWidth)
        let tagWidth = min(width, maximumTagWidth)
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: tagWidth, height: nil)) }
        return (width, Self.frames(for: sizes, width: width, spacing: spacing))
    }

    static func frames(for sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [CGRect] {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        return sizes.map { size in
            let itemWidth = min(size.width, width)
            if x > 0, x + itemWidth > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            let frame = CGRect(x: x, y: y, width: itemWidth, height: size.height)
            x += itemWidth + spacing
            rowHeight = max(rowHeight, size.height)
            return frame
        }
    }
}
