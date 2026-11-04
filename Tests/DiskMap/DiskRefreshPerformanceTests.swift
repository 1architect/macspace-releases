import Foundation
import XCTest
import MacSpaceSdk
@testable import MacSpaceDiskMap

final class DiskRefreshPerformanceTests: XCTestCase {
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Double] = []
        func add(_ value: Double) { lock.withLock { recorded.append(value) } }
        var values: [Double] { lock.withLock { recorded } }
    }
    private func fixture(_ body: (URL, DiskDatabase) throws -> Void) throws {
        let home = URL(fileURLWithPath: "/private/tmp/refresh-performance-" + UUID().uuidString)
        let root = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let db = try DiskDatabase(url: home.appendingPathComponent("cache/index.sqlite"), root: root.path, home: home.path)
        try body(root, db)
    }

    func testSharedAncestorMarkingStaysBoundedAndIncludesEveryAffectedParent() throws {
        try fixture { root, db in
            let parent = root.path + "/deep/shared/branch/Library/Application Support/long-name/雪/another/level"
            let paths = (0..<8_000).map { parent + "/leaf-\($0)" }
            var expected = Set<String>()
            for path in paths {
                var next = path
                while DiskDatabase.contains(next, below: root.path) {
                    expected.insert(next)
                    if next == root.path { break }
                    next = DiskDatabase.parent(next)
                }
            }
            let start = Date()
            try db.transaction {
                for path in paths { try db.markTotals(path); try db.markTotals(path) }
            }
            let elapsed = Date().timeIntervalSince(start)
            var actual = Set<String>()
            try db.query("SELECT path FROM dirty") { actual.insert(DiskDatabase.text($0, 0)) }
            XCTAssertEqual(actual, expected)
            XCTAssertLessThanOrEqual(db.batchWriteCount, paths.count * 3 + 32,
                "Repeated marks must stop at a shared ancestor rather than reinsert the whole root chain")
            print("DISK_SHARED_ANCESTORS folders=8000 marks=16000 seconds=\(elapsed)")
        }
    }

    func testRepeatedMarkingReconcilesNewSiblingsAndCanBeReusedAfterCommitAndRollback() throws {
        try fixture { root, db in
            let shared = root.path + "/shared", a = shared + "/A", b = shared + "/B"
            try db.put(.init(path: root.path))
            try db.put(.init(path: shared))
            try db.put(.init(path: a, directBytes: 10))
            try db.put(.init(path: b, directBytes: 20))
            try db.markTotals(root.path)
            try db.markTotals(a); try db.markTotals(a); try db.markTotals(b)
            try db.reconcileTotals(all: false)
            XCTAssertEqual(try db.directory(root.path)?.bytes, 30)
            try db.put(.init(path: a, directBytes: 40))
            try db.markTotals(a); try db.reconcileTotals(all: false)
            XCTAssertEqual(try db.directory(root.path)?.bytes, 60)
            enum Abort: Error { case test }
            XCTAssertThrowsError(try db.transaction { try db.markTotals(b); throw Abort.test })
            try db.put(.init(path: b, directBytes: 70))
            try db.markTotals(b); try db.reconcileTotals(all: false)
            XCTAssertEqual(try db.directory(root.path)?.bytes, 110)
            try db.markTotals(root.path + "/../outside")
            XCTAssertEqual(try db.query("SELECT path FROM dirty"), 0)
        }
    }

    func testLegacyCacheUsesKnownDirectoryWorkAndRefreshFillsMissingEntryCounts() throws {
        try fixture { root, db in
            for n in 0..<480 { try FileManager.default.createDirectory(at: root.appendingPathComponent("legacy-\(n)"), withIntermediateDirectories: false) }
            var scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(), cursor: 1, progress: nil)
            try db.execute("UPDATE dirs SET items=NULL")
            let before = try db.scanWork(recursive: [root.path], shallow: [])
            XCTAssertEqual(before.directories, 481)
            XCTAssertNil(before.entries, "Unknown legacy file counts must not masquerade as measured zeros")
            let reports = Reports()
            scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(recursive: [root.path]), cursor: 2, progress: { reports.add($0) })
            XCTAssertGreaterThanOrEqual(reports.values.filter { $0 > 0 && $0 < 0.8 }.count, 4)
            XCTAssertEqual(try db.scanWork(recursive: [root.path], shallow: []).entries, 480)
            XCTAssertEqual(reports.values.last, 1)
        }
    }

    func testDirtyTotalsReportWorkWithoutMaterializingTheTree() throws {
        try fixture { root, db in
            try db.put(DiskDirectory(path: root.path, itemCount: 1_000))
            for n in 0..<1_000 {
                let path = root.path + "/leaf-\(n)"
                try db.put(DiskDirectory(path: path, itemCount: 0, directBytes: 4))
                try db.markTotals(path)
            }
            let reports = Reports()
            try db.reconcileTotals(all: false, progress: { reports.add($0) })
            XCTAssertEqual(reports.values.first, 0)
            XCTAssertEqual(reports.values.last, 1)
            XCTAssertGreaterThanOrEqual(reports.values.filter { $0 > 0 && $0 < 1 }.count, 4)
            XCTAssertEqual(try db.directory(root.path)?.bytes, 4_000)
            XCTAssertEqual(try db.query("SELECT path FROM dirty"), 0)
        }
    }

    func testNewSubtreeWithoutCachedCountsDoesNotDeclareTraversalCompleteEarly() throws {
        try fixture { root, db in
            var scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(), cursor: 1, progress: nil)
            let added = root.appendingPathComponent("added")
            try FileManager.default.createDirectory(at: added, withIntermediateDirectories: false)
            for n in 0..<1_000 { try FileManager.default.createDirectory(at: added.appendingPathComponent("folder-\(n)"), withIntermediateDirectories: false) }
            let reports = Reports()
            scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(recursive: [added.path]), cursor: 2, progress: { reports.add($0) })
            let walking = reports.values.filter { $0 > 0 && $0 < 0.8 }
            XCTAssertFalse(walking.isEmpty, "Unknown scopes still report actual work performed")
            XCTAssertTrue(walking.allSatisfy { $0 < 0.05 }, "An unknown thousand-folder subtree must not complete its traversal estimate on the first folders")
            XCTAssertEqual(try db.directory(added.path)?.itemCount, 1_000)
            XCTAssertEqual(reports.values.last, 1)
        }
    }

    func testWorkEstimatesRespectFolderBoundariesAndKeepUnknownScopesUnknown() throws {
        try fixture { root, db in
            let a = root.path + "/A", b = root.path + "/AB"
            for (path, items) in [(root.path, 2), (a, 1), (a + "/child", 0), (b, 30)] {
                try db.put(DiskDirectory(path: path, itemCount: UInt64(items)))
            }
            let scoped = try db.scanWork(recursive: [a], shallow: [])
            XCTAssertEqual(scoped.directories, 2); XCTAssertEqual(scoped.entries, 1)
            let combined = try db.scanWork(recursive: [a], shallow: [b])
            XCTAssertEqual(combined.directories, 3); XCTAssertEqual(combined.entries, 31)
            let newFolder = try db.scanWork(recursive: [a + "/new"], shallow: [])
            XCTAssertEqual(newFolder.directories, 1); XCTAssertNil(newFolder.entries); XCTAssertTrue(newFolder.unknownScopes)
        }
    }

    func testRecursiveRefreshReportsDirectoryWorkBeforeTotalsEvenWithoutFiles() throws {
        try fixture { root, db in
            for n in 0..<480 { try FileManager.default.createDirectory(at: root.appendingPathComponent("folder-\(n)"), withIntermediateDirectories: false) }
            var scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(), cursor: 1, progress: nil)
            let reports = Reports()
            scanner = DiskDatabaseScanner(db: db, excluded: [])
            try scanner.scan(.init(recursive: [root.path]), cursor: 2, progress: { reports.add($0) })
            let values = reports.values
            XCTAssertEqual(scanner.visited, 481)
            XCTAssertGreaterThanOrEqual(values.filter { $0 > 0 && $0 < 0.8 }.count, 4,
                "Directory-heavy rereads must advance progress during traversal, not wait until totals")
            XCTAssertEqual(values.last, 1)
            XCTAssertEqual(try db.state()?.eventID, 2)
        }
    }
}

