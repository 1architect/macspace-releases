import SwiftUI

/// A short read must still let the outgoing cascade finish before the incoming one starts.
@MainActor
final class PageDetailsVisibility: ObservableObject {
    @Published private(set) var visible = true
    private var hiddenAt: ContinuousClock.Instant?
    private var reveal: Task<Void, Never>?
    private let departure: Duration

    init(departure: Duration = .milliseconds(820)) { self.departure = departure }

    func update(busy: Bool, initial: Bool = false) {
        reveal?.cancel()
        reveal = nil
        if initial { visible = !busy; hiddenAt = nil; return }
        if busy {
            if visible { hiddenAt = .now }
            visible = false
        } else if !visible {
            let remaining = hiddenAt.map { max(.zero, departure - $0.duration(to: .now)) } ?? .zero
            reveal = Task { [weak self] in
                do { try await Task.sleep(for: remaining) } catch { return }
                self?.visible = true
                self?.hiddenAt = nil
            }
        }
    }

    func cancel() { reveal?.cancel(); reveal = nil }
}
