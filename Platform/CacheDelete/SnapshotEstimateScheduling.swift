import Foundation

/// Coordinate simultaneous read-only snapshot estimates so a targeted request can finish before broad service queries.
/// No completed answer is retained and every caller still executes its own query.
public final class SnapshotEstimateScheduling: @unchecked Sendable {
    public static let shared = SnapshotEstimateScheduling()
    private let lock = NSLock()
    private var targeted = 0
    private var waiting: [DispatchSemaphore] = []
    private var releaseScheduled = false
    private let queue = DispatchQueue(label: "com.macspace.snapshot-estimates", qos: .userInitiated)
    private let coalescingWindow: DispatchTimeInterval
    private let maximumWait: DispatchTimeInterval

    init(coalescingWindow: DispatchTimeInterval = .milliseconds(10), maximumWait: DispatchTimeInterval = .milliseconds(250)) {
        self.coalescingWindow = coalescingWindow
        self.maximumWait = maximumWait
    }

    var pendingBroadReads: Int { lock.withLock { waiting.count } }

    public func targeted<Value>(_ read: () -> Value) -> Value {
        lock.withLock { targeted += 1 }
        defer {
            let readers = lock.withLock { () -> [DispatchSemaphore] in
                targeted -= 1
                guard targeted == 0 else { return [] }
                let readers = waiting
                waiting.removeAll(keepingCapacity: true)
                return readers
            }
            for reader in readers { reader.signal() }
        }
        return read()
    }

    public func broad<Value>(_ read: () -> Value) -> Value {
        let ready = DispatchSemaphore(value: 0)
        lock.withLock {
            waiting.append(ready)
            guard !releaseScheduled else { return }
            releaseScheduled = true
            // Let requests from the other module tasks reach this scheduler before starting all-service work.
            queue.asyncAfter(deadline: .now() + coalescingWindow) { [self] in
                let readers = lock.withLock { () -> [DispatchSemaphore] in
                    releaseScheduled = false
                    guard targeted == 0 else { return [] }
                    let readers = waiting
                    waiting.removeAll(keepingCapacity: true)
                    return readers
                }
                for reader in readers { reader.signal() }
            }
        }
        // A delayed or stuck targeted OS service must not hold every other module indefinitely.
        let admitted = ModuleLoadMetrics.measure("cache-delete", "snapshot-admission") {
            ready.wait(timeout: .now() + maximumWait)
        }
        if admitted == .timedOut {
            lock.withLock { waiting.removeAll { $0 === ready } }
        }
        return read()
    }
}
