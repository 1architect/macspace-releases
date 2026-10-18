import SwiftUI
import XCTest
@testable import MacSpaceApp

@MainActor
final class TextRollTests: XCTestCase {
    func testNumericFieldsKeepTheirIdentityAndDecimalSeparators() {
        for (before, after) in [("Free 9,9 GB", "Free 10,4 GB"), ("Loading 9%", "Loading 100%"), ("Free 999 MB", "Free 1999 MB")] {
            let old = TextFields.split(before)
            let new = TextFields.split(after)
            XCTAssertEqual(old.map(\.id), new.map(\.id))
            XCTAssertEqual(old.first?.text, new.first?.text)
            XCTAssertEqual(old.last?.text, new.last?.text)
            XCTAssertEqual(new.filter(\.numeric).count, 1)
        }
    }

    func testFieldsPreserveUnicodeAndWhitespace() {
        for text in ["Free 25 GB", "加载 42%", "解放 2,5 GB\n完了", "تنزيل ٤٢٪", "1\u{202F}234,5 MB"] {
            XCTAssertEqual(TextFields.split(text).map(\.text).joined(), text)
        }
    }

    func testPercentageFieldKeepsTheCaptionWidthFixed() throws {
        var widths: [CGFloat] = []
        for progress in [1, 9, 10, 17, 22, 60, 64, 75, 100] {
            let label = ChangingText(text: "carregando \(progress)%", alignment: .trailing)
                .font(Font(CaptionFont.status(size: 22))).lineLimit(1)
            let renderer = ImageRenderer(content: label)
            renderer.render { size, _ in widths.append(size.width) }
        }
        XCTAssertEqual(Set(widths).count, 1, "a trailing caption must not move its unchanged word as progress changes")
    }

    func testLoadingPercentageHasNormalVisibleSpacing() throws {
        func inkWidth<V: View>(_ view: V) throws -> Int {
            let renderer = ImageRenderer(content: view.foregroundStyle(.white))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let columns = (0..<width).filter { x in (0..<height).contains { y in pixels[(y * width + x) * 4 + 3] > 16 } }
            return try XCTUnwrap(columns.last) - XCTUnwrap(columns.first)
        }
        for progress in [1, 9, 17, 22, 64, 75, 100] {
            let text = "carregando \(progress)%"
            let font = Font(CaptionFont.status(size: 22))
            let natural = try inkWidth(Text(verbatim: text).font(font).lineLimit(1))
            let actual = try inkWidth(ChangingText(text: text, alignment: .trailing).font(font).lineLimit(1))
            XCTAssertEqual(actual, natural, accuracy: 2, "reserved width cannot create a visible gap before the number or its sign")
        }
    }

    func testStorageSentenceRetainsItsNaturalSpacingAndWidth() throws {
        for text in ["47% de 245,11 GB", "47% of 245.11 GB", "47 % de 245,11 Go", "47 % von 245,11 GB"] {
            let font = Font(CaptionFont.status(size: 22))
            let expected = ImageRenderer(content: Text(verbatim: text).font(font).lineLimit(1))
            let actual = ImageRenderer(content: ChangingText(text: text, alignment: .trailing).font(font).lineLimit(1))
            var naturalSize: CGSize?, actualSize: CGSize?
            expected.render { size, _ in naturalSize = size }
            actual.render { size, _ in actualSize = size }
            XCTAssertEqual(try XCTUnwrap(actualSize), try XCTUnwrap(naturalSize), "a percentage inside a sentence must preserve native kerning and spaces")
        }
    }

    func testAllDoneNumericReservationDoesNotChangeDuringCountUp() throws {
        var widths: [CGFloat] = []
        for value in ["0", "1", "9", "10", "11", "99", "111"] {
            let renderer = ImageRenderer(content: ChangingText(text: "\(value) MB freed", alignment: .center, maximumText: "111 MB freed")
                .font(.system(size: 22)).lineLimit(1))
            renderer.render { size, _ in widths.append(size.width) }
        }
        XCTAssertEqual(Set(widths).count, 1, "counting cannot push the centered words sideways")
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
            for text in ["31,11 GB", "liberar 2,21 GB", "11", "22", "9", "10", "111,11 GB", "IA desativada", "liberar 30 GB"] {
                let expected = try size(Text(verbatim: text).font(Font(font)))
                let actual = try size(ChangingText(text: text, alignment: .trailing).font(Font(font)).lineLimit(1))
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


}
