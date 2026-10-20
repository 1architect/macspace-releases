import Darwin
import Foundation

/// Gives back to macOS the memory MacSpace has freed, once no window of it is on screen. The scans build large readings and drop them,
/// and the allocator keeps their pages for later: after a session through every module, about 40 of the 100 MB it held were free
/// (Issue 11). `malloc_zone_pressure_relief` returns those pages, but it walks the heap holding the allocator's locks, and run after
/// every scan it made a module page lag as it opened. So it runs once, a while after the last window has closed (its closing animation
/// done and nothing in use), and only once the modules have finished what they were reading or running. A window that comes back
/// first calls it off.
@MainActor
final class MemoryRelief {
    /// How long after the last window closed: past its closing animation, and long enough that a window opened again at once never
    /// meets the walk.
    static let delay: Duration = .seconds(10)
    /// How often it looks again while a module is still reading or running an action.
    static let busyRetry: Duration = .seconds(5)

    private let delay: Duration
    private let busyRetry: Duration
    private let relieve: @Sendable () -> Void
    private var pending: Task<Void, Never>?
    private var generation = 0

    init(delay: Duration = MemoryRelief.delay, busyRetry: Duration = MemoryRelief.busyRetry,
         relieve: @escaping @Sendable () -> Void = { _ = malloc_zone_pressure_relief(nil, 0) }) {
        self.delay = delay
        self.busyRetry = busyRetry
        self.relieve = relieve
    }

    /// The last window has gone. `isBusy`: a module is reading the Mac or running an action, whose memory is still in use.
    func schedule(isBusy: @escaping @MainActor () -> Bool) {
        guard pending == nil else { return }
        generation += 1
        let generation = generation
        let delay = delay, busyRetry = busyRetry, relieve = relieve
        pending = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                while isBusy() { try await Task.sleep(for: busyRetry) }
            } catch { return }
            // Off the main thread: the walk takes a moment, and the menu bar item must still answer.
            await Task.detached(priority: .utility) { relieve() }.value
            guard let self, self.generation == generation else { return }
            self.pending = nil
        }
    }

    /// A window is on screen again.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    var isPending: Bool { pending != nil }
}
