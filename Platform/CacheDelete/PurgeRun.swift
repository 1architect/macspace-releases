import Foundation
import MacSpaceSdk

/// What macOS declined to purge, per CacheDelete service: the estimate it gave when it was asked to delete and removed nothing. A
/// service is not offered again until its estimate grows past that, so a button never promises space macOS has just refused to free.
/// Kept across launches (a rebuild or a restart offered the same refused files again).
public struct PurgeLedger: Sendable {
    /// A defaults suite (tests use their own); nil is the app's own defaults.
    private let suite: String?
    private static let prefix = "purge.declined."
    private var defaults: UserDefaults { suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public init(suite: String? = nil) {
        self.suite = suite
    }

    public func declinedEstimate(_ service: String) -> UInt64? {
        (defaults.object(forKey: Self.prefix + service) as? NSNumber)?.uint64Value
    }

    public func noteDeclined(_ service: String, estimate: UInt64) {
        defaults.set(NSNumber(value: estimate), forKey: Self.prefix + service)
    }

    public func clear(_ service: String) {
        defaults.removeObject(forKey: Self.prefix + service)
    }

    /// macOS declined this service and its estimate has not grown much since: it would decline again.
    public func isDeclined(_ service: String, estimate: UInt64) -> Bool {
        guard let declined = declinedEstimate(service) else { return false }
        return Self.withinDeclined(estimate: estimate, declined: declined)
    }

    /// The estimate is no more than 5 % (at least 20 MB) above what macOS declined.
    public static func withinDeclined(estimate: UInt64, declined: UInt64) -> Bool {
        estimate <= declined + max(declined / 20, 20_000_000)
    }

    /// What can honestly be offered: the estimate, or nothing while macOS declines it.
    public func offerable(_ service: String, estimate: UInt64?) -> UInt64? {
        guard let estimate else { return nil }
        return isDeclined(service, estimate: estimate) ? 0 : estimate
    }
}

/// One purge of one CacheDelete service, done the honest way: macOS is asked again right before (its estimate is the only figure it
/// gives, and it lags), the purge runs in the CLI child process, and what the user got is measured on the volume once it has settled.
/// A purge that freed nothing is remembered in the ledger.
public struct PurgeRun: Sendable {
    public struct Outcome: Sendable, Equatable {
        /// macOS's estimate just before the purge.
        public var estimate: UInt64?
        /// What macOS says it removed.
        public var reported: UInt64
        /// What the Data volume gained, measured.
        public var freed: UInt64
        public var error: String?
        /// Nothing was asked: macOS's fresh estimate was already below the threshold.
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
    public let ledger: PurgeLedger

    public init(service: String, urgency: Int = 1, ledger: PurgeLedger = PurgeLedger()) {
        self.service = service
        self.urgency = urgency
        self.ledger = ledger
    }

    /// macOS's estimate for the service now, asked in the CLI child process. nil when it does not answer.
    public func estimate() -> UInt64? {
        if let cli = ToolLocator.cli() { return CacheDeleteClient.purgeableByServiceInSubprocess(executable: cli, urgency: urgency)?[service] }
        return CacheDeleteClient().purgeableByService(urgency: urgency)?[service]
    }

    /// Asks macOS for a fresh estimate, then purges when it is at least `threshold`.
    public func run(threshold: UInt64) -> Outcome {
        let fresh = estimate()
        if let fresh, fresh < threshold {
            return Outcome(estimate: fresh, reported: 0, freed: 0, error: nil, skipped: true)
        }
        let result: CacheDeletePurgeResult
        if let cli = ToolLocator.cli() { result = CacheDeleteClient.purgeInSubprocess(executable: cli, service: service, urgency: urgency) }
        else { result = CacheDeleteClient().purge(services: [service], urgency: urgency) }
        let outcome = Outcome(estimate: fresh, reported: result.purgedBytes ?? 0, freed: result.freedBytes ?? 0, error: result.error, skipped: false)
        if outcome.removedNothing, let fresh { ledger.noteDeclined(service, estimate: fresh) }
        else if outcome.error == nil { ledger.clear(service) }
        return outcome
    }

    /// What to tell the user. `what` names the files ("unused system assets").
    public static func result(_ outcome: Outcome, what: String) -> ActionResult {
        if let error = outcome.error { return .failed(error, details: details(outcome)) }
        if outcome.skipped {
            return ActionResult(outcome: .succeeded, message: "macOS has nothing to free right now.",
                                details: ["Asked again just before, macOS estimated \(ByteFormat.string(outcome.estimate ?? 0)) of \(what)."])
        }
        if outcome.removedNothing {
            return ActionResult(outcome: .needsAttention, message: "macOS removed nothing.",
                                details: details(outcome) + ["macOS keeps these until it needs the space. MacSpace stops offering them until macOS counts more."])
        }
        return .succeeded("Freed \(ByteFormat.string(outcome.freed)) of \(what), measured on the volume.", details: details(outcome))
    }

    /// The lines that say what happened, for a result note.
    public static func details(_ outcome: Outcome) -> [String] {
        var lines: [String] = []
        if let estimate = outcome.estimate { lines.append("macOS estimated \(ByteFormat.string(estimate)) just before.") }
        lines.append("macOS reported \(ByteFormat.string(outcome.reported)) removed; the volume gained \(ByteFormat.string(outcome.freed)).")
        return lines
    }
}
