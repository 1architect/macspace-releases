import Foundation
import XCTest
import MacSpaceSdk
@testable import MacSpaceDiskMap

/// Opt-in backend measurement. Never launches MacSpace or modifies scanned files.
final class DiskLoadingDiagnosticTests: XCTestCase {
    func testCompleteNativeLoadAndCachedReopen() async throws {
        guard let root = ProcessInfo.processInfo.environment["MACSPACE_DIAGNOSTIC_ROOT"] else {
            throw XCTSkip("Set MACSPACE_DIAGNOSTIC_ROOT to opt into a read-only filesystem scan")
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("disk-loading-diagnostic-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let started = Date(), reports = LoadProgressRelay()
        reports.attach { value in
            let text = "DISK_LOAD progress=\(value) seconds=\(Date().timeIntervalSince(started))\n"
            FileHandle.standardError.write(Data(text.utf8))
        }
        let store = DiskStore(root: root, cache: cache.appendingPathComponent("index"))
        let first = await store.view(progress: { reports.report($0) })
        XCTAssertNotEqual(first.index.loadError, true)
        XCTAssertEqual(reports.fraction, 1)
        XCTAssertEqual(first.index.summaryVersion, DiskIndex.summarySchemaVersion)
        let loaded = Date().timeIntervalSince(started)
        await store.flushPersistence()
        let base = cache.appendingPathComponent("index.sqlite")
        let pointer = base.appendingPathExtension("current")
        let location = (try? String(contentsOf: pointer, encoding: .utf8)).map { base.deletingLastPathComponent().appendingPathComponent($0) } ?? base
        let db = try DiskDatabase(url: location, root: root)
        var directories: UInt64 = 0, files: UInt64 = 0
        try db.query("SELECT COUNT(*) FROM dirs") { directories = DiskDatabase.number($0, 0) }
        try db.query("SELECT COUNT(*) FROM entries") { files = DiskDatabase.number($0, 0) }
        let footprint = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.uint64Value ?? 0
        print("DISK_FULL_INDEX directories=\(directories) retainedFileEntries=\(files) databaseBytes=\(footprint)")
        let reopen = Date(), restored = DiskStore(root: root, cache: cache.appendingPathComponent("index"))
        let second = await restored.view()
        XCTAssertNotEqual(second.index.loadError, true)
        XCTAssertEqual(second.index.summaryVersion, DiskIndex.summarySchemaVersion)
        print("DISK_FULL_LOAD firstSeconds=\(loaded) reopenSeconds=\(Date().timeIntervalSince(reopen)) categories=\(first.index.categories?.count ?? 0)")
    }
}
