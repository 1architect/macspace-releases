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
        loc("Open System Settings > Apple Account > iCloud."),
        loc("Under Saved to iCloud, click See All, then Siri."),
        loc("Turn off Sync this Mac and keep the data on this Mac."),
    ]

    /// Whether the switch is on: the Siri data class among the iCloud account's enabled ones, read from accountsd's Core Data store
    /// (read-only; it needs Full Disk Access). nil when it cannot be read or there is no iCloud account. The join table's and its
    /// columns' names carry Core Data's entity numbers (`Z_2ENABLEDDATACLASSES`, `Z_7ENABLEDDATACLASSES`), so they are looked up.
    /// A data class's name is an archived string (`ZDATACLASS.ZNAME`, a keyed archive) on macOS 27.2, read on 26B5091g: there is no
    /// identifier column, so names are decoded here; a plain-text name (an older store) is read as it is.
    public static func isEnabled(store: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Accounts/Accounts4.sqlite")) -> Bool? {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(store.path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        func rows(_ sql: String) -> [[Data]]? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            var result: [[Data]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append((0..<sqlite3_column_count(statement)).map { column in
                    guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
                    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
                })
            }
            return result
        }
        func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
        guard let join = rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z\\_%ENABLEDDATACLASSES' ESCAPE '\\'")?.first?.first.map(text),
              let columns = rows("PRAGMA table_info(\(join))")?.map({ text($0[1]) }),
              let accountColumn = columns.first(where: { $0.hasSuffix("ACCOUNTS") }),
              let dataclassColumn = columns.first(where: { $0.hasSuffix("ENABLEDDATACLASSES") }),
              let accounts = rows("SELECT a.Z_PK FROM ZACCOUNT a JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK WHERE t.ZIDENTIFIER = 'com.apple.account.AppleAccount'"),
              !accounts.isEmpty,
              let dataclasses = rows("SELECT Z_PK, ZNAME FROM ZDATACLASS"),
              let siri = dataclasses.first(where: { dataclassName($0[1]) == "com.apple.Dataclass.Siri" }).map({ text($0[0]) })
        else { return nil }
        let accountList = accounts.map { text($0[0]) }.joined(separator: ",")
        guard let enabled = rows("SELECT COUNT(*) FROM \(join) WHERE \(dataclassColumn) = \(siri) AND \(accountColumn) IN (\(accountList))"),
              let count = enabled.first.flatMap({ Int(text($0[0])) }) else { return nil }
        return count > 0
    }

    /// A data class's name: a keyed archive of a string, or the string itself.
    static func dataclassName(_ data: Data) -> String? {
        if let name = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: data) { return name as String }
        let plain = String(decoding: data, as: UTF8.self)
        return plain.hasPrefix("com.apple.") ? plain : nil
    }
}