extension DiskRefreshPerformanceTests {
    func testReactivatedCallerRetriesCancelledScanInsteadOfReturningOldCache() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/reactivated-scan-" + UUID().uuidString)
        let root = home.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for n in 0..<2_000 { try FileManager.default.createDirectory(at: root.appendingPathComponent("folder-\(n)"), withIntermediateDirectories: false) }
        let file = root.appendingPathComponent("file.txt")
        try Data([1]).write(to: file)
        let store = DiskStore(root: root.path, cache: home.appendingPathComponent("cache/index"), home: home.path)
        let initial = await store.view()
        let before = try XCTUnwrap(initial.index.directories[root.path]?.bytes)
        try Data(repeating: 1, count: 131_072).write(to: file)
        await store.mark([root.path], recursive: true)
        let reports = LoadProgressRelay()
        let read = Task { await store.view(progress: { reports.report($0) }) }
        for _ in 0..<200 where reports.fraction == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(reports.fraction)
        await store.setActive(false)
        await store.setActive(true)
        let joined = await store.view()
        let original = await read.value
        XCTAssertGreaterThan(joined.index.revision, initial.index.revision)
        XCTAssertGreaterThan(try XCTUnwrap(joined.index.directories[root.path]?.bytes), before)
        XCTAssertEqual(original.index.revision, joined.index.revision)
        XCTAssertNotEqual(joined.index.loadError, true)
        await store.setActive(false)
    }
}

