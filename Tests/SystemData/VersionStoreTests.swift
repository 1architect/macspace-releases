import XCTest
import MacSpacePlatform
@testable import MacSpaceSystemData
@testable import MacSpaceSystemDataPrivileged

final class VersionStoreTests: XCTestCase {
    final class FakeRunner: CommandRunning, @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        var failBootout = false
        var failBootstrap = false
        var pids: [String] = ["4242"]
        func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
            lock.lock(); defer { lock.unlock() }
            calls.append(arguments)
            if executable.hasSuffix("pgrep") {
                let out = pids.isEmpty ? "" : pids.removeFirst() + "\n"
                return CommandResult(stdout: Data(out.utf8), stderr: Data(), exitCode: out.isEmpty ? 1 : 0)
            }
            let fail = (arguments.first == "bootout" && failBootout) || (arguments.first == "bootstrap" && failBootstrap)
            return CommandResult(stdout: Data(), stderr: Data(fail ? "Boot-out failed: 1: Operation not permitted".utf8 : "".utf8), exitCode: fail ? 1 : 0)
        }
    }

    private func store() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("versions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("PerUID/501"), withIntermediateDirectories: true)
        try Data(count: 3_000_000).write(to: root.appendingPathComponent("PerUID/501/chunk"))
        try Data(count: 1_000).write(to: root.appendingPathComponent("db.sqlite"))
        return root
    }

    func testStopsTheDaemonEmptiesTheStoreAndStartsItAgain() throws {
        let root = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner()
        let result = VersionStoreCleaner(storePath: root.path, runner: runner, sleep: { _ in }).execute()
        XCTAssertTrue(result.executed)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.removedEntries, 2)
        XCTAssertGreaterThan(result.bytesBefore ?? 0, 2_000_000)
        XCTAssertLessThan(result.bytesAfter ?? 1, 1_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "the folder itself stays")
        XCTAssertEqual(runner.calls.map { $0.first }, ["bootout", "bootstrap"])
        XCTAssertTrue(result.daemonRestarted)
    }

    func testNothingIsDeletedWhenTheDaemonCannotBeStopped() throws {
        let root = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner()
        runner.failBootout = true
        runner.pids = []
        let result = VersionStoreCleaner(storePath: root.path, runner: runner, sleep: { _ in }).execute()
        XCTAssertFalse(result.executed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
        XCTAssertTrue(result.error?.contains("Operation not permitted") == true, "the reason is shown")
    }

    func testFreezesTheRunningDaemonWhenMacOSWillNotUnloadIt() throws {
        let root = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner()
        runner.failBootout = true
        runner.pids = ["4242", "4242", "9999"]   // found, still the old one right after the kill, then the new one
        let result = VersionStoreCleaner(storePath: root.path, runner: runner, sleep: { _ in }).execute()
        XCTAssertTrue(result.executed)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.removedEntries, 2)
        XCTAssertTrue(result.daemonRestarted)
        let order = runner.calls.map { $0.joined(separator: " ") }
        XCTAssertEqual(order.filter { $0.hasPrefix("-STOP") || $0.hasPrefix("-KILL") }, ["-STOP 4242", "-KILL 4242"], "frozen before deleting, killed after")
    }

    func testFallsBackToKickstartAndReportsAFailedRestart() throws {
        let root = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner()
        runner.failBootstrap = true
        let result = VersionStoreCleaner(storePath: root.path, runner: runner, sleep: { _ in }).execute()
        XCTAssertEqual(runner.calls.map { $0.first }, ["bootout", "bootstrap", "kickstart"])
        XCTAssertTrue(result.daemonRestarted, "kickstart succeeded")
    }

    func testMissingStoreIsReportedNotCreated() {
        let result = VersionStoreCleaner(storePath: "/nonexistent-\(UUID().uuidString)", runner: FakeRunner()).execute()
        XCTAssertFalse(result.executed)
        XCTAssertNotNil(result.error)
    }

    func testScreenOffersTheDeletionOnlyWithAConfirmationAndTheHelperRequirement() throws {
        let item = SystemDataItem(id: "versions:documents", title: "v", kind: .documentVersions, paths: [], bytes: 6_000_000_000, readable: true, owners: [],
                                  inUse: false, cleanup: SystemDataCleanup(kind: .managedByMacOS, description: "d", command: nil), notes: [])
        var snap = SystemDataSnapshot(
            report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: [item], measuredBytes: 0, cleanableBytes: 0, manualCleanup: [], unreadable: [], warnings: []),
            purgeableAssetsBytes: nil, reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []), takenAt: Date())
        guard case let .section(section) = try XCTUnwrap(SystemDataScreenBuilder.versionsSection(snap)), case let .list(list) = section.widgets[0] else { return XCTFail() }
        let action = try XCTUnwrap(list.rows.first?.actions.first)
        XCTAssertEqual(action.id, "deleteVersions")
        XCTAssertEqual(action.role, .destructive)
        XCTAssertNotNil(action.confirmation)
        XCTAssertEqual(action.requires, [.privilegedHelper])
        snap.report.items = []
        XCTAssertNil(SystemDataScreenBuilder.versionsSection(snap))
        XCTAssertNil(SystemDataScreenBuilder.otherSection(SystemDataSnapshot(report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: [item], measuredBytes: 0, cleanableBytes: 0, manualCleanup: [], unreadable: [], warnings: []), purgeableAssetsBytes: nil, reports: snap.reports, takenAt: Date())), "the other list does not repeat it")
    }
}
