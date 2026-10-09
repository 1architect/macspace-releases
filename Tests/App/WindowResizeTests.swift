import AppKit
import XCTest
@testable import MacSpaceApp

@MainActor
final class WindowResizeTests: XCTestCase {
    private let bounds = NSRect(x: 0, y: 0, width: 700, height: 500)

    func testAllEdgesAndCornersAndInteriorHitTargets() {
        let cases: [(NSPoint, WindowResizeEdge)] = [
            (.init(x: 1, y: 250), .left), (.init(x: 699, y: 250), .right),
            (.init(x: 350, y: 1), .bottom), (.init(x: 350, y: 499), .top),
            (.init(x: 1, y: 20), [.left, .bottom]), (.init(x: 680, y: 1), [.right, .bottom]),
            (.init(x: 20, y: 499), [.left, .top]), (.init(x: 699, y: 480), [.right, .top]),
            (.init(x: 350, y: 250), []), (.init(x: 20, y: 20), []),
            (.init(x: -1, y: 200), []), (.init(x: 701, y: 200), [])
        ]
        for (point, expected) in cases {
            XCTAssertEqual(WindowResizeEdge.target(at: point, in: bounds, band: 12, corner: 28), expected, "\(point)")
        }
    }

    func testResizeKeepsOppositeEdgesFixedWhenClamped() {
        let original = NSRect(x: -900, y: 100, width: 700, height: 500)
        let edges: [WindowResizeEdge] = [.left, .right, .top, .bottom, [.left, .top], [.right, .top], [.left, .bottom], [.right, .bottom]]
        for edge in edges {
            for amount: CGFloat in [-2000, 2000] {
                let resized = edge.frame(from: original, delta: .init(x: amount, y: amount),
                                         minimum: .init(width: 520, height: 360), maximum: .init(width: 1000, height: 800))
                XCTAssertTrue((520...1000).contains(resized.width))
                XCTAssertTrue((360...800).contains(resized.height))
                if edge.contains(.left) { XCTAssertEqual(resized.maxX, original.maxX) }
                else { XCTAssertEqual(resized.minX, original.minX) }
                if edge.contains(.bottom) { XCTAssertEqual(resized.maxY, original.maxY) }
                else { XCTAssertEqual(resized.minY, original.minY) }
                if !edge.contains(.left), !edge.contains(.right) { XCTAssertEqual(resized.width, original.width) }
                if !edge.contains(.top), !edge.contains(.bottom) { XCTAssertEqual(resized.height, original.height) }
            }
        }
    }

    func testMouseEventsResizeWithoutPollingTheGlobalCursor() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentMinSize = NSSize(width: 520, height: 360)
        let overlay = WindowResizeView(frame: bounds)
        window.contentView = overlay
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let original = window.frame
        overlay.mouseDown(with: event(.leftMouseDown, .init(x: 695, y: 250)))
        overlay.mouseDragged(with: event(.leftMouseDragged, .init(x: 615, y: 250)))
        XCTAssertEqual(window.frame.width, original.width - 80)
        XCTAssertEqual(window.frame.origin, original.origin)
        overlay.mouseUp(with: event(.leftMouseUp, .init(x: 615, y: 250)))
        overlay.mouseDragged(with: event(.leftMouseDragged, .init(x: 595, y: 250)))
        XCTAssertEqual(window.frame.width, original.width - 80)
    }

    func testOverlayPassesControlsThroughAndAcceptsInactiveWindowClicks() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: bounds)
        let overlay = WindowResizeView(frame: bounds)
        window.contentView = root
        root.addSubview(overlay)
        XCTAssertTrue(overlay.hitTest(.init(x: 10, y: 250)) === overlay)
        XCTAssertNil(overlay.hitTest(.init(x: 350, y: 250)))
        XCTAssertNil(overlay.hitTest(.init(x: 28, y: 472)))
        XCTAssertTrue(overlay.acceptsFirstMouse(for: nil))
        XCTAssertFalse(overlay.mouseDownCanMoveWindow)
        window.styleMask.remove(.resizable)
        XCTAssertNil(overlay.hitTest(.init(x: 10, y: 250)))
    }
}
