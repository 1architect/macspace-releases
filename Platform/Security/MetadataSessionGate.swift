import Foundation

/// Lock notifications refuse work immediately. The bounded fallback probe covers missed
/// notifications without sending a WindowServer request for every database statement.
final class MetadataSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let probe: @Sendable () -> Bool
    private let clock: @Sendable () -> UInt64
    private let interval: UInt64
    private var paused = false
    private var lastProbe: UInt64?
    private var cached = false

    init(interval: UInt64 = 100_000_000,
         clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         probe: @escaping @Sendable () -> Bool) {
        self.interval = interval; self.clock = clock; self.probe = probe
    }
    func setLocked(_ value: Bool) {
        lock.withLock { paused = value; lastProbe = nil; cached = false }
    }
    func available(fresh: Bool = false) -> Bool {
        lock.withLock {
            guard !paused else { return false }
            let now = clock()
            if !fresh, let lastProbe, now >= lastProbe, now - lastProbe < interval { return cached }
            cached = probe(); lastProbe = now
            return cached
        }
    }
}
