import Foundation
import Darwin
import XCTest
import MacSpacePlatform
@testable import MacSpaceDiskMap

final class DiskDatabaseTests: XCTestCase {
    private func fixture(_ body: (URL, DiskDatabase) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disk-db-" + UUID().uuidString).appendingPathComponent("Downloads").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let db = try DiskDatabase(url: root.appendingPathComponent("cache/index.sqlite"), root: root.path, home: root.deletingLastPathComponent().path)
        try body(root, db)
    }
    private func file(_ path: String, bytes: Int = 8192) throws {
        try FileManager.default.createDirectory(atPath: DiskDatabase.parent(path), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: URL(fileURLWithPath: path))
    }
    func testDatabaseScanMatchesReferenceAndOnlyRereadsChangedParents() throws {
        try fixture { root, db in
            try file(root.path + "/A/nested/file"); try file(root.path + "/AB/stable")
            var scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
            try scanner.scan(.init(), cursor: 7, progress: nil)
            let before = try XCTUnwrap(db.directory(root.path)?.bytes)
            let stable = try XCTUnwrap(db.directory(root.path + "/AB")?.bytes)
            var info = stat(); XCTAssertEqual(lstat(root.path + "/A/nested/file", &info), 0)
            XCTAssertEqual(try db.directory(root.path + "/A")?.bytes, UInt64(info.st_blocks) * 512)
            XCTAssertEqual(try db.directory(root.path + "/A/nested")?.ownerUID, getuid())
            try file(root.path + "/A/nested/file", bytes: 131072)
            scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
            try scanner.scan(.init(shallow: [root.path + "/A/nested"]), cursor: 8, progress: nil)
            XCTAssertEqual(scanner.visited, 1)
            XCTAssertGreaterThan(try db.directory(root.path)!.bytes, before)
            XCTAssertEqual(try db.directory(root.path + "/AB")?.bytes, stable)
            try FileManager.default.removeItem(atPath: root.path + "/A")
            try scanner.scan(.init(shallow: [root.path]), cursor: 9, progress: nil)
            XCTAssertNil(try db.directory(root.path + "/A/nested"))
            XCTAssertEqual(try db.directory(root.path)?.bytes, try db.directory(root.path + "/AB")?.bytes)
        }
    }
    func testHardlinksTransferAndSymlinkAndCloudDataAreNotTraversed() throws {
        try fixture { root, db in
            try file(root.path + "/A/file")
            try FileManager.default.createDirectory(atPath: root.path + "/B", withIntermediateDirectories: true)
            try FileManager.default.linkItem(atPath: root.path + "/A/file", toPath: root.path + "/B/file")
            try FileManager.default.createSymbolicLink(atPath: root.path + "/loop", withDestinationPath: root.path)
            try file(root.path + "/cloud/hidden")
            var scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
            scanner.metadata = { path in
                var info = stat(); guard lstat(path, &info) == 0 else { return nil }
                if path.hasSuffix("/cloud") { info.st_flags |= UInt32(SF_DATALESS) }
                return info
            }
            try scanner.scan(.init(), cursor: 1, progress: nil)
            let before = try XCTUnwrap(db.directory(root.path)?.bytes)
            XCTAssertNil(try db.directory(root.path + "/loop")); XCTAssertEqual(try db.directory(root.path + "/cloud")?.bytes, 0)
            try FileManager.default.removeItem(atPath: root.path + "/A/file")
            try scanner.scan(.init(shallow: [root.path + "/A"]), cursor: 2, progress: nil)
            XCTAssertEqual(try db.directory(root.path)?.bytes, before)
            XCTAssertEqual(try db.directory(root.path + "/B")?.bytes, before)
        }
    }
    func testNativeHardlinkUpdatesDoNotSweepUnrelatedFileRecords() throws {
        try fixture { root, db in
            let hot = root.path + "/linked", cold = root.path + "/unrelated"
            let pairs = 300, unrelated = 100_000
            for n in 0..<pairs {
                try file(hot + "/source-\(n)")
                try FileManager.default.linkItem(atPath: hot + "/source-\(n)", toPath: hot + "/alias-\(n)")
            }
            try db.transaction {
                try db.put(DiskDirectory(path: root.path))
                try db.put(DiskDirectory(path: hot))
                try db.put(DiskDirectory(path: cold, directBytes: UInt64(unrelated * 4096), bytes: UInt64(unrelated * 4096)))
                for n in 0..<unrelated {
                    let file = DiskFile(path: cold + "/large-\(n)", bytes: 4096, logicalBytes: 100_000_000, ownerUID: getuid())
                    try db.put(file); try db.putDetail(file, link: ""); try db.flushBatch()
                }
                try db.saveState(DiskIndex(root: root.path))
            }
            let start = Date()
            var scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
            try scanner.scan(.init(shallow: [hot]), cursor: 1, progress: nil)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(scanner.visited, 1)
            var info = stat(); XCTAssertEqual(lstat(hot + "/source-0", &info), 0)
            let perFile = UInt64(info.st_blocks) * 512, before = UInt64(pairs) * perFile
            XCTAssertEqual(try db.directory(hot)?.bytes, before, "Hard links must still contribute allocation once")
            var records: UInt64 = 0
            try db.query("SELECT COUNT(*) FROM file_details WHERE parent=?", [.text(cold)]) { records = DiskDatabase.number($0, 0) }
            XCTAssertEqual(records, UInt64(unrelated))
            XCTAssertLessThan(elapsed, 1.5, "Hard-link updates must seek matching identities instead of scanning the entire inventory")
            // A changed inode must still refresh every alias, including one outside the reread folder.
            try FileManager.default.createDirectory(atPath: root.path + "/other", withIntermediateDirectories: true)
            try FileManager.default.linkItem(atPath: hot + "/source-0", toPath: root.path + "/other/alias")
            try scanner.scan(.init(shallow: [root.path + "/other"]), cursor: 2, progress: nil)
            try file(hot + "/source-0", bytes: 131072)
            try scanner.scan(.init(shallow: [hot]), cursor: 3, progress: nil)
            var bytes: [UInt64] = []
            try db.query("SELECT bytes FROM files WHERE path IN (?,?,?)", [.text(hot + "/source-0"), .text(hot + "/alias-0"), .text(root.path + "/other/alias")]) { bytes.append(DiskDatabase.number($0, 0)) }
            XCTAssertEqual(bytes.count, 3)
            XCTAssertEqual(Set(bytes).count, 1)
            XCTAssertGreaterThan(bytes[0], perFile)
            print("DISK_NATIVE_HARDLINK_BENCHMARK unrelated=100000 linkedFiles=600 scanSeconds=\(elapsed)")
        }
    }

