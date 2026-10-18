import Foundation
import MacSpacePlatform

/// The Siri module's root-level operations, compiled into the helper.
public struct SiriPrivilegedOperations: PrivilegedOperationHandler {
    public static let planOrphans = "siri.orphan-subscriptions.plan"
    public static let removeOrphans = "siri.orphan-subscriptions.execute"
    public static let phoneFeatureStatus = "siri.phone-features.status"
    public static let setPhoneFeatures = "siri.phone-features.set"

    public init() {}

    public var operations: Set<String> { [Self.planOrphans, Self.removeOrphans, Self.phoneFeatureStatus, Self.setPhoneFeatures] }
    public var readOnlyOperations: Set<String> { [Self.planOrphans, Self.phoneFeatureStatus] }

    public func handle(_ operation: String, arguments: [String: String], caller: PrivilegedCaller) throws -> Data {
        if operation == Self.phoneFeatureStatus {
            guard arguments.isEmpty else { throw PrivilegedOperationError("Phone feature status takes no arguments.") }
            return try JSONEncoder().encode(PhoneFeatureFlags().status())
        }
        if operation == Self.setPhoneFeatures {
            guard arguments.count == 1, let value = arguments["off"], ["true", "false"].contains(value) else {
                throw PrivilegedOperationError("Phone features take only off=true or off=false.")
            }
            return try JSONEncoder().encode(PhoneFeatureFlags().setOff(value == "true"))
        }
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
