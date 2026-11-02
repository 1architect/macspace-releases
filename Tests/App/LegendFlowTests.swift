import AppKit
import SwiftUI
import XCTest
@testable import MacSpaceApp

final class LegendFlowTests: XCTestCase {
    func testWholeEntriesWrapWithoutEqualWidthCompression() {
        let sizes = [CGSize(width: 210, height: 15), CGSize(width: 310, height: 15), CGSize(width: 180, height: 15)]
        let layout = LegendFlowLayout.placement(sizes: sizes, width: 550)
        XCTAssertEqual(layout.frames[0], CGRect(x: 0, y: 0, width: 210, height: 15))
        XCTAssertEqual(layout.frames[1], CGRect(x: 230, y: 0, width: 310, height: 15))
        XCTAssertEqual(layout.frames[2], CGRect(x: 0, y: 20, width: 180, height: 15))
        XCTAssertEqual(layout.size.height, 35)
    }

    func testOversizeEntryGetsOneWholeRowAndKeepsOneLineOfHeight() {
        let layout = LegendFlowLayout.placement(sizes: [CGSize(width: 650, height: 15), CGSize(width: 100, height: 15)], width: 420)
        XCTAssertEqual(layout.frames[0].size, CGSize(width: 420, height: 15))
        XCTAssertEqual(layout.frames[1].minY, 20)
        XCTAssertEqual(layout.size.height, 35)
        XCTAssertEqual(LegendFlowLayout.placement(sizes: [], width: 420).size.height, 0)
    }
}