    func testParallelInitialScanPreservesPerFolderTotalsAndSharedHardlinks() throws {
        try fixture { root, db in
            let shared = root.path + "/shared"
            try file(shared)
            var info = stat(); XCTAssertEqual(lstat(shared, &info), 0)
            let allocated = UInt64(info.st_blocks) * 512
            for n in 0..<32 {
                let folder = root.path + "/branch-\(n)-雪"
                for item in 0..<64 { try file(folder + "/item-\(item).txt") }
                try FileManager.default.linkItem(atPath: shared, toPath: folder + "/alias")
            }
            var scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
            try scanner.scan(.init(), cursor: 123, progress: nil)
            XCTAssertEqual(scanner.visited, 33)
            XCTAssertEqual(try db.directory(root.path)?.bytes, allocated * (32 * 64 + 1))
            for n in 0..<32 {
                let node = try XCTUnwrap(db.directory(root.path + "/branch-\(n)-雪"))
                XCTAssertEqual(node.directBytes, allocated * 64)
                XCTAssertTrue(node.readable)
            }
            var count: UInt64 = 0
            try db.query("SELECT COUNT(*) FROM files") { count = DiskDatabase.number($0, 0) }
            XCTAssertEqual(count, 32 * 64 + 33, "Approved personal metadata and hardlink allocation records persist without a second whole-disk representation")
            XCTAssertEqual(try db.state()?.eventID, 123)
        }
    }

