import XCTest
@testable import MacSpaceApp

@MainActor
final class UninstallTests: XCTestCase {
    func testRestorationFailureKeepsHelperAndApp() async {
        var calls: [String] = []
        do {
            try await AppUninstaller.run([
                { calls.append("restore"); throw AppUninstaller.Failure(message: "restore failed") },
                { calls.append("unregister") },
                { calls.append("trash") }
            ])
            XCTFail("must propagate restoration failure")
        } catch { XCTAssertEqual(error.localizedDescription, "restore failed") }
        XCTAssertEqual(calls, ["restore"])
    }

    func testRemovalRunsOnlyAfterRestorationAndHelperRemoval() async throws {
        var calls: [String] = []
        try await AppUninstaller.run([
            { calls.append("restore") },
            { calls.append("unregister") },
            { calls.append("trash") }
        ])
        XCTAssertEqual(calls, ["restore", "unregister", "trash"])
    }
}
