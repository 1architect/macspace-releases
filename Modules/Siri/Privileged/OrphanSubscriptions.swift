import Foundation

/// Removes UAF subscription rows that belong to accounts that no longer exist.
///
/// assetsubscriptiond keeps a deleted account's subscriptions indefinitely, and they keep the assets they name, for
/// example the Apple Intelligence models, installed and locked for every other account. A restart does not clear them
/// (measured on 26B5091g). This edits Apple's database as root, so it backs it up first. It touches only rows whose
/// user GUID matches no local account, and refuses when the account list looks wrong.
/// Measured: `results/ai-orphan-subscriptions-2026-09-30/`.
public struct OrphanSubscriptionAccount: Codable, Equatable, Sendable {
    public let guid: String
    public let subscriptions: Int
    public let appleIntelligenceUseCases: Int
}

public struct OrphanSubscriptionPlan: Codable, Equatable, Sendable {
    public let databasePath: String
    public let accounts: [OrphanSubscriptionAccount]
    /// Why nothing may be removed (the account list could not be trusted), if so.
    public let refusal: String?

    public var rowCount: Int { accounts.map(\.subscriptions).reduce(0, +) }
    public var isEmpty: Bool { accounts.isEmpty }
}

public struct OrphanSubscriptionResult: Codable, Equatable, Sendable {
    public let plan: OrphanSubscriptionPlan
    public let executed: Bool
    public let backupPath: String?
    public let remainingRows: Int?
    public let integrity: String?
    public let error: String?
    /// The removal takes effect for ModelCatalog after a restart (measured).
    public let restartRequired: Bool

    public init(plan: OrphanSubscriptionPlan, executed: Bool, backupPath: String?, remainingRows: Int?, integrity: String?,
                error: String?, restartRequired: Bool) {
        self.plan = plan
        self.executed = executed
        self.backupPath = backupPath
        self.remainingRows = remainingRows
        self.integrity = integrity
        self.error = error
        self.restartRequired = restartRequired
    }
}

public struct OrphanSubscriptionCleaner {
    public static let backupDirectory = URL(fileURLWithPath: "/Library/Application Support/MACSPACE/backups")

    let databasePath: String
    let existingGUIDs: () -> Set<String>
    let currentUserGUID: String?
    let backupDirectory: URL
    let fileManager: FileManager
    let isRoot: () -> Bool

    public init(databasePath: String = UAFSubscriptionDatabase.path,
                existingGUIDs: @escaping () -> Set<String> = { Set(AppleIntelligenceAccountsReport.accountNames().keys) },
                currentUserGUID: String? = UAFSubscriptionDatabase.userGUID(uid: getuid()),
                backupDirectory: URL = OrphanSubscriptionCleaner.backupDirectory, fileManager: FileManager = .default,
                isRoot: @escaping () -> Bool = { geteuid() == 0 }) {
        self.databasePath = databasePath
        self.existingGUIDs = existingGUIDs
        self.currentUserGUID = currentUserGUID
        self.backupDirectory = backupDirectory
        self.fileManager = fileManager
        self.isRoot = isRoot
    }

    /// Read-only. nil if the database cannot be read.
    public func plan() -> OrphanSubscriptionPlan? {
        guard let rows = UAFSubscriptionDatabase.query(databasePath, "SELECT k1, k4 FROM Subscriptions;"),
              let users = UAFSubscriptionDatabase.query(databasePath, "SELECT k0 FROM UserInformation;") else { return nil }
        return Self.plan(databasePath: databasePath, subscriptions: rows, userInformation: users,
                         existing: existingGUIDs(), currentUser: currentUserGUID)
    }

