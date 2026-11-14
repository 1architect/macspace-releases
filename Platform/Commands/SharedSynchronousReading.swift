import Foundation
import MacSpaceSdk

/// A synchronous disk scan shared by callers on worker threads. No lock is held during I/O or progress delivery.
/// Invalidating or reconciling retires the current scan, including the results its waiters would otherwise receive.
final class SharedSynchronousReading<Value: Sendable>: @unchecked Sendable {
    private final class Flight {
        let done = DispatchGroup()
        let progress = LoadProgressRelay()
        let generation: Int
        var result: Value?
        init(generation: Int) { self.generation = generation; done.enter() }
    }

    private let lock = NSLock()
    private var cached: (value: Value, at: Date)?
    private var flight: Flight?
    private var generation = 0
    private let read: @Sendable (@escaping LoadProgressSink) -> Value

    init(_ read: @escaping @Sendable (@escaping LoadProgressSink) -> Value) { self.read = read }

    func value(maxAge: TimeInterval, now: Date = Date(), progress: @escaping LoadProgressSink) -> Value {
        while true {
            lock.lock()
            if let cached, now.timeIntervalSince(cached.at) < maxAge {
                lock.unlock()
                progress(1)
                return cached.value
            }
            let ownsScan = flight == nil
            let pending = flight ?? Flight(generation: generation)
            flight = pending
            lock.unlock()
            pending.progress.attach(progress)
            if ownsScan {
                let reports = pending.progress
                reports.report(0)
                let result = read { reports.report($0) }
                reports.report(1)
                lock.lock()
                pending.result = result
                if generation == pending.generation {
                    cached = (result, now)
                    flight = nil
                }
                lock.unlock()
                pending.done.leave()
            } else {
                pending.done.wait()
            }
            lock.lock()
            let current = generation == pending.generation
            let result = pending.result!
            lock.unlock()
            if current { return result }
        }
    }

    func invalidate() {
        lock.lock()
        generation += 1
        cached = nil
        flight = nil
        lock.unlock()
    }

    /// Updates only existing cached data and keeps its age. The change is a pure in-memory transformation.
    func reconcile(_ change: (Value?) -> Value?) {
        lock.lock()
        generation += 1
        flight = nil
        let updated = change(cached?.value)
        if let updated, let at = cached?.at { cached = (updated, at) }
        else { cached = nil }
        lock.unlock()
    }

    var current: Value? { lock.withLock { cached?.value } }
}
