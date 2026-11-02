import SwiftUI

/// Legend entries wrap as whole units. Each entry gets its natural width, or the full
/// available row when its label alone is too long; its figure is never squeezed.
struct LegendFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 20
    var verticalSpacing: CGFloat = 5

    struct Placement {
        let frames: [CGRect]
        let size: CGSize
    }

    static func placement(sizes: [CGSize], width: CGFloat, horizontalSpacing: CGFloat = 20,
                          verticalSpacing: CGFloat = 5) -> Placement {
        let width = width.isFinite ? max(0, width) : sizes.reduce(0) { $0 + max(0, $1.width) } + CGFloat(max(0, sizes.count - 1)) * horizontalSpacing
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for size in sizes {
            let item = CGSize(width: min(width, max(0, size.width)), height: max(0, size.height))
            if x > 0 && x + item.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: item))
            x += item.width + horizontalSpacing
            rowHeight = max(rowHeight, item.height)
        }
        return Placement(frames: frames, size: CGSize(width: width, height: frames.isEmpty ? 0 : y + rowHeight))
    }

    private func arrangement(_ proposal: ProposedViewSize, subviews: Subviews) -> Placement {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return Self.placement(sizes: sizes, width: proposal.width ?? .infinity,
                              horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (view, frame) in zip(subviews, layout.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
