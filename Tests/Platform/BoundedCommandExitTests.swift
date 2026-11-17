import Foundation
import XCTest
import MacSpacePlatform

final class BoundedCommandExitTests: XCTestCase {
    func testExitStatusAndCapturedOutputSurvivePipesClosingBeforeTheProcessExits() {
        for status in [0, 17, 43] {
            let result = BoundedCommand.run("/bin/sh", arguments: ["-c",
                "printf output; printf diagnostic >&2; exec 1>&- 2>&-; sleep 0.02; exit \(status)"],
                environment: ["PATH": "/usr/bin:/bin"], timeout: 2)
            XCTAssertEqual(result.status, Int32(status))
            XCTAssertEqual(result.stdout, Data("output".utf8))
            XCTAssertEqual(result.stderr, Data("diagnostic".utf8))
            XCTAssertFalse(result.timedOut)
            XCTAssertFalse(result.truncated)
        }
    }

    func testClosedPipesDoNotHideTheOwnedProcessDeadline() {
        let started = Date()
        let result = BoundedCommand.run("/bin/sh", arguments: ["-c", "exec 1>&- 2>&-; sleep 5"],
            environment: ["PATH": "/usr/bin:/bin"], timeout: 0.3)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, -2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}
