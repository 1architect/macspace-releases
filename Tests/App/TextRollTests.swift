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
            let expected = ImageRenderer(content: Text(verbatim: text).font(.system(size: 13)))
            let actual = ImageRenderer(content: ChangingText(text: text).font(.system(size: 13)))
            var expectedSize: CGSize?, actualSize: CGSize?
            expected.render { size, _ in expectedSize = size }
            actual.render { size, _ in actualSize = size }
            XCTAssertEqual(try XCTUnwrap(actualSize), try XCTUnwrap(expectedSize), "an animation overlay cannot add width or height")
        }
    }
}

@MainActor
final class CaptionDigitTests: XCTestCase {
    private func size<V: View>(_ view: V) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        var measured: CGSize?
        renderer.render { value, _ in measured = value }
        return try XCTUnwrap(measured)
    }

    func testReportedOnesUseTheOriginalCaptionFontMetrics() throws {
        for font in [CaptionFont.title(size: 22), CaptionFont.status(size: 22), CaptionFont.title(size: 16), CaptionFont.status(size: 16)] {
            for text in ["31,11 GB", "liberar 2,21 GB", "11", "22", "9", "10", "111,11 GB", "IA desativada", "carregando 30%"] {
                let expected = try size(Text(verbatim: text).font(Font(font)))
                let actual = try size(ChangingText(text: text, alignment: .trailing).font(Font(font)))
                XCTAssertEqual(actual, expected, "animation must inherit the caption font's original digit spacing")
            }
        }
    }

    func testCaptionLayoutAndDrawingAgreeForOnesNearTheWrappingBoundary() throws {
        let text = "dados do sistema 31,11 GB"
        let actual = try size(ChangingText(text: text).font(Font(CaptionFont.title(size: 22))))
        let info = TileInfo(title: "dados do sistema", figure: "31,11 GB", status: "liberar 2,21 GB")
        let fitting = CaptionLayout(info: info, size: 22, width: actual.width + 1)
        XCTAssertTrue(fitting.oneLine)
        XCTAssertEqual(fitting.titleWidth, ceil(actual.width), accuracy: 1)
        XCTAssertFalse(CaptionLayout(info: info, size: 22, width: actual.width - 1).oneLine)
    }

    func testExplicitMonospacedCallersStillControlTheirDigits() throws {
        for text in ["111,11 GB", "888,88 GB"] {
            let expected = try size(Text(verbatim: text).font(.system(size: 13)).monospacedDigit())
            let actual = try size(ChangingText(text: text).font(.system(size: 13)).monospacedDigit())
            XCTAssertEqual(actual, expected)
        }
    }

    func testNativeNumericAnimationKeepsItsIdentityButUnrelatedPhrasesDoNot() {
        for (old, new) in [("11", "22"), ("9", "10"), ("31,11 GB", "31,22 GB"), ("carregando 9%", "carregando 10%")] {
            XCTAssertEqual(TextChangeIdentity(old), TextChangeIdentity(new))
        }
        for (old, new) in [("IA desativada", "carregando 30%"), ("carregando 30%", "IA desativada"), ("Free", "Freeing in the background")] {
            XCTAssertNotEqual(TextChangeIdentity(old), TextChangeIdentity(new), "unrelated phrases cannot reuse the native numeric interpolation")
        }
    }
}
