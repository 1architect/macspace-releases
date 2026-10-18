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
            let captionSize = CaptionSize.tile(height: size.height, large: false)
            let area = TileFace.chartArea(in: size, info: blocks, captionSize: captionSize)
            XCTAssertGreaterThanOrEqual(area.height, TileFace.minimumChartHeight, "\(size)")
        }
        // A caption on one line leaves the chart as before.
        let wide = CGSize(width: 900, height: 330)
        XCTAssertEqual(TileFace.captionHeight(in: wide, info: blocks, captionSize: 22), TileFace.captionBand)
    }

    /// A switch tile's detail wraps onto a second line, at its size, before it folds away (2026-10-13: it folded away on a 230-point tile).
    func testASwitchTilesDetailWrapsBeforeItFolds() {
        let detail = "367,3 MB de modelos mantidos pelo macOS"
        XCTAssertTrue(StateView.detailFits(detail, width: 206), "two lines")
        XCTAssertTrue(StateView.detailFits(detail, width: 400), "one line")
        XCTAssertFalse(StateView.detailFits(detail, width: 60), "more than two lines: folded")
    }

    /// Resizing the window changes a caption's size in steps, never point by point: the text does not grow and shrink while the
    /// window is dragged (2026-10-13).
    func testTheCaptionSizeChangesInSteps() {
        let sizes = Set(stride(from: 120.0, through: 600.0, by: 1).map { CaptionSize.tile(height: $0, large: false) })
        XCTAssertEqual(sizes, [16], "16 points on every small tile")
        XCTAssertEqual(Set(stride(from: 250.0, through: 900.0, by: 1).map { CaptionSize.tile(height: $0, large: true) }), [18, 22])
    }

    /// Each digit rolls on its own; the words between them keep together, so they keep their kerning.
    func testRollingTextSplitsDigitsFromWords() {
        let pieces = RollingText.pieces("liberar 209,3 MB")
        XCTAssertEqual(pieces.map(\.text), ["liberar ", "2", "0", "9", ",", "3", " MB"])
        XCTAssertEqual(pieces.filter(\.isDigit).count, 4)
        // Slots retain their layout identity; changed content gets the new identity inside its drawing overlay.
        let next = RollingText.pieces("liberar 212,3 MB")
        XCTAssertEqual(pieces.map(\.id), next.map(\.id))
        let contents = Set(pieces.map { "\($0.id)|\($0.text)" })
        XCTAssertEqual(contents.intersection(next.map { "\($0.id)|\($0.text)" }).count, 5)
    }
}
