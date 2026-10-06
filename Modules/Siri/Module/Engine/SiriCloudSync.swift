import Foundation
import SQLite3

/// Siri's iCloud sync: the "Siri" switch under System Settings > Apple Account > iCloud > Saved to iCloud ("Sync this Mac").
///
/// MacSpace cannot change it. The switch is a data class of the iCloud account (`ACAccountDataclassSiri`), kept by accountsd, which
/// shows the account only to processes Apple entitles (an app sees no account at all; tested 2026-10-04). The `Cloud Sync Enabled`
/// key in `com.apple.assistant.backedup` is Siri's own preference, not that switch: writing it left System Settings unchanged. So
/// MacSpace says what the switch does and opens the page that has it. It reads the switch from accountsd's database, with Full Disk
/// Access (`isEnabled`).
///
/// It matters because MacSpace switches Apple Intelligence off by changing the Siri language, and with sync on the iPhone and
/// iPad follow (measured 2026-10-04).
public enum SiriCloudSync {
    /// The Apple Account page of System Settings, at iCloud.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud")!

    public static let steps = [
        "Open System Settings > Apple Account > iCloud.",
        "Under Saved to iCloud, click See All, then Siri.",
        "Turn off Sync this Mac, and choose to keep Siri's data on this Mac.",
    ]

    /// Whether the switch is on: the Siri data class among the iCloud account's enabled ones, read from accountsd's Core Data store
    /// (read-only; it needs Full Disk Access). nil when it cannot be read or there is no iCloud account. The join table's name
    /// carries Core Data's entity numbers, so it is looked up rather than named.
    public static func isEnabled(store: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Accounts/Accounts4.sqlite")) -> Bool? {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(store.path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        func rows(_ sql: String) -> [[String]]? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            var result: [[String]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
            }
            return result
        }
        guard let join = rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z\\_%ENABLEDDATACLASSES' ESCAPE '\\'")?.first?.first,
              let columns = rows("PRAGMA table_info(\(join))")?.map({ $0[1] }),
              let accountColumn = columns.first(where: { $0.hasSuffix("ACCOUNTS") }),
              let dataclassColumn = columns.first(where: { $0.hasSuffix("ENABLEDDATACLASSES") }),
              let accounts = rows("SELECT a.Z_PK FROM ZACCOUNT a JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK WHERE t.ZIDENTIFIER = 'com.apple.account.AppleAccount'"),
              !accounts.isEmpty,
              let enabled = rows("SELECT COUNT(*) FROM \(join) j JOIN ZDATACLASS d ON j.\(dataclassColumn) = d.Z_PK WHERE d.ZIDENTIFIER = 'com.apple.Dataclass.Siri' AND j.\(accountColumn) IN (\(accounts.map { $0[0] }.joined(separator: ",")))"),
              let count = enabled.first.flatMap({ Int($0[0]) })
        else { return nil }
        return count > 0
    }

    /// Where a Siri language change goes.
    public static let reach = "With Siri's iCloud sync on, iPhone and iPad signed in to the same Apple Account get the same Siri language. Turn it off in iCloud settings to keep the change on this Mac."
}
