import SwiftUI

/// Session-only values, not a retained SwiftUI/AppKit drawing tree.
@MainActor
final class ModulePageViewState {
    var scrollY: CGFloat = 0
    var flippedSections: Set<String> = []
}

struct ModulePageScrollState: ViewModifier {
    let state: ModulePageViewState?
    @State private var position = ScrollPosition()
    @State private var appeared = false
    @State private var restoring = false

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onAppear {
                guard let state else { return }
                restoring = state.scrollY > 0
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { position.scrollTo(y: state.scrollY) }
                appeared = true
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                guard appeared, y.isFinite else { return }
                // The first layout may still be at zero before SwiftUI applies scrollTo.
                if restoring, y == 0, !position.isPositionedByUser { return }
                restoring = false
                state?.scrollY = max(0, y)
            }
            .onDisappear { appeared = false }
    }
}
