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
            XCTAssertEqual(icon.frame.minX, title.frame.minX, accuracy: 0.1)
        }
    }

}
