import SwiftUI

/// Keep the page's footer reserved until SwiftUI removes the outgoing dock animation.
/// A newer presentation invalidates an older completion, so a quick reload cannot collapse a visible dock.
@MainActor
final class ActionDockLifetime: ObservableObject {
    @Published private(set) var reservesSpace = false
    private var generation = 0
    private var shown: Bool?

    /// The render transaction can precede onChange. Both must use the same departure generation.
    func token(for shown: Bool) -> Int { self.shown == shown ? generation : generation + 1 }

    func update(shown: Bool) -> Int {
        generation = token(for: shown)
        self.shown = shown
        if shown { reservesSpace = true }
        return generation
    }

    func finishDeparture(_ token: Int) {
        guard token == generation else { return }
        reservesSpace = false
    }

    func cancel() {
        generation += 1
        shown = nil
        reservesSpace = false
    }
}
