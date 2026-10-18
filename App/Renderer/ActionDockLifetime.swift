import SwiftUI

/// Keep the page's footer reserved until SwiftUI removes the outgoing dock animation.
/// A newer presentation invalidates an older completion, so a quick reload cannot collapse a visible dock.
@MainActor
final class ActionDockLifetime: ObservableObject {
    @Published private(set) var reservesSpace = false
    private var generation = 0

    func update(shown: Bool) -> Int {
        generation += 1
        if shown { reservesSpace = true }
        return generation
    }

    func finishDeparture(_ token: Int) {
        guard token == generation else { return }
        reservesSpace = false
    }

    func cancel() {
        generation += 1
        reservesSpace = false
    }
}
