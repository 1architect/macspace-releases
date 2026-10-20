import AppKit
import XCTest
@testable import MacSpaceApp

final class GlyphCacheTests: XCTestCase {
    func testTheGlyphCacheTakesTheLimit() throws {
        let applied = try XCTUnwrap(GlyphCache.apply(), "Core Graphics' font cache was not found")
        XCTAssertEqual(applied, GlyphCache.limit)
    }

    func testCaptionFontsInBetweenSizesAreNotKeptForGood() {
        // A caption following its tile through a move: a size for every frame.
        for step in 0..<400 { _ = CaptionFont.title(size: 15 + CGFloat(step) * 0.0371) }
        XCTAssertLessThanOrEqual(CaptionFont.cachedCount, CaptionFont.limit)
        XCTAssertEqual(CaptionFont.title(size: 22).pointSize, 22, "a resting size is drawn at exactly that size")
    }
}
