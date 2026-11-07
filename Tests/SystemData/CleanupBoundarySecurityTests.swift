import XCTest
@testable import MacSpaceSystemData

final class CleanupBoundarySecurityTests: XCTestCase {
    func testReportReplacementAfterPlanningIsPreservedEvenWhenOldEnough() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appendingPathComponent("report.spin"), now = Date(), old = now.addingTimeInterval(-10 * 86_400)
        try Data("original".utf8).write(to: report)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: report.path)
        let cleaner = DiagnosticReportCleaner(directories: [folder.path]), plan = cleaner.plan(olderThanDays: 7, now: now)
        try FileManager.default.moveItem(at: report, to: folder.appendingPathComponent("original"))
        try Data("replacement".utf8).write(to: report)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: report.path)
        let result = cleaner.execute(plan)
        XCTAssertTrue(result.deleted.isEmpty); XCTAssertNotNil(result.failed[report.path])
        XCTAssertEqual(try Data(contentsOf: report), Data("replacement".utf8))
    }
    func testTrashUnlinksTopLevelSymlinkWithoutTouchingItsDestination() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trash = folder.appendingPathComponent("Trash"), original = folder.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("preserved".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: trash.appendingPathComponent("link"), withDestinationURL: original)
        let result = SystemDataModule.emptyTrash(trash: trash)
        XCTAssertNotEqual(result.outcome, .failed)
        XCTAssertEqual(try Data(contentsOf: original), Data("preserved".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
    }
}
