import AppKit
import XCTest
@testable import MacSpaceApp

@MainActor
final class WindowPresenceTests: XCTestCase {
    func testStatusWindowsDoNotRestoreForegroundPresence() {
        _ = NSApplication.shared
        let status = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        XCTAssertFalse(BackgroundPresence.isAppWindow(status))
        let canvas = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        canvas.identifier = NSUserInterfaceItemIdentifier(MacSpaceWindow.glass)
        XCTAssertTrue(BackgroundPresence.isAppWindow(canvas))
        let settings = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
        XCTAssertTrue(BackgroundPresence.isAppWindow(settings))
    }
}
