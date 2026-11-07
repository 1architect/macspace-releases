import XCTest
@testable import MacSpacePlatform

final class TemporaryOwnerCleanupTests: XCTestCase {
    private enum Failure: Error { case preparation, reply, cleanup }

    func testLaterPreparationFailureWithdrawsEarlierSubmission() {
        var withdrawn: [String] = []
        XCTAssertThrowsError(try AssetOwners.withTemporaryOwners(withdraw: { withdrawn = $0 }) { register in
            register("first")
            throw Failure.preparation
        }) { XCTAssertEqual($0 as? Failure, .preparation) }
        XCTAssertEqual(withdrawn, ["first"])
    }

    func testMissingReplyStillWithdrawsTheSubmittedOwner() {
        var withdrawn: [String] = []
        XCTAssertThrowsError(try AssetOwners.withTemporaryOwners(withdraw: { withdrawn = $0 }) { register in
            register("first")
            register("unconfirmed")
            throw Failure.reply
        }) { XCTAssertEqual($0 as? Failure, .reply) }
        XCTAssertEqual(withdrawn, ["first", "unconfirmed"])
    }

    func testCleanupCompletesBeforeReturningSuccess() throws {
        var events: [String] = []
        try AssetOwners.withTemporaryOwners(withdraw: { (owners: [String]) in events += owners.map { "withdraw:" + $0 } }) { register in
            register("first")
            events.append("body")
        }
        XCTAssertEqual(events, ["body", "withdraw:first"])
    }

    func testUnconfirmedCleanupCannotReportSuccess() {
        XCTAssertThrowsError(try AssetOwners.withTemporaryOwners(withdraw: { (_: [String]) in throw Failure.cleanup }) { register in
            register("first")
        }) { XCTAssertEqual($0 as? Failure, .cleanup) }
    }

    func testNoSubmissionDoesNotCallCleanup() throws {
        try AssetOwners.withTemporaryOwners(withdraw: { (_: [String]) in XCTFail("No owner was submitted") }) { _ in }
    }
}
