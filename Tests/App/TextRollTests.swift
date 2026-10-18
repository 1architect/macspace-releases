import SwiftUI
import XCTest
@testable import MacSpaceApp

@MainActor
final class TextRollTests: XCTestCase {
    func testCounterGrowthKeepsTheLabelAndUnitIdentities() {
        for (before, after) in [("Free 9,9 GB", "Free 10,4 GB"), ("Loading 9%", "Loading 10%"), ("Free 999 MB", "Free 1999 MB")] {
            let old = RollingText.pieces(before)
            let new = RollingText.pieces(after)
            XCTAssertEqual(old.first?.id, new.first?.id)
            XCTAssertEqual(old.last?.id, new.last?.id, "adding a digit cannot replace the unchanged unit")
            XCTAssertEqual(old.first?.text, new.first?.text)
            XCTAssertEqual(old.last?.text, new.last?.text)
            XCTAssertEqual(Set(new.map(\.id)).count, new.count)
        }
    }

    func testDigitsKeepTheirPlaceFromTheRightAsACounterGrows() {
        let old = RollingText.pieces("9 MB")
        let new = RollingText.pieces("19 MB")
        XCTAssertEqual(old[0].id, new[1].id)
        XCTAssertNotEqual(new[0].id, new[1].id)
        XCTAssertEqual(old[1].id, new[2].id)
    }

    func testOriginalCounterPreservesUnicodeAndWhitespace() {
        for text in ["Free 25 GB", "加载 42%", "解放 2,5 GB\n完了", "تنزيل ٤٢٪"] {
            XCTAssertEqual(RollingText.pieces(text).map(\.text).joined(), text)
        }
    }

    func testNativeTransitionUsesOnlyCurrentTextForRestingLayout() throws {
        for text in ["Free", "Free selected 2.1 GB", "Loading", "999 MB", "1000 MB", "正在加载", "Liberar selecionados 2,1 GB"] {
            let expected = ImageRenderer(content: Text(verbatim: text).monospacedDigit().font(.system(size: 13)))
            let actual = ImageRenderer(content: ChangingText(text: text).font(.system(size: 13)))
            var expectedSize: CGSize?, actualSize: CGSize?
            expected.render { size, _ in expectedSize = size }
            actual.render { size, _ in actualSize = size }
            XCTAssertEqual(try XCTUnwrap(actualSize), try XCTUnwrap(expectedSize), "an animation overlay cannot add width or height")
        }
    }
}
