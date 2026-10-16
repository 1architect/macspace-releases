import SwiftUI

/// Owns the completion page's task so navigation cannot leave an old completion over a new page.
@MainActor
final class AllDoneLifetime: ObservableObject {
    @Published private(set) var shown = false
    var reloading = false
    private var task: Task<Void, Never>?
    private var generation = 0

    func present(hold: Duration, finished: @escaping @MainActor () -> Void) {
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
            finished()
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard self.generation == current else { return }
            self.shown = false
        }
    }

    func dismiss() {
        generation += 1
        task?.cancel()
        task = nil
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { shown = false }
    }
}
