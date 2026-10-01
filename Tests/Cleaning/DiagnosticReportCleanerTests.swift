import XCTest
@testable import MacSpaceCleaning

final class DiagnosticReportCleanerTests: XCTestCase {
    func testPlansOnlyOldRegularReportFilesAndDeletesThem() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macspace-reports-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func file(_ name: String, bytes: Int, ageDays: Double) throws -> String {
            let path = root.appendingPathComponent(name).path
            try Data(count: bytes).write(to: URL(fileURLWithPath: path))
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: path)
            return path
        }
        let oldSpin = try file("App_1.spin", bytes: 300, ageDays: 10)
        let oldIps = try file("App_2.ips", bytes: 100, ageDays: 8)
        _ = try file("App_3.spin", bytes: 500, ageDays: 1)
        _ = try file("notes.txt", bytes: 50, ageDays: 30)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link.spin").path, withDestinationPath: oldSpin)

        let cleaner = DiagnosticReportCleaner(directories: [root.path, root.appendingPathComponent("missing").path])
        let plan = cleaner.plan(olderThanDays: 7, now: now)
        XCTAssertEqual(plan.candidates.map(\.path), [oldSpin, oldIps], "largest first; recent, non-report and symlink files excluded")
        XCTAssertEqual(plan.totalBytes, 400)
        XCTAssertTrue(plan.unreadableDirectories.isEmpty, "a missing directory is not an unreadable one")

        try fm.removeItem(atPath: oldIps) // removed between plan and execute
        let result = cleaner.execute(plan)
        XCTAssertEqual(result.deleted, [oldSpin])
        XCTAssertEqual(result.freedBytes, 300)
        XCTAssertNotNil(result.failed[oldIps])
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("App_3.spin").path))
    }
}
