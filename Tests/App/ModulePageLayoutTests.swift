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
        XCTAssertEqual(ModulePageLayout.metrics(availableWidth: 1200 - 2 * PageInsets.side).columns, 2)
        XCTAssertEqual(ModulePageLayout.metrics(availableWidth: 1800 - 2 * PageInsets.side).columns, 3)
    }

    func testNewColumnOnlyAppearsWhenEveryColumnHasRoom() {
        for count in 2...3 {
            let canvas = CGFloat(count) * ModulePageLayout.minimumColumnWidth
                + CGFloat(count - 1) * ModulePageLayout.gap
            let threshold = canvas / 0.8 - 2 * PageInsets.side
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

    func testSmallWindowsStackUntilBothSidesHaveReadableRoom() throws {
        for width: CGFloat in [520, 678, 700, 780, 900, ModulePageLayout.minimumSideViewportWidth - 1] {
            XCTAssertNil(ModulePageLayout.graphArrangement(viewport: CGSize(width: width, height: 1200), hasGraph: true))
        }
        XCTAssertNil(ModulePageLayout.graphArrangement(viewport: CGSize(width: 2090, height: 1140), hasGraph: false))
        for width: CGFloat in [ModulePageLayout.minimumSideViewportWidth, 1045, 1448, 2090] {
            let layout = try XCTUnwrap(ModulePageLayout.graphArrangement(viewport: CGSize(width: width, height: 1140), hasGraph: true))
            XCTAssertEqual(layout.contentWidth, width - 2 * PageInsets.side)
            XCTAssertEqual(layout.listWidth + ModulePageLayout.gap + layout.graphWidth, layout.contentWidth, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(layout.listWidth, 440)
            XCTAssertGreaterThanOrEqual(layout.graphWidth, 420)
            XCTAssertLessThanOrEqual(layout.listWidth, ModulePageLayout.maximumSingleColumnWidth)
            XCTAssertTrue(layout.graphHeight.isFinite)
        }
        let full = try XCTUnwrap(ModulePageLayout.graphArrangement(viewport: CGSize(width: 1448, height: 1140), hasGraph: true))
        XCTAssertEqual(full.listWidth / full.contentWidth, 0.34, accuracy: 0.001)
        XCTAssertNil(ModulePageLayout.graphArrangement(viewport: CGSize(width: CGFloat.infinity, height: 900), hasGraph: true))
    }

    func testChartHeightIsBoundedAndDoesNotDependOnWindowHeight() {
        XCTAssertEqual(ModulePageLayout.chartHeight(width: 1200, columns: 3), 294, accuracy: 0.001)
        XCTAssertEqual(ModulePageLayout.chartHeight(width: 1608, columns: 3), 390)
        XCTAssertEqual(ModulePageLayout.chartHeight(width: 820, columns: 1), 150)
    }
    func testLargeFileOverviewUsesFreeHeightAndReservesNavigationAndDock() {
        XCTAssertEqual(ModulePageLayout.overviewCapacity(viewportHeight: 900, rowsTop: 160, top: 20, bottom: 80, navigation: true), 15)
        XCTAssertEqual(ModulePageLayout.overviewCapacity(viewportHeight: 490, rowsTop: 350, top: 20, bottom: 80, navigation: true), 5)
        XCTAssertEqual(ModulePageLayout.overviewCapacity(viewportHeight: 1200, rowsTop: 160, top: 20, bottom: 80, navigation: true), 23)
    }

}
