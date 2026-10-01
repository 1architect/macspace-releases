import Foundation
import MacSpacePlatform

/// The Siri module's root-level operations, compiled into the helper.
public struct SiriPrivilegedOperations: PrivilegedOperationHandler {
    public static let planOrphans = "siri.orphan-subscriptions.plan"
    public static let removeOrphans = "siri.orphan-subscriptions.execute"

    public init() {}

    public var operations: Set<String> { [Self.planOrphans, Self.removeOrphans] }

    public func handle(_ operation: String, arguments: [String: String], caller: PrivilegedCaller) throws -> Data {
        // The current user is the caller, not root: the cleaner must never remove that account's own rows.
        let cleaner = OrphanSubscriptionCleaner(currentUserGUID: UAFSubscriptionDatabase.userGUID(uid: caller.uid))
        let result: OrphanSubscriptionResult
        switch operation {
        case Self.removeOrphans:
            result = cleaner.execute()
        case Self.planOrphans:
            guard let plan = cleaner.plan() else { throw PrivilegedOperationError("The subscription database could not be read.") }
            result = OrphanSubscriptionResult(plan: plan, executed: false, backupPath: nil, remainingRows: nil, integrity: nil, error: plan.refusal, restartRequired: false)
        default:
            throw PrivilegedOperationError("Unknown operation \(operation).")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(result)
    }
}
