import SQLite3
import XCTest
@testable import MacSpaceSiri

final class SiriCloudSyncTests: XCTestCase {
    /// accountsd's store as macOS 27.2 lays it out: data class names are keyed archives, and the join table and its columns carry
    /// Core Data's entity numbers. The switch reads on when the Siri class is among the iCloud account's enabled ones, off when not.
    func testReadsTheSwitchFromAccountsStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        func store(siriEnabled: Bool) throws {
            try? FileManager.default.removeItem(at: url)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
            exec("CREATE TABLE ZACCOUNTTYPE (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER VARCHAR)")
            exec("CREATE TABLE ZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZACCOUNTTYPE INTEGER)")
            exec("CREATE TABLE ZDATACLASS (Z_PK INTEGER PRIMARY KEY, ZNAME BLOB)")
            exec("CREATE TABLE Z_2ENABLEDDATACLASSES (Z_2ENABLEDACCOUNTS INTEGER, Z_7ENABLEDDATACLASSES INTEGER)")
            exec("INSERT INTO ZACCOUNTTYPE VALUES (9, 'com.apple.account.AppleAccount'), (11, 'com.apple.account.idms')")
            exec("INSERT INTO ZACCOUNT VALUES (7, 9), (8, 11)")
            for (pk, name) in [(17, "com.apple.Dataclass.Siri"), (20, "com.apple.Dataclass.Notes")] {
                let blob = try NSKeyedArchiver.archivedData(withRootObject: name as NSString, requiringSecureCoding: true)
                var statement: OpaquePointer?
                sqlite3_prepare_v2(db, "INSERT INTO ZDATACLASS VALUES (?, ?)", -1, &statement, nil)
                sqlite3_bind_int(statement, 1, Int32(pk))
                _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(blob.count), nil) }
                XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
                sqlite3_finalize(statement)
            }
            exec("INSERT INTO Z_2ENABLEDDATACLASSES VALUES (7, 20), (8, 17)")
            if siriEnabled { exec("INSERT INTO Z_2ENABLEDDATACLASSES VALUES (7, 17)") }
        }
        try store(siriEnabled: false)
        XCTAssertEqual(SiriCloudSync.isEnabled(store: url), false, "Siri enabled only for another account type")
        try store(siriEnabled: true)
        XCTAssertEqual(SiriCloudSync.isEnabled(store: url), true)
        XCTAssertNil(SiriCloudSync.isEnabled(store: url.appendingPathExtension("missing")))
        XCTAssertEqual(SiriCloudSync.dataclassName(Data("com.apple.Dataclass.Siri".utf8)), "com.apple.Dataclass.Siri", "an older store's plain name")
    }
}
