import Foundation
import Darwin
import XCTest
@testable import MacSpaceDiskMap

final class DiskDatabaseMemoryTests: XCTestCase {
    private static func footprint() -> (current: UInt64, peak: UInt64) {
        var info = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
        return (info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint)
    }
    private final class Sampler: @unchecked Sendable {
        let lock = NSLock()
        var maximum = DiskDatabaseMemoryTests.footprint().current
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        init() {
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let current = DiskDatabaseMemoryTests.footprint().current
                lock.withLock { maximum = max(maximum, current) }
            }
            timer.schedule(deadline: .now(), repeating: .milliseconds(5)); timer.resume()
        }
        func stop() -> UInt64 { timer.cancel(); return lock.withLock { max(maximum, DiskDatabaseMemoryTests.footprint().current) } }
    }
    func testDatabaseIndexSummariesAndNavigationStayWithinMemoryBudget() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("disk-db-memory-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let baseline = Self.footprint(), sampler = Sampler(), started = Date()
        let db = try DiskDatabase(url: temporary.appendingPathComponent("index.sqlite"), root: "/fixture/Downloads", home: "/fixture")
        try db.transaction {
            try db.put(DiskDirectory(path: "/fixture/Downloads"))
            for group in 0..<10 { try db.put(DiskDirectory(path: "/fixture/Downloads/\(group)")) }
            for n in 0..<50_000 {
                let path = "/fixture/Downloads/\(n % 10)/\(n)"
                try db.put(DiskDirectory(path: path, directBytes: 8192))
                for name in ["one.txt", "two.txt"] { try db.putDetail(DiskFile(path: path + "/" + name, bytes: 4096, logicalBytes: 4096, ownerUID: getuid()), link: "") }
                try db.flushBatch()
            }
            var state = DiskIndex(root: "/fixture/Downloads"); state.browseVersion = DiskIndex.browseSchemaVersion
            try db.saveState(state)
        }
        try db.reconcileTotals(all: true)
        try db.prepareBrowseMetadata()
        let indexed = Date().timeIntervalSince(started)
        var persisted: UInt64 = 0
        try db.query("SELECT COUNT(*) FROM entries") { persisted = DiskDatabase.number($0, 0) }
        XCTAssertEqual(persisted, 100_000, "Reviewable personal metadata stays on disk so Show all does not rescan; Swift projections stay bounded")
        XCTAssertEqual(try db.categorySummaries().reduce(0) { $0 + $1.count }, 0)
        XCTAssertEqual(try db.directory("/fixture/Downloads")?.bytes, 409_600_000)
        let navigation = Date()
        for n in 0..<100 {
            let path = "/fixture/Downloads/\(n % 10)/\(n)"
            let snapshot = try db.snapshot(folder: path, inventory: false)
            XCTAssertEqual(snapshot.index.directories.count, 1)
            XCTAssertEqual(try db.browse(.init(folder: path, kind: .category, category: .other))?.files.count, 0)
        }
        let pageTime = Date().timeIntervalSince(navigation), peak = sampler.stop()
        let extra = peak > baseline.current ? peak - baseline.current : 0
        print("DISK_DATABASE_MEMORY directories=50011 files=100000 indexSeconds=\(indexed) pages=100 pageSeconds=\(pageTime) extraPeakMiB=\(Double(extra)/1_048_576)")
        XCTAssertLessThan(extra, 64 * 1_048_576, "Index growth must not retain a whole-file object graph")
        XCTAssertLessThan(pageTime, 1, "Small folder navigation must not sweep the global inventory")
    }
}
