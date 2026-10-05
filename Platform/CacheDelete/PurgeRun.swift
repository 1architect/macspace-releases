import Foundation
import MacSpaceSdk

/// When macOS keeps files it was asked to purge, MacSpace asks it again by itself, a few times over the next hour, instead of leaving
/// the user to press the button again. While it does, the files still count as purgeable, and the page says they are being freed.
/// Only the app keeps asking: the CLI exits as soon as it is done.
public final class PurgeRetrier: @unchecked Sendable {
    public static let shared = PurgeRetrier()
    /// How long after the refusal each new request is made.
    public static let delays: [TimeInterval] = [60, 5 * 60, 15 * 60, 60 * 60]

    private let lock = NSLock()
    private var pending: [String: Task<Void, Never>] = [:]

    public init() {}

    /// MacSpace is still asking macOS to purge this service.
    public func isRetrying(_ service: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pending[service] != nil
    }

    /// Asks again after each delay until macOS frees something; `freed` is told what the volume gained (the module drops its cache
    /// so the figures move). A new schedule for the same service replaces the old one.
    public func schedule(service: String, urgency: Int, delays: [TimeInterval] = PurgeRetrier.delays,
                         purge: (@Sendable () -> CacheDeletePurgeResult)? = nil, freed: @escaping @Sendable (UInt64) async -> Void) {
        let attempt = purge ?? { PurgeRun.purgeOnce(service: service, urgency: urgency) }
        let task = Task.detached(priority: .utility) { [weak self] in
            for delay in delays {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                let result = attempt()
                let gained = result.freedBytes ?? 0
                if result.error == nil, (result.purgedBytes ?? 0) > 0 || gained >= PurgeRun.noise {
                    self?.finish(service)
                    await freed(gained)
                    return
                }
            }
            self?.finish(service)
            await freed(0)
        }
        lock.lock()
        pending[service]?.cancel()
        pending[service] = task
        lock.unlock()
    }

    public func cancel(_ service: String) {
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: service)?.cancel()
    }

    private func finish(_ service: String) {
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: service)
    }
}

/// What macOS keeps counting as purgeable but will not delete: after a purge and all of `PurgeRetrier`'s requests freed nothing,
/// the estimate it still gave is held back from what MacSpace offers (mobileassetd kept estimating 129.1 MB and removing 0 bytes,
/// 2026-10-05). Only the part of a later estimate above that amount counts; the hold goes once macOS frees something, once its
/// estimate drops below the amount, or after a day, when MacSpace may ask again.
public final class PurgeHoldouts: @unchecked Sendable {
    public struct Hold: Codable, Equatable, Sendable {
        public var bytes: UInt64
        public var since: Date
    }

    public static let shared = PurgeHoldouts()
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSpace/purge-holdouts.json")
    public static let lifetime: TimeInterval = 24 * 60 * 60

    private let url: URL?
    private let lock = NSLock()
    private var holds: [String: Hold]

