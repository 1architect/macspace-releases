import SwiftUI
import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

final class ZoomMathTests: XCTestCase {
    func testRampIsFlatOutsideItsRangeAndMonotonicInside() {
        XCTAssertEqual(ZoomMath.ramp(0, 0.2, 0.7), 0)
        XCTAssertEqual(ZoomMath.ramp(1, 0.2, 0.7), 1)
        XCTAssertEqual(ZoomMath.ramp(0.45, 0.2, 0.7), 0.5, accuracy: 0.0001)
        XCTAssertLessThan(ZoomMath.ramp(0.3, 0.2, 0.7), ZoomMath.ramp(0.5, 0.2, 0.7))
    }

    func testRectInterpolatesFromTileToWindow() {
        let tile = CGRect(x: 100, y: 200, width: 400, height: 300)
        let window = CGRect(x: 0, y: 0, width: 1000, height: 700)
        XCTAssertEqual(ZoomMath.rect(from: tile, to: window, progress: 0), tile)
        XCTAssertEqual(ZoomMath.rect(from: tile, to: window, progress: 1), window)
        XCTAssertEqual(ZoomMath.rect(from: tile, to: window, progress: 0.5), CGRect(x: 50, y: 100, width: 700, height: 500))
    }

    func testHeroIsTheWidgetWithTheSummarysId() {
        let screen = Screen(title: "T", widgets: [.banner(Banner(id: "partial", severity: .info, title: "x")),
                                                  .usage(UsageBar(id: "usage", title: "U", segments: [])),
                                                  .text(TextWidget(id: "t", text: "t"))])
        let summary = ScreenWidget.usage(UsageBar(id: "usage", title: "System Data", segments: []))
        XCTAssertEqual(ZoomMath.heroIndex(in: screen, summary: summary), 1)
    }

    func testHeroFallsBackToTheFirstWidgetOfTheSameKindThenTheFirst() {
        let screen = Screen(title: "T", widgets: [.text(TextWidget(id: "t", text: "t")), .banner(Banner(id: "status", severity: .info, title: "x"))])
        XCTAssertEqual(ZoomMath.heroIndex(in: screen, summary: .banner(Banner(id: "summary", severity: .info, title: "s"))), 1)
        XCTAssertEqual(ZoomMath.heroIndex(in: screen, summary: .usage(UsageBar(id: "u", title: "U", segments: []))), 0)
        XCTAssertEqual(ZoomMath.heroIndex(in: screen, summary: nil), 0)
        XCTAssertNil(ZoomMath.heroIndex(in: Screen(title: "T", widgets: []), summary: nil))
    }
}
