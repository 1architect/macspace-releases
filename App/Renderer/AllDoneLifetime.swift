import SwiftUI

/// Owns the completion page's task so navigation cannot leave an old completion over a new page.
@MainActor
final class AllDoneLifetime: ObservableObject {
    @Published private(set) var shown = false
    /// The countdown back to the page under it has started: shown as a ring that empties, so the return is never a surprise.
    @Published private(set) var countingDown = false
    var reloading = false
    private var task: Task<Void, Never>?
    private var generation = 0

    /// `hold` lets the words and the count arrive; the module then finishes reading the Mac, and only then does `countdown` run.
    /// A slow reload no longer ends with an instant return the moment it is done.
    func present(hold: Duration, countdown: Duration = .zero, finished: @escaping @MainActor () -> Void) {
        dismiss()
        generation += 1
        let current = generation
        shown = true
        task = Task { [weak self] in
            do { try await Task.sleep(for: hold) } catch { return }
            while let self, self.reloading {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard let self, !Task.isCancelled, self.generation == current else { return }
            self.countingDown = countdown > .zero
            do { try await Task.sleep(for: countdown) } catch { return }
            guard self.generation == current else { return }
            finished()
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard self.generation == current else { return }
            self.shown = false
        }
    }

    func dismiss(animated: Bool = false) {
        generation += 1
        task?.cancel()
        task = nil
        countingDown = false
        if animated { withAnimation(Theme.push) { shown = false }; return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { shown = false }
    }
}
