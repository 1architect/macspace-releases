import Foundation
import XCTest
import MacSpaceSdk
@testable import MacSpaceDiskMap

/// Opt-in backend measurement. Never launches MacSpace or modifies scanned files.
final class DiskLoadingDiagnosticTests: DiskSecurityFixtureCase {
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
        if ProcessInfo.processInfo.environment["MACSPACE_DIAGNOSTIC_REFRESH"] == "1" {
            let refresh = Date()
            await store.mark([root], recursive: true)
            let updated = await store.view(progress: { value in
                DiskScanMetrics.write("DISK_REFRESH progress=\(value) seconds=\(Date().timeIntervalSince(refresh))")
            })
            XCTAssertGreaterThan(updated.index.revision, first.index.revision)
            XCTAssertNotEqual(updated.index.loadError, true)
            print("DISK_FULL_REFRESH seconds=\(Date().timeIntervalSince(refresh))")
        }
        let reopen = Date(), restored = DiskStore(root: root, cache: cache.appendingPathComponent("index"))
        let second = await restored.view()
        XCTAssertNotEqual(second.index.loadError, true)
        XCTAssertEqual(second.index.summaryVersion, DiskIndex.summarySchemaVersion)
        print("DISK_FULL_LOAD firstSeconds=\(loaded) reopenSeconds=\(Date().timeIntervalSince(reopen)) categories=\(first.index.categories?.count ?? 0)")
    }
}

extension DiskLoadingDiagnosticTests {
    private struct ReplayOptions: OptionStore {
        func bool(_ id: String) -> Bool { false }
        func string(_ id: String) -> String { "" }
        func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
    }
    private struct ReplayPermissions: PermissionChecker {
        func status(of permission: Permission) -> PermissionStatus { .granted }
    }
    private final class FirstProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var first: Double?
        var elapsed: Double? { lock.withLock { first } }
        func record(_ fraction: Double, elapsed: Double) {
            guard fraction > 0 else { return }
            lock.withLock {
                if first == nil {
                    first = elapsed
                    DiskScanMetrics.write("DISK_FIRST_POSITIVE elapsed=\(elapsed) fraction=\(fraction)")
                }
            }
        }
    }
    private func cachedState(_ path: String) throws -> DiskIndex {
        let db = try DiskDatabase(url: URL(fileURLWithPath: path), root: "/")
        return try XCTUnwrap(db.state())
    }
    /// The input is a SQLite backup, never the live app cache. The store works on its own second copy.
    func testForegroundCachedModuleReadCompletesFromIsolatedIndex() async throws {
        guard let source = ProcessInfo.processInfo.environment["MACSPACE_REPLAY_CACHE"] else {
            throw XCTSkip("Set MACSPACE_REPLAY_CACHE to an isolated SQLite backup for a read-only native replay")
        }
        let directory = URL(fileURLWithPath: "/private/tmp/macspace-cache-replay-" + UUID().uuidString)
        let cache = directory.appendingPathComponent("cache/index")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: cache.appendingPathExtension("sqlite"))
        let initial = try cachedState(cache.appendingPathExtension("sqlite").path)
        let start = Date(), firstProgress = FirstProgress()
        let store = DiskStore(root: "/", cache: cache)
        let forced = ProcessInfo.processInfo.environment["MACSPACE_REPLAY_FORCE_ROOT"] != "0"
        if forced { await store.mark(["/"], recursive: true) }
        let module = DiskMapModule(store: store)
        let context = ModuleContext(manifest: ModuleManifest(id: "com.macspace.disk-map", name: "Disk", summary: "", version: "test", symbol: "internaldrive"),
            options: ReplayOptions(), permissions: ReplayPermissions())
        let progress = LoadProgressRelay()
        progress.attach { fraction in
            firstProgress.record(fraction, elapsed: Date().timeIntervalSince(start))
            DiskScanMetrics.write("DISK_NATIVE_REPLAY progress=\(fraction) elapsed=\(Date().timeIntervalSince(start))")
        }
        async let tile = module.tile(context: context, progress: { progress.report($0) })
        async let screen = module.screen(context: context, progress: { progress.report($0) })
        let presentation = await (tile, screen)
        let final = await store.navigation()
        if let maximum = ProcessInfo.processInfo.environment["MACSPACE_REPLAY_MAX_FIRST_PROGRESS"].flatMap(Double.init) {
            XCTAssertLessThanOrEqual(try XCTUnwrap(firstProgress.elapsed), maximum)
        }
        if let maximum = ProcessInfo.processInfo.environment["MACSPACE_REPLAY_MAX_LOAD_SECONDS"].flatMap(Double.init) {
            XCTAssertLessThanOrEqual(Date().timeIntervalSince(start), maximum)
        }
        XCTAssertNotEqual(final.index.loadError, true)
        if forced { XCTAssertGreaterThan(final.index.revision, initial.revision) }
        else { XCTAssertGreaterThanOrEqual(final.index.revision, initial.revision) }
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertEqual(presentation.1.title, presentation.0.title)
        print("DISK_NATIVE_REPLAY_COMPLETE elapsed=\(Date().timeIntervalSince(start)) revision=\(final.index.revision) initial=\(initial.revision)")
        await module.setActive(false)
        let reopened = Date(), restoredStore = DiskStore(root: "/", cache: cache)
        let restoredModule = DiskMapModule(store: restoredStore)
        async let restoredTile = restoredModule.tile(context: context)
        async let restoredScreen = restoredModule.screen(context: context)
        let restored = await (restoredTile, restoredScreen)
        let restoredState = await restoredStore.navigation()
        XCTAssertNotEqual(restoredState.index.loadError, true)
        XCTAssertGreaterThanOrEqual(restoredState.index.revision, final.index.revision)
        XCTAssertEqual(restored.0.title, restored.1.title)
        DiskScanMetrics.write("DISK_NATIVE_REOPEN_COMPLETE elapsed=\(Date().timeIntervalSince(reopened)) revision=\(restoredState.index.revision)")
        await restoredModule.setActive(false)
    }
}
