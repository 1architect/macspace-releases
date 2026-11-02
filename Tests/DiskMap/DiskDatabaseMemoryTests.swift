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
    func testReadOnlyLiveCacheMigrationAndPageQueriesStayWithinMemoryBudget() throws {
        guard ProcessInfo.processInfo.environment["MACSPACE_DATABASE_MEMORY"] == "1" else { throw XCTSkip("Opt-in read-only disk database memory benchmark") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("disk-db-memory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.macspace.disk-map/Index-v2.scan")
        let baseline = Self.footprint(), started = Date(), sampler = Sampler()
        let db = try DiskDatabase(url: temporary.appendingPathComponent("index.sqlite"), root: "/")
        try db.importLegacy(legacy)
        let imported = Date().timeIntervalSince(started), afterImport = Self.footprint()
        let pageStart = Date(), root = try db.snapshot()
        let folders = root.index.directories["/"]?.folders ?? []
        var count = 0, maxProjection = 0
        for folder in folders {
            let page = try db.snapshot(folder: folder, inventory: false)
            maxProjection = max(maxProjection, page.index.directories.count)
            count += 1
            for child in (page.index.directories[folder]?.folders ?? []).prefix(10) {
                let next = try db.snapshot(folder: child, inventory: false)
                maxProjection = max(maxProjection, next.index.directories.count); count += 1
            }
        }
        let afterPages = Self.footprint()
        let sampled = sampler.stop()
        let extra = sampled > baseline.current ? sampled - baseline.current : 0
        print("DISK_DATABASE_MEMORY importSeconds=\(imported) importFootprintMiB=\(Double(afterImport.current)/1_048_576) pages=\(count) pageSeconds=\(Date().timeIntervalSince(pageStart)) maximumProjectionDirectories=\(maxProjection) currentFootprintMiB=\(Double(afterPages.current)/1_048_576) extraPeakMiB=\(Double(extra)/1_048_576)")
        XCTAssertLessThan(extra, 45 * 1_048_576, "The disk index must leave room for the full app within 150 MB")
        XCTAssertLessThan(maxProjection, 10000, "No page can materialize the entire folder index")
    }
}
