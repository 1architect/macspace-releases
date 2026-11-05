import SwiftUI

/// Conditional and newly mounted lists use the same per-row reveal and shade timing
/// as module loading. Opening never waits for an earlier departure or page-wide index.
@MainActor
final class ListVisibility: ObservableObject {
    @Published private(set) var visible = false
    @Published private(set) var expanded = false
    private var configured = false
    private var requested = false
    private var pending: Task<Void, Never>?

    func update(shown: Bool, rowCount: Int, reduceMotion: Bool = false) {
        let initial = !configured
        if configured, requested == shown, shown, visible { return }
        configured = true; requested = shown
        pending?.cancel(); pending = nil
        if shown {
            withAnimation(initial || reduceMotion ? nil : Theme.layout) { expanded = true }
            if initial && !reduceMotion {
                // Publish one hidden layout before revealing, including on prepared navigation pages.
                pending = Task { [weak self] in
                    await Task.yield()
                    guard !Task.isCancelled, let self, self.requested else { return }
                    self.visible = true
                }
            } else { visible = true }
        } else {
            let wasVisible = visible
            visible = false
            guard !initial, !reduceMotion, expanded, wasVisible else { expanded = false; return }
            pending = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(PageCascade.listSpan(rowCount: rowCount))) } catch { return }
                guard let self, !self.requested else { return }
                withAnimation(Theme.layout) { self.expanded = false }
            }
        }
    }

    func cancel() {
        pending?.cancel(); pending = nil
        // A lazy list may leave the viewport mid-animation; retain its settled state.
        visible = requested; expanded = requested
    }
}

/// Measures children at their full size while only their occupied height collapses.
struct ListHeightLayout: Layout {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.init(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: size.width, height: size.height * min(1, max(0, fraction)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: bounds.width, height: nil))
    }
}
