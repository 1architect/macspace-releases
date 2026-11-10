import Darwin
import Foundation
import XCTest
import MacSpacePlatform
@testable import MacSpaceDiskMap

final class DiskNativeRefreshTests: DiskSecurityFixtureCase {
    private func fixture(_ body: (URL, DiskDatabase, DiskDatabase) throws -> Void) throws {
        let home = URL(fileURLWithPath: "/private/tmp/native-refresh-" + UUID().uuidString)
        let root = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let native = try DiskDatabase(url: home.appendingPathComponent("cache/native.sqlite"), root: root.path, home: home.path)
        let reference = try DiskDatabase(url: home.appendingPathComponent("cache/reference.sqlite"), root: root.path, home: home.path)
        try body(root, native, reference)
    }
    private func file(_ path: String, bytes: Int = 8192) throws {
        try FileManager.default.createDirectory(atPath: DiskDatabase.parent(path), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: URL(fileURLWithPath: path))
    }
    private func compare(_ a: DiskDatabase, _ b: DiskDatabase, file: StaticString = #filePath, line: UInt = #line) throws {
        var aa: [String] = [], bb: [String] = []
        func collect(_ db: DiskDatabase, result: inout [String]) throws {
            try db.query("SELECT path,direct,total,readable,uid,COALESCE(bundle,''),COALESCE(items,-1) FROM dirs ORDER BY path") { row in
                result.append((0...6).map { DiskDatabase.text(row, Int32($0)) }.joined(separator: "|"))
            }
            try db.query("SELECT path,bytes,logical,uid,link,category,modified,kind FROM files ORDER BY path") { row in
                result.append((0...7).map { DiskDatabase.text(row, Int32($0)) }.joined(separator: "|"))
            }
        }
        try collect(a, result: &aa); try collect(b, result: &bb)
        XCTAssertEqual(aa, bb, file: file, line: line)
    }
    func testParallelRefreshMatchesSequentialMeasurementsAfterAddsEditsRemovalsAndLinks() throws {
        try fixture { root, native, reference in
            let base = root.path
            for n in 0..<300 { try self.file(base + "/branch-\(n)/nested/文档.txt") }
            try self.file(base + "/A/source")
            try FileManager.default.createDirectory(atPath: base + "/B", withIntermediateDirectories: true)
            try FileManager.default.linkItem(atPath: base + "/A/source", toPath: base + "/B/alias")
            try FileManager.default.createSymbolicLink(atPath: base + "/loop", withDestinationPath: base)
            for db in [native, reference] { var scan = DiskDatabaseScanner(db: db, excluded: []); try scan.scan(.init(), cursor: 1, progress: nil) }
            try self.file(base + "/branch-3/nested/文档.txt", bytes: 131_072)
            try FileManager.default.removeItem(atPath: base + "/branch-4")
            try FileManager.default.removeItem(atPath: base + "/A/source")
            try self.file(base + "/new/child/grandchild/new.zip")
            for (db, parallel) in [(native, true), (reference, false)] {
                var scan = DiskDatabaseScanner(db: db, excluded: []); scan.parallelRootRefresh = parallel
                try scan.scan(.init(recursive: [base]), cursor: 2, progress: nil)
            }
            try compare(native, reference)
            XCTAssertNotNil(try native.directory(base + "/new/child/grandchild"))
            XCTAssertNil(try native.directory(base + "/branch-4"))
            XCTAssertEqual(try native.children(base + "/new/child"), [base + "/new/child/grandchild"])
        }
    }
    func testUnvisitedDirectoryAndChangedAliasKeepCachedTruth() throws {
        try fixture { root, native, reference in
            let base = root.path, a = base + "/A", b = base + "/B"
            try self.file(a + "/source")
            try FileManager.default.createDirectory(atPath: b, withIntermediateDirectories: true)
            try FileManager.default.linkItem(atPath: a + "/source", toPath: b + "/alias")
            for db in [native, reference] { var scan = DiskDatabaseScanner(db: db, excluded: []); try scan.scan(.init(), cursor: 1, progress: nil) }
            try self.file(a + "/source", bytes: 131_072)
            for (db, parallel) in [(native, true), (reference, false)] {
                var scan = DiskDatabaseScanner(db: db, excluded: []); scan.parallelRootRefresh = parallel
                scan.metadata = { path in
                    if path == b { errno = EACCES; return nil }
                    var value = stat(); return lstat(path, &value) == 0 ? value : nil
                }
                try scan.scan(.init(recursive: [base]), cursor: 2, progress: nil)
            }
            try compare(native, reference)
            var bytes: [UInt64] = []
            try native.query("SELECT bytes FROM files WHERE link<>''") { bytes.append(DiskDatabase.number($0, 0)) }
            XCTAssertEqual(bytes.count, 2); XCTAssertEqual(Set(bytes).count, 1)
        }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func cancel() { lock.withLock { stopped = true } }
        var isCancelled: Bool { lock.withLock { stopped } }
    }
    func testCancellationBeforeMergePreservesCompletedIndexAndRetryUsesFreshStaging() throws {
        try fixture { root, db, _ in
            let base = root.path
            for n in 0..<200 { try self.file(base + "/folder-\(n)/file") }
            var scan = DiskDatabaseScanner(db: db, excluded: [])
            try scan.scan(.init(), cursor: 1, progress: nil)
            let before = try XCTUnwrap(db.directory(base)?.bytes)
            try self.file(base + "/folder-3/file", bytes: 131_072)
            let stop = Cancellation()
            scan = DiskDatabaseScanner(db: db, excluded: []); scan.cancelled = { stop.isCancelled }
            XCTAssertThrowsError(try scan.scan(.init(recursive: [base]), cursor: 2, progress: { value in
                if value > 0.1 { stop.cancel() }
            })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(try db.state()?.eventID, 1)
            XCTAssertEqual(try db.directory(base)?.bytes, before)
            scan = DiskDatabaseScanner(db: db, excluded: [])
            try scan.scan(.init(recursive: [base]), cursor: 3, progress: nil)
            XCTAssertEqual(try db.state()?.eventID, 3)
            XCTAssertGreaterThan(try XCTUnwrap(db.directory(base)?.bytes), before)
        }
    }
    func testCloudOnlySubtreeRemainsUnenumeratedAndKeepsItsPriorInventory() throws {
        try fixture { root, native, reference in
            let base = root.path, cloud = base + "/cloud"
            try self.file(cloud + "/old")
            try self.file(base + "/live/file")
            for db in [native, reference] { var scan = DiskDatabaseScanner(db: db, excluded: []); try scan.scan(.init(), cursor: 1, progress: nil) }
            try self.file(base + "/live/file", bytes: 131_072)
            try self.file(cloud + "/new-should-not-be-enumerated")
            for (db, parallel) in [(native, true), (reference, false)] {
                var scan = DiskDatabaseScanner(db: db, excluded: []); scan.parallelRootRefresh = parallel
                scan.metadata = { path in
                    var value = stat(); guard lstat(path, &value) == 0 else { return nil }
                    if path == cloud { value.st_flags |= UInt32(SF_DATALESS) }
                    return value
                }
                try scan.scan(.init(recursive: [base]), cursor: 2, progress: nil)
            }
            try compare(native, reference)
            var found: [String] = []
            try native.query("SELECT path FROM files WHERE parent=?", [.text(cloud)]) { found.append(DiskDatabase.text($0, 0)) }
            XCTAssertEqual(found, [cloud + "/old"])
            XCTAssertEqual(try native.directory(cloud)?.readable, false)
        }
    }

    func testIncompleteDirectoryStagingCannotEraseOldMembershipOrSupplyAliasMeasurements() throws {
        try fixture { root, db, _ in
            let parent = root.path + "/folder", path = parent + "/old"
            try self.file(path)
            var scan = DiskDatabaseScanner(db: db, excluded: []); try scan.scan(.init(), cursor: 1, progress: nil)
            let before = try XCTUnwrap(db.directory(parent))
            try db.transaction {
                try db.beginNativeRefresh()
                try db.nativeDirectorySeen(root.path, uid: getuid())
                try db.nativeDirectorySeen(parent, uid: getuid())
                try db.nativeDirectoryFinished(root.path, direct: 0, bundle: nil, readable: true, items: 1, complete: true)
                try db.put(DiskFile(path: parent + "/partial", bytes: 9999, logicalBytes: 9999, ownerUID: getuid()), staging: true)
                try db.nativeDirectoryFinished(parent, direct: 9999, bundle: nil, readable: true, items: 1, complete: false)
                _ = try db.finishNativeRefresh(cancelled: { false })
                try db.reconcileTotals(all: true)
            }
            XCTAssertEqual(try db.directory(parent)?.bytes, before.bytes)
            XCTAssertEqual(try db.directory(parent)?.readable, false)
            var names: [String] = []
            try db.query("SELECT name FROM entries WHERE parent=(SELECT id FROM dirs WHERE path=?)", [.text(parent)]) { names.append(DiskDatabase.text($0, 0)) }
            XCTAssertEqual(names, ["old"])
        }
    }
    func testCancellationAfterFirstMergeBatchRollsBackAndRetryMergesLaterDirectories() throws {
        try fixture { root, db, _ in
            try db.put(DiskDirectory(path: root.path))
            try db.query("WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<4100) INSERT INTO dirs(path,parent,direct,total,readable) SELECT ?||i,1,0,0,1 FROM n", [.text(root.path + "/folder-")])
            try db.saveState(DiskIndex(root: root.path))
            let first = root.path + "/folder-1/a.txt", last = root.path + "/folder-4100/b.txt"
            func merge(cancelAfterFirstBatch: Bool) throws {
                var cancel = false
                try db.transaction {
                    try db.beginNativeRefresh()
                    try db.execute("INSERT INTO refresh_dirs(id,complete,readable) SELECT id,1,1 FROM dirs")
                    for path in [first, last] {
                        try db.put(DiskFile(path: path, bytes: 4096, logicalBytes: 4096, ownerUID: getuid()), staging: true)
                    }
                    _ = try db.finishNativeRefresh(cancelled: { cancel }, progress: { value in
                        if cancelAfterFirstBatch && value > 0.2 { cancel = true }
                    })
                }
            }
            XCTAssertThrowsError(try merge(cancelAfterFirstBatch: true)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(try db.query("SELECT name FROM entries"), 0)
            try merge(cancelAfterFirstBatch: false)
            XCTAssertEqual(try db.query("SELECT name FROM entries"), 2)
        }
    }

    func testLinkedDirectoryLookupIsBoundedAndExcludesOrdinaryFiles() throws {
        try fixture { root, db, _ in
            let linked = root.path + "/linked", ordinary = root.path + "/ordinary"
            try db.put(DiskDirectory(path: root.path))
            for path in [linked, ordinary] { try db.put(DiskDirectory(path: path)) }
            try db.put(DiskFile(path: linked + "/alias", bytes: 4096, logicalBytes: 4096), link: "family")
            try db.put(DiskFile(path: ordinary + "/file", bytes: 4096, logicalBytes: 4096, ownerUID: getuid()))
            XCTAssertEqual(try db.linkedDirectoryPaths(limit: 1), [linked])
            XCTAssertNil(try db.linkedDirectoryPaths(limit: 0))
        }
    }

}
