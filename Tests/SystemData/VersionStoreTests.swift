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
        func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
            lock.lock(); calls.append(arguments); lock.unlock()
            let fail = (arguments.first == "bootout" && failBootout) || (arguments.first == "bootstrap" && failBootstrap)
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: fail ? 1 : 0)
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
        let result = VersionStoreCleaner(storePath: root.path, runner: runner).execute()
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
        let result = VersionStoreCleaner(storePath: root.path, runner: runner).execute()
        XCTAssertFalse(result.executed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testFallsBackToKickstartAndReportsAFailedRestart() throws {
        let root = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner()
        runner.failBootstrap = true
        let result = VersionStoreCleaner(storePath: root.path, runner: runner).execute()
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
        XCTAssertNil(SystemDataScreenBuilder.managedSection(SystemDataSnapshot(report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: [item], measuredBytes: 0, cleanableBytes: 0, manualCleanup: [], unreadable: [], warnings: []), purgeableAssetsBytes: nil, reports: snap.reports, takenAt: Date()).report), "the managed list does not repeat it")
    }
}
