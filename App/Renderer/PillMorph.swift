import SwiftUI

/// The row flag and page button resize the same shell. Its label is always laid out at its destination size,
/// anchored at the leading edge; only the shell's footprint interpolates. This leaves glyph motion to ChangingText.
struct PillMorph<Label: View>: View {
    @ViewBuilder var label: Label
    @State private var measured: CGSize?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PillMorphLayout(size: measured) {
            label
                .environment(\.textChangeDelay, 0)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    guard size != measured else { return }
                    if measured == nil || reduceMotion {
                        var instant = Transaction()
                        instant.disablesAnimations = true
                        withTransaction(instant) { measured = size }
                    } else {
                        withAnimation(Theme.layout) { measured = size }
                    }
                }
        }
    }
}

struct PillMorphLayout: Layout {
    var size: CGSize?

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size?.width ?? -1, size?.height ?? -1) }
        set { size = newValue.first < 0 || newValue.second < 0 ? nil : CGSize(width: newValue.first, height: newValue.second) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        size ?? subviews[0].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let natural = subviews[0].sizeThatFits(proposal)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(natural))
    }
}