extension DiskRefreshPerformanceTests {
    func testConsumedHistoryAdvancesCursorWithoutInventingANewMeasurementRevision() throws {
        try fixture { root, db in
            try db.put(DiskDirectory(path: root.path, bytes: 123))
            var initial = DiskIndex(root: root.path); initial.eventID = 10; initial.revision = 9
            try db.saveState(initial)
            try db.advanceEventCursor(20)
            XCTAssertEqual(try db.state()?.eventID, 20)
            XCTAssertEqual(try db.state()?.revision, 9)
            XCTAssertEqual(try db.directory(root.path)?.bytes, 123)
            try db.advanceEventCursor(19)
            XCTAssertEqual(try db.state()?.eventID, 20)
        }
    }
    func testExplicitMarksBeforeBootstrapAreNotLostAndPreparationReportsRealProgress() async throws {
        let home = URL(fileURLWithPath: "/private/tmp/bootstrap-marks-" + UUID().uuidString)
        let root = home.appendingPathComponent("Downloads"), cache = home.appendingPathComponent("cache/index")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = root.appendingPathComponent("file")
        try Data([1]).write(to: file)
        let first = DiskStore(root: root.path, cache: cache, home: home.path)
        let old = await first.view(); await first.setActive(false)
        try Data(repeating: 1, count: 131_072).write(to: file)
        let restored = DiskStore(root: root.path, cache: cache, home: home.path)
        await restored.mark([root.path], recursive: true)
        let reports = Reports()
        let result = await restored.view(progress: { reports.add($0) })
        XCTAssertEqual(reports.values.first, 0.02)
        XCTAssertGreaterThan(result.index.revision, old.index.revision)
        XCTAssertGreaterThan(try XCTUnwrap(result.index.directories[root.path]?.bytes), try XCTUnwrap(old.index.directories[root.path]?.bytes))
        await restored.setActive(false)
    }
}
