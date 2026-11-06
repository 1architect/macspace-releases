import AppKit
import XCTest
@testable import MacSpaceApp

@MainActor
final class AppRouterTests: XCTestCase {
    func testFirstClickWaitsForSceneRegistrationAndRepeatedClicksOpenOnce() {
        var preparations = 0
        var opened: [String] = []
        let router = AppRouter(findWindow: { nil }, prepareForOpening: { preparations += 1 }, presentWindow: { _ in
            XCTFail("there is no retained window")
        })

        router.open()
        router.open()
        XCTAssertTrue(router.isOpeningWindow, "background handling must preserve foreground presence while waiting")
        XCTAssertEqual(preparations, 1)
        router.registerWindowOpener { opened.append($0) }
        router.open()
        router.registerWindowOpener { opened.append($0) }
        XCTAssertEqual(opened, [MacSpaceWindow.glass], "registration and repeated clicks share the first request")
        XCTAssertTrue(router.isOpeningWindow, "opening the scene does not mean its window is visible yet")

        router.windowDidAppear()
        XCTAssertFalse(router.isOpeningWindow)
    }

    func testAnOpenerRegisteredAtLaunchWorksBeforeAnyWindowHasAppeared() {
        var opened: [String] = []
        let router = AppRouter(findWindow: { nil }, prepareForOpening: {}, presentWindow: { _ in XCTFail() })
        router.registerWindowOpener { opened.append($0) }
        XCTAssertTrue(opened.isEmpty, "registration alone must not open a window at launch")

        router.open(.settings)
        XCTAssertEqual(opened, [MacSpaceWindow.glass])
        XCTAssertEqual(router.take(), .settings)
        router.windowDidAppear()
        router.open(.storage)
        XCTAssertEqual(opened, [MacSpaceWindow.glass, MacSpaceWindow.glass])
        XCTAssertEqual(router.take(), .storage)
    }

    func testLatestDestinationAndPageSurviveClicksWhileTheWindowIsOpening() {
        var presentations = 0
        let router = AppRouter(findWindow: { nil }, prepareForOpening: {}, presentWindow: { _ in XCTFail() })
        router.registerWindowOpener { _ in presentations += 1 }
        router.open(.settings)
        router.open(.module("test.module"), page: "details")

        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(router.request?.destination, .module("test.module"))
        XCTAssertEqual(router.take(), .module("test.module"))
        XCTAssertEqual(router.takePage(), "details")
        XCTAssertNil(router.take())
        XCTAssertNil(router.takePage())
    }

    func testAnOrderedOutWindowIsReusedWithoutOpeningAnotherScene() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier(MacSpaceWindow.glass)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(AppRouter.isMainWindow(window))
        var prepared = false
        var presented: NSWindow?
        let router = AppRouter(findWindow: { window }, prepareForOpening: { prepared = true }, presentWindow: {
            XCTAssertTrue(prepared)
            presented = $0
        })
        router.registerWindowOpener { _ in XCTFail("reuse the hidden scene window") }

        router.open(.settings)
        XCTAssertTrue(presented === window)
        XCTAssertFalse(router.isOpeningWindow)
        XCTAssertEqual(router.take(), .settings)
    }
}
