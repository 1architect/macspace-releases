import XCTest
@testable import MacSpaceApp

final class TileCaptionTests: XCTestCase {
    private let info = TileInfo(title: "outros arquivos do sistema", figure: "2,46 GB", status: "liberar até 748,8 MB")

    /// Where the title and its figure fit, they share a line; where they do not, the title may take two lines and the figure goes
    /// under it. The text is never shrunk, so the chart is given less room instead.
    func testTheFigureGoesUnderTheTitleWhereTheyDoNotFitOnOneLine() {
        let wide = CaptionLayout(info: info, size: 22, width: 800)
        XCTAssertTrue(wide.oneLine)
        XCTAssertEqual(wide.lines, 1)
        XCTAssertEqual(wide.extraHeight, 0)
        let narrow = CaptionLayout(info: info, size: 16, width: 200)
        XCTAssertFalse(narrow.oneLine)
        XCTAssertGreaterThanOrEqual(narrow.lines, 2)
        XCTAssertGreaterThan(narrow.extraHeight, 0)
        XCTAssertLessThanOrEqual(narrow.titleWidth, 200)
        let noFigure = CaptionLayout(info: TileInfo(title: "debloat", status: "12/12"), size: 16, width: 200)
        XCTAssertTrue(noFigure.oneLine)
    }

    /// Every block of a chart has the smallest block's corners.
    func testEveryBlockHasTheSmallestBlocksCorners() {
        let rects = [CGRect(x: 0, y: 0, width: 140, height: 70), CGRect(x: 0, y: 0, width: 20, height: 18), .zero]
        XCTAssertEqual(BlocksView.radius(for: rects), BlocksView.radius(rects[1]))
        XCTAssertEqual(BlocksView.radius(for: []), 6)
    }

    /// On a small tile, a caption that takes more lines takes only the room they need: the chart keeps its minimum height, and the
    /// legend gives way rather than squeeze it. The figure, title and status were added on top of a fixed band, and the blocks of
    /// Other System Files came out as thin lines (2026-10-12).
    func testASmallTileKeepsItsChart() {
        let blocks = TileInfo(title: "outros arquivos do sistema", figure: "2,46 GB", status: "liberar até 748,8 MB",
                              graphic: .blocks([]))
        for size in [CGSize(width: 215, height: 150), CGSize(width: 230, height: 165), CGSize(width: 260, height: 190)] {
            let captionSize = CaptionSize.tile(height: size.height)
            let area = TileFace.chartArea(in: size, info: blocks, captionSize: captionSize)
            XCTAssertGreaterThanOrEqual(area.height, TileFace.minimumChartHeight, "\(size)")
        }
        // A caption on one line leaves the chart as before.
        let wide = CGSize(width: 900, height: 330)
        XCTAssertEqual(TileFace.captionHeight(in: wide, info: blocks, captionSize: 22), TileFace.captionBand)
    }
}
