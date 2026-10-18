import AppKit
import XCTest
@testable import MacSpaceApp

@MainActor
final class AppAlertTests: XCTestCase {
    func testEveryLayoutPassKeepsIconAndTextOnTheSameLeadingEdge() {
        _ = NSApplication.shared
        let alert = AppAlert()
        alert.messageText = "Free 200 MB?"
        alert.informativeText = "Cannot be undone."
        alert.addButton(withTitle: "Free")
        alert.addButton(withTitle: "Cancel")
        for _ in 0..<2 {
            alert.layout()
            let views = alert.window.contentView!.subviews
            let title = views.compactMap { $0 as? NSTextField }.first { $0.stringValue == alert.messageText }!
            let icon = views.compactMap { $0 as? NSImageView }.first!
            XCTAssertEqual(title.alignment, .left)
            XCTAssertEqual(title.frame.minX, 20, accuracy: 0.1)
            XCTAssertEqual(title.frame.width, alert.window.contentView!.bounds.width - 40, accuracy: 0.1)
            XCTAssertEqual(icon.frame.minX, title.frame.minX, accuracy: 0.1)
        }
    }

    func testCacheConfirmationKeepsItsFullMessageOnTheSameLeftEdge() {
        _ = NSApplication.shared
        let alert = AppAlert()
        alert.messageText = "Free selected 250 MB?"
        alert.informativeText = "Quits Enscape and WhatsApp."
        alert.addButton(withTitle: "Free")
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        let labels = alert.window.contentView!.subviews.compactMap { $0 as? NSTextField }.filter { $0.stringValue == alert.messageText || $0.stringValue == alert.informativeText }
        XCTAssertEqual(labels.count, 2)
        for label in labels { XCTAssertEqual(label.frame.minX, 20, accuracy: 0.1); XCTAssertEqual(label.alignment, .left) }
    }

}
