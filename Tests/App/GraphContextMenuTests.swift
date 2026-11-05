import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

final class GraphContextMenuTests: XCTestCase {
    func testReviewNavigationDoesNotAskForConfirmationBeforeOpeningThePage() throws {
        let action = Action(id: "reviewFile", title: "Review", parameters: ["reviewed": "original"], pageID: "review")
        let deletion = try XCTUnwrap(GraphMenuPolicy.deletion(action, label: "File.zip"))
        XCTAssertEqual(deletion.pageID, "review")
        XCTAssertEqual(deletion.parameters, action.parameters)
        XCTAssertNil(deletion.confirmation)
    }

    func testDeletionAlwaysHasADestructiveConfirmationAndKeepsItsReviewedTargetAndPermissions() throws {
        let original = Action(id: "deleteFile", title: "Remove", parameters: ["target": "reviewed"], requires: [.fullDiskAccess])
        let deletion = try XCTUnwrap(GraphMenuPolicy.deletion(original, label: "File.zip"))
        XCTAssertEqual(deletion.role, .destructive)
        XCTAssertEqual(deletion.title, "Delete")
        XCTAssertTrue(deletion.confirmation?.title.contains("File.zip") == true)
        XCTAssertEqual(deletion.parameters, original.parameters)
        XCTAssertEqual(deletion.requires, original.requires)
        var moduleAction = original
        moduleAction.confirmation = Confirmation(title: "Move to Trash?", message: "Only this reviewed file.", confirmTitle: "Move to Trash")
        XCTAssertEqual(GraphMenuPolicy.deletion(moduleAction, label: "File.zip")?.confirmation, moduleAction.confirmation)
        XCTAssertNil(GraphMenuPolicy.deletion(nil, label: "Protected data"))
    }
}
