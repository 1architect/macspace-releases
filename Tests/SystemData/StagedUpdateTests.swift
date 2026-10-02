import XCTest
@testable import MacSpaceSystemData
@testable import MacSpaceSystemDataPrivileged

final class StagedUpdateTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("staged-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("install/UpdateBundle"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("install/Locked Files"), withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: root.appendingPathComponent("install/UpdateBundle/pkg"))
        try Data(count: 100).write(to: root.appendingPathComponent("install/index.sproduct"))
        try Data(count: 10).write(to: root.appendingPathComponent("SystemVersion.plist"))
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func cleaner(stagedAge: Double, systemAge: Double) throws -> StagedUpdateCleaner {
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -stagedAge * 86_400)], ofItemAtPath: root.appendingPathComponent("install").path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -systemAge * 86_400)], ofItemAtPath: root.appendingPathComponent("SystemVersion.plist").path)
        return StagedUpdateCleaner(storePath: root.appendingPathComponent("install").path, systemVersionPath: root.appendingPathComponent("SystemVersion.plist").path)
    }

    func testDeletesTheLeftoverAndKeepsTheProtectedFolder() throws {
        let result = try cleaner(stagedAge: 90, systemAge: 5).execute()
        XCTAssertTrue(result.executed)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.removedEntries, 2)
        XCTAssertGreaterThan(result.bytesBefore ?? 0, 1_900_000)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("install/UpdateBundle").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("install/Locked Files").path), "the protected folder stays")
    }

    func testRefusesWhenTheFilesAreNotOlderThanTheInstalledSystem() throws {
        let result = try cleaner(stagedAge: 2, systemAge: 30).execute()
        XCTAssertFalse(result.executed, "an update may be waiting")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("install/UpdateBundle/pkg").path))
    }

    func testMissingFolderIsReported() {
        let result = StagedUpdateCleaner(storePath: "/nonexistent-\(UUID().uuidString)").execute()
        XCTAssertFalse(result.executed)
    }

    func testScreenOffersTheDeletionOnlyForALeftover() throws {
        func snapshot(_ cleanup: SystemDataCleanup.Kind) -> SystemDataSnapshot {
            let item = SystemDataItem(id: "update:staged", title: "t", kind: .stagedUpdate, paths: [], bytes: 1_270_000_000, readable: true, owners: [], inUse: false,
                                      cleanup: SystemDataCleanup(kind: cleanup, description: "d", command: nil), notes: [])
            return SystemDataSnapshot(report: SystemDataReport(schemaVersion: 1, generatedAt: Date(), volumes: [], items: [item], measuredBytes: 0, cleanableBytes: 0,
                                                               manualCleanup: [], unreadable: [], warnings: []),
                                      purgeableAssetsBytes: nil, reports: CleanupPlan(olderThanDays: 7, cutoff: .distantPast, candidates: [], totalBytes: 0, unreadableDirectories: []),
                                      takenAt: Date())
        }
        guard case let .section(section) = try XCTUnwrap(SystemDataScreenBuilder.leftoverUpdateSection(snapshot(.managedByMacOS))), case let .list(list) = section.widgets[0] else { return XCTFail() }
        let action = try XCTUnwrap(list.rows.first?.actions.first)
        XCTAssertEqual(action.id, "deleteStagedUpdate")
        XCTAssertEqual(action.requires, [.privilegedHelper])
        XCTAssertNotNil(action.confirmation)
        XCTAssertNil(SystemDataScreenBuilder.leftoverUpdateSection(snapshot(.review)), "a waiting update is never offered for deletion")
    }
}
