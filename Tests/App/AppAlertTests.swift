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

    func testFinalDrawingPassRepairsNativeRecenteringForEveryAlertStyle() throws {
        _ = NSApplication.shared
        let messages = [
            ("Liberar os caches selecionados?", "Encerra Affinity."),
            ("Free?", "Cannot be undone."),
            ("Uninstall MacSpace?", "Restores settings changed by MacSpace and moves the app to the Trash."),
            ("MacSpace", "Version 1.1.1\n\nDeveloped by\nGio Mantovani/1architect"),
            ("選択したキャッシュを解放しますか？", "アプリを終了します。"),
            ("This copy of MacSpace is incomplete", String(repeating: "Copy the complete app again. ", count: 8))
        ]
        for style in [NSAlert.Style.informational, .warning, .critical] {
            for (title, message) in messages {
                let alert = AppAlert()
                alert.messageText = title
                alert.informativeText = message
                alert.alertStyle = style
                alert.addButton(withTitle: "Free")
                alert.addButton(withTitle: "Cancel")
                alert.layout()
                let content = try XCTUnwrap(alert.window.contentView)
                let labels = content.subviews.compactMap { $0 as? NSTextField }.filter { $0.stringValue == title || $0.stringValue == message }
                let icon = try XCTUnwrap(content.subviews.compactMap { $0 as? NSImageView }.first)
                XCTAssertEqual(labels.count, 2)
                for _ in 0..<2 {
                    // Reproduce native modal-entry layout changing both frames and paragraph alignment after alert.layout().
                    for label in labels {
                        label.frame.origin.x = 74
                        label.alignment = .center
                        let centered = NSMutableParagraphStyle()
                        centered.alignment = .center
                        let attributed = NSMutableAttributedString(attributedString: label.attributedStringValue)
                        attributed.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: attributed.length))
                        label.attributedStringValue = attributed
                    }
                    icon.frame.origin.x = 74
                    icon.imageAlignment = .alignCenter
                    content.layoutSubtreeIfNeeded()
                    for view in content.subviews { view.viewWillDraw() }
                    for label in labels {
                        XCTAssertEqual(label.frame.minX, 20, accuracy: 0.1)
                        XCTAssertEqual(label.frame.width, content.bounds.width - 40, accuracy: 0.1)
                        XCTAssertEqual(label.alignment, .left)
                        label.attributedStringValue.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: label.attributedStringValue.length)) { value, _, _ in
                            if let paragraph = value as? NSParagraphStyle { XCTAssertEqual(paragraph.alignment, .left) }
                        }
                    }
                    XCTAssertEqual(icon.frame.minX, 20, accuracy: 0.1)
                    XCTAssertEqual(icon.imageAlignment, .alignLeft)
                }
            }
        }
    }

}
