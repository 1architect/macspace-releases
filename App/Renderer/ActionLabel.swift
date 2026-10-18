import SwiftUI

/// Idle flags fit their title. While working, known phase labels determine a stable width instead of the changing text.
struct ReservedPillLabel<Label: View>: View {
    let samples: [String]
    let reserveWidth: Bool
    @ViewBuilder var label: Label

    var body: some View {
        ReservedPillLayout(reserveWidth: reserveWidth) {
            label
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                Text(verbatim: sample).hidden().accessibilityHidden(true)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 18)
    }
}

struct ReservedPillLayout: Layout {
    let reserveWidth: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard reserveWidth else { return subviews[0].sizeThatFits(.unspecified) }
        let samples = subviews.dropFirst().map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: samples.map(\.width).max() ?? 0, height: samples.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews { view.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size)) }
    }
}

/// Measuring the ideal label independently of PillMorph's intermediate width prevents a shrink/grow feedback loop.
/// The page's available width caps long notices; they truncate with the full text in the button's help.
struct SingleLineActionLabel: View {
    let text: String
    var maximumWidth: CGFloat?

    var body: some View {
        SingleLineActionLayout(maximumWidth: maximumWidth) {
            ChangingText(text: text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 15)
                .frame(height: 31)
        }
    }
}

struct SingleLineActionLayout: Layout {
    var maximumWidth: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = subviews[0].sizeThatFits(.unspecified)
        return CGSize(width: min(natural.width, maximumWidth ?? natural.width), height: 31)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
