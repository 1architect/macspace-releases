import Foundation
import XCTest
@testable import MacSpaceDiskMap

final class DiskTotalsPerformanceTests: DiskSecurityFixtureCase {
    func testCancelledDatabaseInitializationClosesPreparedStatementsOnce() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/cancelled-database-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try DiskDatabase(url: home.appendingPathComponent("cache/index.sqlite"), root: home.path, home: home.path)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(cancelled)
        // The failed unpublished database remains reusable by a fresh reader.
        _ = try DiskDatabase(url: home.appendingPathComponent("cache/index.sqlite"), root: home.path, home: home.path)
    }

    func testTotalsScaleWithDirectoriesAndPreserveHardLinkAllocation() throws {
        let home = URL(fileURLWithPath: "/private/tmp/totals-performance-" + UUID().uuidString)
        let root = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let db = try DiskDatabase(url: home.appendingPathComponent("cache/index.sqlite"), root: root.path, home: home.path)
        let folders = 2_000
        try db.transaction {
            try db.put(.init(path: root.path))
            for n in 0..<folders {
                let path = root.path + String(format: "/folder-%05d-雪", n)
                try db.put(.init(path: path, directBytes: 4096))
                // Two names for one family in separate directories, plus a distinct family per folder.
                try db.put(DiskFile(path: path + "/shared", bytes: 8192, logicalBytes: 8192), link: "shared")
                try db.put(DiskFile(path: path + "/unique", bytes: 16384, logicalBytes: 16384), link: "family-\(n)")
            }
        }
        // Model a personal inventory with many ordinary rows and relatively few hard links.
        try db.query("WITH RECURSIVE names(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM names WHERE n<64) INSERT INTO entries SELECT d.id,'ordinary-'||n,64,64,NULL,'','other',NULL,'',1 FROM dirs d CROSS JOIN names WHERE d.path<>?", [.text(root.path)])
        try db.execute("DROP INDEX entries_link_parents")
        let legacyStart = Date()
        try db.transaction {
            var paths: [String] = []
            try db.query("SELECT path FROM dirs ORDER BY length(path) DESC,id") { paths.append(DiskDatabase.text($0, 0)) }
            for path in paths { try db.total(path) }
        }
        let legacySeconds = Date().timeIntervalSince(legacyStart)
        let expected = try db.directory(root.path)?.bytes
        try db.createIndexes()
        try db.execute("UPDATE dirs SET total=0")
        let start = Date()
        var totalStatements = 0
        try db.transaction {
            try db.reconcileTotals(all: true)
            totalStatements = db.batchWriteCount
        }
        print("DISK_TOTALS folders=\(folders) legacySeconds=\(legacySeconds) optimizedSeconds=\(Date().timeIntervalSince(start))")
        XCTAssertLessThan(totalStatements, 128, "Totals must update bounded groups rather than issue a statement per directory")
        XCTAssertEqual(try db.directory(root.path)?.bytes, expected)
        XCTAssertEqual(try db.directory(root.path)?.bytes, UInt64(folders * (4096 + 16384) + 8192))
        XCTAssertEqual(try db.directory(root.path + "/folder-00000-雪")?.bytes, 4096 + 16384 + 8192)
        XCTAssertEqual(try db.directory(root.path + "/folder-00001-雪")?.bytes, 4096 + 16384)
        // A changed family still transfers to exactly one representative on partial reconciliation.
        try db.execute("UPDATE entries SET bytes=32768 WHERE link='shared'")
        for path in try db.linkParents(at: root.path + "/folder-00001-雪") { try db.markTotals(path) }
        try db.transaction { try db.reconcileTotals(all: false) }
        XCTAssertEqual(try db.directory(root.path)?.bytes, UInt64(folders * (4096 + 16384) + 32768))
    }
}
