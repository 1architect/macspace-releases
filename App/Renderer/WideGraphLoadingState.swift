import SwiftUI

/// Reuses the chart's loading-finish spring, then releases the existing row reveal cascade.
/// Interrupted loads invalidate the old completion instead of exposing an obsolete list.
@MainActor
final class WideGraphLoadingState: ObservableObject {
    enum Phase { case expanded, resizing, ready }
    @Published private(set) var phase: Phase = .ready
    private(set) var configured = false
    private var generation = 0

    func update(expand: Bool, active: Bool, reduceMotion: Bool) {
        generation += 1
        let token = generation
        let initial = !configured
        configured = true
        if !active || initial || reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { phase = active && expand ? .expanded : .ready }
        } else if expand {
            withAnimation(ChartMotion.finishAnimation) { phase = .expanded }
        } else if phase == .expanded || phase == .resizing {
            // Reveal at the spring's logical arrival, without waiting for its residual bounce to settle.
            withAnimation(ChartMotion.finishAnimation, completionCriteria: .logicallyComplete) {
                phase = .resizing
            } completion: { [weak self] in
                guard let self, self.generation == token else { return }
                self.phase = .ready
            }
        }
    }

    func cancel() {
        generation += 1
        configured = false
        phase = .ready
    }
}
