import CoreGraphics
import XCTest
@testable import MacSpaceApp

final class ModulePageLayoutTests: XCTestCase {
    func testCurrentCompactWindowKeepsItsSingleColumn() {
        let layout = ModulePageLayout.metrics(availableWidth: 700 - 2 * PageInsets.side)
        XCTAssertEqual(layout.columns, 1)
        XCTAssertEqual(layout.contentWidth, 640)
        XCTAssertEqual(ModulePageLayout.chartHeight(width: layout.columnWidth, columns: layout.columns), 150)
    }

    func testMediumAndFullWidthWindowsReflowWholeSections() {
        XCTAssertEqual(ModulePageLayout.metrics(availableWidth: 1000 - 2 * PageInsets.side).columns, 2)
        XCTAssertEqual(ModulePageLayout.metrics(availableWidth: 1440 - 2 * PageInsets.side).columns, 3)
    }

    func testNewColumnOnlyAppearsWhenEveryColumnHasRoom() {
        for count in 2...3 {
            let threshold = CGFloat(count) * ModulePageLayout.minimumColumnWidth
                + CGFloat(count - 1) * ModulePageLayout.gap
            XCTAssertEqual(ModulePageLayout.metrics(availableWidth: threshold - 1).columns, count - 1)
            let layout = ModulePageLayout.metrics(availableWidth: threshold)
            XCTAssertEqual(layout.columns, count)
            XCTAssertEqual(layout.columnWidth, ModulePageLayout.minimumColumnWidth)
        }
    }

    func testUltrawideWindowsStopStretchingRows() {
        let layout = ModulePageLayout.metrics(availableWidth: 3380)
        XCTAssertEqual(layout.columns, 3)
        XCTAssertEqual(layout.columnWidth, ModulePageLayout.maximumColumnWidth)
        XCTAssertLessThan(layout.contentWidth, 3380)
    }

    func testDrillDownStaysOneReadableListEvenOnALargeDisplay() {
        let layout = ModulePageLayout.metrics(availableWidth: 2500, maximumColumns: 1)
        XCTAssertEqual(layout.columns, 1)
        XCTAssertEqual(layout.contentWidth, ModulePageLayout.maximumSingleColumnWidth)
    }

    func testInitialAndInvalidGeometryNeverProducesNegativeOrInfiniteSizes() {
        let widths: [CGFloat] = [-1, 0, .infinity, .nan]
        for width in widths {
            let layout = ModulePageLayout.metrics(availableWidth: width)
            XCTAssertTrue(layout.contentWidth.isFinite)
            XCTAssertGreaterThanOrEqual(layout.columnWidth, 0)
        }
    }

    func testChartHeightIsBoundedAndDoesNotDependOnWindowHeight() {
        XCTAssertEqual(ModulePageLayout.chartHeight(width: 420, columns: 3), 231, accuracy: 0.001)
        XCTAssertEqual(ModulePageLayout.chartHeight(width: 480, columns: 3), 240)
        XCTAssertEqual(ModulePageLayout.chartHeight(width: 820, columns: 1), 150)
    }
}