    static func plan(databasePath: String, subscriptions: [[String: String]], userInformation: [[String: String]],
                     existing: Set<String>, currentUser: String?) -> OrphanSubscriptionPlan {
        let existing = Set(existing.map { $0.uppercased() })
        let current = currentUser?.uppercased()
        // Without a trustworthy account list every row would look orphaned.
        if existing.isEmpty || current.map({ !existing.contains($0) }) ?? true {
            return OrphanSubscriptionPlan(databasePath: databasePath, accounts: [],
                                          refusal: "The local account list could not be read reliably (it must include the current user); nothing will be removed.")
        }
        var counts: [String: (all: Int, ai: Int)] = [:]
        for row in subscriptions {
            guard let guid = row["k4"]?.uppercased(), !existing.contains(guid) else { continue }
            let useCase = row["k1"] ?? ""
            counts[guid, default: (0, 0)].all += 1
            if AppleIntelligenceAccountsReport.isAppleIntelligenceUseCase(useCase) { counts[guid, default: (0, 0)].ai += 1 }
        }
        for row in userInformation {
            guard let guid = row["k0"]?.uppercased(), !existing.contains(guid), counts[guid] == nil else { continue }
            counts[guid] = (0, 0)
        }
        let accounts = counts.map { OrphanSubscriptionAccount(guid: $0.key, subscriptions: $0.value.all, appleIntelligenceUseCases: $0.value.ai) }
            .sorted { $0.guid < $1.guid }
        return OrphanSubscriptionPlan(databasePath: databasePath, accounts: accounts, refusal: nil)
    }

    /// GUIDs are uppercase hex UUIDs; anything else is rejected before it reaches SQL.
    static func isGUID(_ value: String) -> Bool {
        value.range(of: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$", options: .regularExpression) != nil
    }

    static func deleteSQL(for guids: [String]) -> String {
        let list = guids.map { "'\($0)'" }.joined(separator: ",")
        return """
        .timeout 10000
        BEGIN IMMEDIATE;
        DELETE FROM Subscriptions WHERE upper(k4) IN (\(list));
        DELETE FROM UserInformation WHERE upper(k0) IN (\(list));
        COMMIT;
        """
    }

    /// Backs up the database, removes the orphaned rows in one transaction, and verifies. Requires root.
    public func execute(now: Date = Date()) -> OrphanSubscriptionResult {
        guard let plan = plan() else {
            let empty = OrphanSubscriptionPlan(databasePath: databasePath, accounts: [], refusal: nil)
            return result(empty, error: "The subscription database could not be read.")
        }
        if let refusal = plan.refusal { return result(plan, error: refusal) }
        if plan.isEmpty { return OrphanSubscriptionResult(plan: plan, executed: false, backupPath: nil, remainingRows: 0, integrity: nil, error: nil, restartRequired: false) }
        guard isRoot() else { return result(plan, error: "Removing subscriptions requires root (the MACSPACE helper or sudo).") }
        let guids = plan.accounts.map(\.guid)
        guard guids.allSatisfy(Self.isGUID) else { return result(plan, error: "Unexpected account identifier; nothing was removed.") }

        // Backup (database plus any WAL/SHM files).
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let backup = backupDirectory.appendingPathComponent("UAFAssetSubscriptions-\(stamp)")
        do {
            try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] where fileManager.fileExists(atPath: databasePath + suffix) {
                try fileManager.copyItem(atPath: databasePath + suffix,
                                         toPath: backup.appendingPathComponent((databasePath as NSString).lastPathComponent + suffix).path)
            }
        } catch {
            return result(plan, error: "Backup failed, nothing was removed: \(error.localizedDescription)")
        }

        let run = UAFSubscriptionDatabase.write(databasePath, Self.deleteSQL(for: guids))
        let list = guids.map { "'\($0)'" }.joined(separator: ",")
        let remaining = UAFSubscriptionDatabase.query(databasePath, "SELECT count(*) AS n FROM Subscriptions WHERE upper(k4) IN (\(list));")?
            .first?["n"].flatMap(Int.init)
        let integrity = UAFSubscriptionDatabase.query(databasePath, "PRAGMA integrity_check;")?.first?.values.first
        let error = run.status == 0 ? (remaining == 0 ? nil : "Rows remain after the removal.") : "sqlite3 failed: \(run.message)"
        return OrphanSubscriptionResult(plan: plan, executed: run.status == 0, backupPath: backup.path, remainingRows: remaining,
                                        integrity: integrity, error: error, restartRequired: run.status == 0)
    }

    private func result(_ plan: OrphanSubscriptionPlan, error: String) -> OrphanSubscriptionResult {
        OrphanSubscriptionResult(plan: plan, executed: false, backupPath: nil, remainingRows: nil, integrity: nil, error: error, restartRequired: false)
    }
}
