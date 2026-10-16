import AppKit
import XCTest
@testable import MacSpaceApp

@MainActor
final class AboutMacSpaceTests: XCTestCase {
    func testAboutMatchesMacBatContentAndKeepsAllAuthorLines() {
        _ = NSApplication.shared
        let alert = AboutMacSpace.makeAlert()
        alert.layout()
        XCTAssertEqual(alert.messageText, "MacSpace")
        XCTAssertTrue(alert.informativeText.contains("\n\n"))
        XCTAssertTrue(alert.informativeText.contains("Gio Mantovani/1architect"))
        XCTAssertEqual(alert.buttons.count, 3)
        XCTAssertTrue(alert.buttons[1].hasDestructiveAction)
        let description = alert.window.contentView!.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == alert.informativeText }!
        XCTAssertEqual(description.maximumNumberOfLines, 0, "the author must not be truncated to two lines")
        XCTAssertEqual(description.alignment, .left)
    }
}
