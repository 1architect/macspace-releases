import SwiftUI

/// A covered page keeps its row/scroll state, but releases the chart's drawing tree after the existing
/// page transition finishes. Back mounts it at full strength, inside the same page transition.
@MainActor
final class CoveredGraphLifetime: ObservableObject {
    @Published private(set) var draws: Bool
    private var covered: Bool
    private var generation = 0
    init(covered: Bool) { self.covered = covered; draws = !covered }
    func token(for covered: Bool) -> Int { self.covered == covered ? generation : generation + 1 }
    func update(covered: Bool) {
        generation = token(for: covered); self.covered = covered
        if !covered { draws = true }
    }
    func finishCover(_ token: Int) {
        guard covered, token == generation else { return }
        draws = false
    }
}
