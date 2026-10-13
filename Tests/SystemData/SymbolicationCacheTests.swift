import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceSystemData
@testable import MacSpaceSystemDataPrivileged

final class SymbolicationCacheTests: XCTestCase {
    /// coresymbolicationd as `pgrep` and `kill` see it: running with `pids` until a signal it heeds.
    final class FakeDaemon: CommandRunning, @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        var running: Int32? = 4242
        /// The signals it quits on.
        var quitsOn: Set<String> = ["-TERM"]
        func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
            lock.lock(); defer { lock.unlock() }
            calls.append([executable] + arguments)
            if executable.hasSuffix("pgrep") {
                XCTAssertEqual(arguments, ["-x", "coresymbolicationd"])
                return CommandResult(stdout: Data((running.map { "\($0)\n" } ?? "").utf8), stderr: Data(), exitCode: running == nil ? 1 : 0)
            }
            XCTAssertEqual(executable, "/bin/kill")
            if quitsOn.contains(arguments[0]) { running = nil }
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }
    }

    private func cache() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("symbols-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(count: 3_000_000).write(to: root.appendingPathComponent("data"))
        return root
    }

    func testEmptiesTheFolderThenStopsTheDaemonSoTheMappedArchiveGoes() throws {
        let folder = try cache()
        defer { try? FileManager.default.removeItem(at: folder) }
        let daemon = FakeDaemon()
        let result = SymbolicationCacheCleaner(cachePath: folder.path, runner: daemon, sleep: { _ in }).execute()
        XCTAssertTrue(result.executed)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.removedEntries, 1)
        XCTAssertTrue(result.daemonStopped)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the folder stays; the daemon starts a new cache in it")
        XCTAssertEqual(daemon.calls.filter { $0[0] == "/bin/kill" }, [["/bin/kill", "-TERM", "4242"]], "asked to quit, nothing harsher")
        XCTAssertGreaterThan(result.bytesBefore ?? 0, result.bytesAfter ?? .max)
    }

    func testADaemonThatIgnoresTheRequestIsMadeToQuit() throws {
        let folder = try cache()
        defer { try? FileManager.default.removeItem(at: folder) }
        let daemon = FakeDaemon()
        daemon.quitsOn = ["-KILL"]
        let result = SymbolicationCacheCleaner(cachePath: folder.path, runner: daemon, sleep: { _ in }).execute()
        XCTAssertTrue(result.daemonStopped)
        XCTAssertEqual(daemon.calls.filter { $0[0] == "/bin/kill" }.map { $0[1] }, ["-TERM", "-KILL"])
    }

    func testANotRunningDaemonIsLeftAlone() throws {
        let folder = try cache()
        defer { try? FileManager.default.removeItem(at: folder) }
        let daemon = FakeDaemon()
        daemon.running = nil
        let result = SymbolicationCacheCleaner(cachePath: folder.path, runner: daemon, sleep: { _ in }).execute()
        XCTAssertTrue(result.executed)
        XCTAssertFalse(result.daemonStopped)
        XCTAssertFalse(daemon.calls.contains { $0[0] == "/bin/kill" })
    }

    func testALinkInPlaceOfTheFolderIsRefused() throws {
        let folder = try cache()
        let link = folder.deletingLastPathComponent().appendingPathComponent("symbols-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let daemon = FakeDaemon()
        let result = SymbolicationCacheCleaner(cachePath: link.path, runner: daemon, sleep: { _ in }).execute()
        XCTAssertFalse(result.executed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("data").path), "what the link points to stays")
        XCTAssertTrue(daemon.calls.isEmpty)
    }

    func testALinkInsideIsRemovedNotFollowed() throws {
        let folder = try cache()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: outside) }
        try Data(count: 1_000).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("trap"), withDestinationURL: outside)
        _ = SymbolicationCacheCleaner(cachePath: folder.path, runner: FakeDaemon(), sleep: { _ in }).execute()
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: Page

    private func snapshot(bytes: UInt64, purgeable: UInt64 = 0) -> SystemDataSnapshot {
        var item = SystemDataItem(id: "cache:symbolication", title: "Symbols for crash reports", kind: .symbolCache,
                                  paths: ["/System/Library/Caches/com.apple.coresymbolicationd"], bytes: bytes, readable: true, owners: [], inUse: false,
                                  cleanup: SystemDataCleanup(kind: .managedByMacOS, description: "d", command: nil), notes: [])
        item.purgeableBytes = purgeable
        return SystemDataSnapshot(report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: [item], measuredBytes: 0, cleanableBytes: 0,
                                                           manualCleanup: [], unreadable: [], warnings: []),
                                  purgeableAssetsBytes: nil, reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []),
                                  takenAt: Date())
    }

    func testALargeCacheIsFreedWithItsOwnButtonNeverWithClean() throws {
        let snap = snapshot(bytes: 2_100_000_000)
        guard case let .section(free)? = SystemDataScreenBuilder.freeNow(snap), case let .list(list) = free.widgets[0] else { return XCTFail() }
        let row = try XCTUnwrap(list.rows.first { $0.id == "symbols" })
        XCTAssertEqual(row.title, "Symbols for crash reports")
        XCTAssertEqual(row.actions.map(\.id), ["deleteSymbolicationCache"])
        XCTAssertEqual(row.actions.first?.title, "Free")
        XCTAssertEqual(row.actions.first?.requires, [.privilegedHelper])
        XCTAssertTrue(row.badges.isEmpty, "a cache macOS rebuilds needs no pill")
        XCTAssertTrue(row.paths.isEmpty, "root's folder, which the Finder cannot open")
        XCTAssertEqual(SystemDataScreenBuilder.cleanBytes(snap), 0)
        XCTAssertEqual(SystemDataScreenBuilder.freeableBytes(snap), 2_100_000_000)
        XCTAssertFalse(SystemDataScreenBuilder.leftAlone(snap).contains { $0.id == "cache:symbolication" }, "listed once")
    }

    func testASmallOrPurgeableCacheStaysWithWhatMacOSManages() {
        XCTAssertNil(SystemDataScreenBuilder.symbolsRow(snapshot(bytes: 164_000)))
        XCTAssertNil(SystemDataScreenBuilder.symbolsRow(snapshot(bytes: 2_100_000_000, purgeable: 2_100_000_000)),
                     "what macOS marked purgeable is free space already")
    }
}
