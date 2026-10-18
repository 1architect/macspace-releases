import Foundation
import MacSpaceSdk

/// One reading of the Mac, shared by every caller that asks while it runs (the tile and the page ask together), kept for a while, and
/// forgotten by `invalidate`: a reading that started before an action is then never handed out, or the page came back with the
/// figures from before the action.
public actor SharedReading<Value: Sendable> {
    public typealias Read = @Sendable (LoadProgressRelay) async -> Value

    private var cached: (value: Value, at: Date)?
    private var inflight: Task<Value, Never>?
    /// The progress of the reading in flight, which every caller waiting on it hears.
    private var relay: LoadProgressRelay?
    private var generation = 0
    private let read: Read

    public init(_ read: @escaping Read) { self.read = read }

    /// The last reading while it is younger than `maxAge`, else a new one (joined when one is already running).
    public func value(maxAge: TimeInterval, now: Date = Date(), progress: LoadProgressSink? = nil) async -> Value {
        if let cached, now.timeIntervalSince(cached.at) < maxAge { return cached.value }
        let started = generation
        if let inflight {
            if let progress { relay?.attach(progress) }
            let fresh = await inflight.value
            return started == generation ? fresh : await value(maxAge: maxAge, progress: progress)
        }
        let read = self.read
        let relay = LoadProgressRelay()
        if let progress { relay.attach(progress) }
        relay.report(0)
        let task = Task.detached(priority: .utility) {
            defer { relay.report(1) }
            return await read(relay)
        }
        inflight = task
        self.relay = relay
        let fresh = await task.value
        guard started == generation else { return await value(maxAge: maxAge, progress: progress) }
        cached = (fresh, Date())
        inflight = nil
        self.relay = nil
        return fresh
    }

    /// The last reading, whatever its age; nil before the first.
    public var current: Value? { cached?.value }

    /// Measures again only what an action changed, on top of the last reading, which keeps its age. A reading running meanwhile is
    /// retired; nil when there is no reading yet, or a newer change came in first.
    public func reconcile(_ change: @escaping @Sendable (Value) async -> Value) async -> Value? {
        guard let cached else { return nil }
        generation += 1
        let started = generation
        inflight = nil
        relay = nil
        let updated = await Task.detached(priority: .utility) { await change(cached.value) }.value
        guard started == generation else { return self.cached?.value }
        self.cached = (updated, cached.at)
        return updated
    }

    public func invalidate() {
        cached = nil
        inflight = nil
        relay = nil
        generation += 1
    }
}