    public init(url: URL? = PurgeHoldouts.defaultURL) {
        self.url = url
        holds = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Hold].self, from: $0) } ?? [:]
    }

    /// Two estimates this close are the same files measured again.
    static func tolerance(_ bytes: UInt64) -> UInt64 { max(bytes / 50, 5_000_000) }

    public func hold(_ service: String, bytes: UInt64, now: Date = Date()) {
        guard bytes > 0 else { return clear(service) }
        update { $0[service] = Hold(bytes: bytes, since: now) }
    }

    public func clear(_ service: String) {
        update { $0.removeValue(forKey: service) }
    }

    /// What of macOS's `estimate` MacSpace counts as freeable.
    public func freeable(_ service: String, estimate: UInt64, now: Date = Date()) -> UInt64 {
        lock.lock()
        let hold = holds[service]
        lock.unlock()
        guard let hold else { return estimate }
        let tolerance = Self.tolerance(hold.bytes)
        if now.timeIntervalSince(hold.since) >= Self.lifetime || estimate + tolerance < hold.bytes {
            clear(service)
            return estimate
        }
        return estimate > hold.bytes + tolerance ? estimate - hold.bytes : 0
    }

    private func update(_ change: (inout [String: Hold]) -> Void) {
        lock.lock()
        change(&holds)
        let snapshot = holds
        lock.unlock()
        guard let url, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// One purge of one CacheDelete service, done the honest way: macOS is asked again right before (its estimate is the only figure it
/// gives, and it lags), the purge runs in the CLI child process, and what the user got is measured on the volume once it has settled.
/// When macOS keeps everything, `PurgeRetrier` asks it again in the background.
public struct PurgeRun: Sendable {
    public struct Outcome: Sendable, Equatable {
        /// macOS's estimate just before the purge.
        public var estimate: UInt64?
        /// What macOS says it removed.
        public var reported: UInt64
        /// What the Data volume gained, measured.
        public var freed: UInt64
        public var error: String?
        /// Nothing was asked (kept for callers that decide not to purge).
        public var skipped: Bool

        public init(estimate: UInt64?, reported: UInt64, freed: UInt64, error: String?, skipped: Bool) {
            self.estimate = estimate
            self.reported = reported
            self.freed = freed
            self.error = error
            self.skipped = skipped
        }

        /// macOS removed nothing at all.
        public var removedNothing: Bool { error == nil && !skipped && reported == 0 && freed < PurgeRun.noise }
    }

    /// Below this a change in free space is the system writing or deleting its own files, not the purge.
    public static let noise: UInt64 = 1_000_000

    public let service: String
    public let urgency: Int
    public let retrier: PurgeRetrier
    public let holdouts: PurgeHoldouts

    public init(service: String, urgency: Int = 1, retrier: PurgeRetrier = .shared, holdouts: PurgeHoldouts = .shared) {
        self.service = service
        self.urgency = urgency
        self.retrier = retrier
        self.holdouts = holdouts
    }

    /// One purge request, in the CLI child process when there is one.
    public static func purgeOnce(service: String, urgency: Int) -> CacheDeletePurgeResult {
        if let cli = ToolLocator.cli() { return CacheDeleteClient.purgeInSubprocess(executable: cli, service: service, urgency: urgency) }
        return CacheDeleteClient().purge(services: [service], urgency: urgency)
    }

    /// macOS's estimate for the service now, asked in the CLI child process. nil when it does not answer.
    public func estimate() -> UInt64? {
        if let cli = ToolLocator.cli() { return CacheDeleteClient.purgeableByServiceInSubprocess(executable: cli, urgency: urgency)?[service] }
        return CacheDeleteClient().purgeableByService(urgency: urgency)?[service]
    }

    /// Purges, reporting macOS's estimate from just before. The estimate never decides whether to purge: it lags behind what macOS
    /// can delete (it read 0 with 11 GB of released Apple Intelligence models unlocked, and the purge then removed 11.08 GB,
    /// 2026-10-04). If macOS keeps everything, it is asked again in the background; `freedLater` is told when that frees something.
    public func run(freedLater: @escaping @Sendable (UInt64) async -> Void = { _ in }) -> Outcome {
        let fresh = estimate()
        retrier.cancel(service)
        let result = Self.purgeOnce(service: service, urgency: urgency)
        let outcome = Outcome(estimate: fresh, reported: result.purgedBytes ?? 0, freed: result.freedBytes ?? 0, error: result.error, skipped: false)
        if outcome.removedNothing {
            let run = self
            retrier.schedule(service: service, urgency: urgency) { freed in
                // Every request freed nothing: what macOS still estimates is what it keeps, and is no longer offered.
                if freed == 0 { run.holdouts.hold(run.service, bytes: run.estimate() ?? 0) } else { run.holdouts.clear(run.service) }
                await freedLater(freed)
            }
        } else if outcome.error == nil {
            holdouts.clear(service)
        }
        return outcome
    }

    /// What to tell the user. `what` names the files ("unused system assets").
    public static func result(_ outcome: Outcome, what: String) -> ActionResult {
        if let error = outcome.error { return .failed(failedMessage, details: [error] + details(outcome)) }
        if outcome.skipped {
            return ActionResult(outcome: .succeeded, message: PurgeRun.nothingMessage,
                                details: ["Asked again just before, macOS estimated \(ByteFormat.string(outcome.estimate ?? 0)) of \(what)."])
        }
        if outcome.removedNothing {
            return ActionResult(outcome: .succeeded, message: PurgeRun.laterMessage,
                                details: details(outcome) + [PurgeRun.retryNote])
        }
        return .succeeded(freedMessage(outcome.freed), details: details(outcome), freedBytes: outcome.freed)
    }

    /// The words a cleanup shows the user, in its button, as few as possible: what it freed, measured on the volume.
    public static func freedMessage(_ freed: UInt64) -> String { freed > 0 ? "Freed \(ByteFormat.string(freed))" : nothingMessage }
    public static let nothingMessage = "Nothing to free"
    /// A purge that failed; why is in the details, not in front of the user.
    public static let failedMessage = "Couldn't free space. Try again later."
    /// macOS kept the files; MacSpace asks it again in the background (`PurgeRetrier`).
    public static let laterMessage = "Finishing in the background"

    static let retryNote = "MacSpace asks macOS again over the next hour; the figures update as soon as it lets them go."

    /// The lines that say what happened, for a result note.
    public static func details(_ outcome: Outcome) -> [String] {
        var lines: [String] = []
        if let estimate = outcome.estimate { lines.append("macOS estimated \(ByteFormat.string(estimate)) just before.") }
        lines.append("macOS reported \(ByteFormat.string(outcome.reported)) removed; the volume gained \(ByteFormat.string(outcome.freed)).")
        return lines
    }
}
