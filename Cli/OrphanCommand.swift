import Foundation
import MacSpaceSiriPrivileged

/// `MacSpaceCli orphan-subscriptions [--execute] [--json]`
///
/// Removes the Apple asset subscriptions of accounts that no longer exist, which keep Apple Intelligence models installed
/// for everyone. Executing needs root (`sudo`): the database is backed up first and the removal runs in one transaction.
enum OrphanCommand {
    static func run(_ arguments: [String]) -> Never {
        let json = arguments.contains("--json")
        let cleaner = OrphanSubscriptionCleaner()
        let result: OrphanSubscriptionResult
        if arguments.contains("--execute") {
            result = cleaner.execute()
        } else {
            guard let plan = cleaner.plan() else {
                FileHandle.standardError.write(Data("The subscription database could not be read.\n".utf8))
                exit(1)
            }
            result = OrphanSubscriptionResult(plan: plan, executed: false, backupPath: nil, remainingRows: nil, integrity: nil, error: plan.refusal, restartRequired: false)
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result) { FileHandle.standardOutput.write(data); print() }
            exit(result.error == nil ? 0 : 1)
        }
        if result.plan.isEmpty && result.error == nil { print("No subscriptions from deleted accounts."); exit(0) }
        for account in result.plan.accounts {
            print("Deleted account \(account.guid): \(account.subscriptions) subscription(s), \(account.appleIntelligenceUseCases) for Apple Intelligence")
        }
        if let error = result.error { print("error: \(error)"); exit(1) }
        if result.executed {
            print("Removed \(result.plan.rowCount) row(s); backup: \(result.backupPath ?? "?"); integrity: \(result.integrity ?? "?").")
            print("Restart the Mac, then use \"Release and delete leftover models\" in MacSpace.")
        } else {
            print("Dry run. Run again with sudo and --execute to remove these rows (the database is backed up first).")
        }
        exit(0)
    }
}
