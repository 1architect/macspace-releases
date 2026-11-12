import Foundation

/// A scan can report from any worker. Keep one pending main-queue callback instead of
/// making a main-actor task for every report, including reports already superseded.
final class ReadProgressDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: UInt64 = 33_000_000
    private let deliver: @MainActor @Sendable (Double) -> Void
    private var first: Double?
    private var latest: Double?
    private var maximum: Double = -1
    private var lastDelivery: UInt64?
    private var scheduled = false
    private var cancelled = false

    init(_ deliver: @escaping @MainActor @Sendable (Double) -> Void) { self.deliver = deliver }

    func report(_ fraction: Double) {
        guard fraction.isFinite else { return }
        let value = min(1, max(0, fraction))
        let enqueue = lock.withLock {
            guard !cancelled, value > maximum else { return false }
            if maximum < 0 { first = value }
            maximum = value; latest = value
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if enqueue { schedule() }
    }

    func cancel() { lock.withLock { cancelled = true; first = nil; latest = nil } }

    private func schedule(after delay: UInt64 = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
            MainActor.assumeIsolated { self?.drain() }
        }
    }

    private enum Next { case none, wait(UInt64), value(Double, more: Bool) }

    @MainActor private func drain() {
        let next: Next = lock.withLock {
            guard !cancelled, let value = first ?? latest else { scheduled = false; return .none }
            let now = DispatchTime.now().uptimeNanoseconds
            if let lastDelivery, now - lastDelivery < interval { return .wait(interval - (now - lastDelivery)) }
            first = nil
            if latest == value { latest = nil }
            lastDelivery = now
            let more = latest != nil
            scheduled = more
            return .value(value, more: more)
        }
        switch next {
        case .none: break
        case let .wait(delay): schedule(after: delay)
        case let .value(value, more):
            deliver(value)
            if more { schedule(after: interval) }
        }
    }
}