    func testThousandsOfAliasesDoNotRewriteTheirEntireFamilyPerEntry() throws {
        try fixture { root, db in
            let folder = root.path + "/aliases", source = folder + "/source"
            try file(source)
            for n in 0..<4000 { try FileManager.default.linkItem(atPath: source, toPath: folder + "/alias-\(n)") }
            for changes in [DiskEvents.Changes(), .init(shallow: [folder])] {
                let start = Date()
                var scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
                try scanner.scan(changes, cursor: 1, progress: nil)
                let elapsed = Date().timeIntervalSince(start)
                var info = stat(); XCTAssertEqual(lstat(source, &info), 0)
                XCTAssertEqual(try db.directory(root.path)?.bytes, UInt64(info.st_blocks) * 512)
                var count: UInt64 = 0
                try db.query("SELECT COUNT(*) FROM files") { count = DiskDatabase.number($0, 0) }
                XCTAssertEqual(count, 4001)
                XCTAssertLessThan(elapsed, 2, "One inode with thousands of names must scale by names, not names squared")
                print("DISK_ALIAS_FAMILY files=4001 scanSeconds=\(elapsed)")
            }
        }
    }

    func testSummaryTraversalSeeksPastCompletedBatchesAndCountsUnicodeDescendants() throws {
        try fixture { root, db in
            let count = 8_000
            try db.transaction {
                try db.put(DiskDirectory(path: root.path))
                for n in 0..<count {
                    let folder = root.path + String(format: "/%05d", n) + "/雪é"
                    try db.put(DiskDirectory(path: DiskDatabase.parent(folder)))
                    try db.put(DiskDirectory(path: folder, directBytes: 4096))
                    try db.putDetail(DiskFile(path: folder + "/small.pdf", bytes: 4096, logicalBytes: 4096), link: "")
                    try db.flushBatch()
                }
            }
            for (sql, values) in [
                ("SELECT path,id FROM dirs WHERE length(path)=? AND id>? ORDER BY id LIMIT 512", [DiskDatabase.Value.number(100), .number(100)]),
                ("SELECT path,id FROM dirs WHERE length(path)<? ORDER BY length(path) DESC,id LIMIT ?", [.number(100), .number(512)])
            ] {
                var plan: [String] = []
                try db.query("EXPLAIN QUERY PLAN " + sql, values) { plan.append(DiskDatabase.text($0, 3)) }
                XCTAssertTrue(plan.contains { $0.contains("SEARCH dirs") }, plan.joined(separator: "; "))
                XCTAssertFalse(plan.contains { $0.contains("SCAN dirs") || $0.contains("TEMP B-TREE") }, "Every batch must seek, not rescan or sort earlier directories")
            }
            let start = Date()
            try db.reconcileTotals(all: true)
            try db.prepareBrowseMetadata()
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(try db.directory(root.path)?.bytes, UInt64(count * 4096))
            XCTAssertEqual(try db.categorySummaries().reduce(0) { $0 + $1.count }, 0)
            XCTAssertEqual(try db.directory(root.path + "/07999")?.bytes, 4096)
            XCTAssertLessThan(elapsed, 20, "Summary rebuild must stay bounded on a broad directory tree")
            print("DISK_SUMMARY_BENCHMARK directories=16001 files=8000 seconds=\(elapsed)")
        }
    }


}

extension DiskDatabaseTests {
    func testWholeRootRefreshPreservesAllocationTransferredToAnUnreadableHardlinkAlias() throws {
        try fixture { root, db in
            let a = root.path + "/A", b = root.path + "/B"
            try file(a + "/source")
            try FileManager.default.createDirectory(atPath: b, withIntermediateDirectories: true)
            try FileManager.default.linkItem(atPath: a + "/source", toPath: b + "/alias")
            var scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
            try scanner.scan(.init(), cursor: 1, progress: nil)
            let before = try XCTUnwrap(db.directory(root.path)?.bytes)
            try FileManager.default.removeItem(atPath: a + "/source")
            scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
            scanner.metadata = { path in
                if path == b { errno = EACCES; return nil }
                var value = stat(); return lstat(path, &value) == 0 ? value : nil
            }
            try scanner.scan(.init(recursive: [root.path]), cursor: 2, progress: nil)
            XCTAssertEqual(try db.directory(root.path)?.bytes, before)
            XCTAssertEqual(try db.directory(b)?.bytes, before)
            XCTAssertEqual(try db.directory(b)?.readable, false)
            try file(b + "/alias", bytes: 131_072)
            scanner = DiskDatabaseScanner(db: db, excluded: [root.path + "/cache"])
            try scanner.scan(.init(recursive: [root.path]), cursor: 3, progress: nil)
            XCTAssertGreaterThan(try XCTUnwrap(db.directory(root.path)?.bytes), before)
            XCTAssertEqual(try db.directory(root.path)?.bytes, try db.directory(b)?.bytes)
        }
    }
}
