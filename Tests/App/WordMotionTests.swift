import AppKit
import SwiftUI
import XCTest
@testable import MacSpaceApp

@MainActor
final class WordMotionTests: XCTestCase {
    private func snapshot(_ text: String) -> TextMotionSnapshot {
        TextMotionSnapshot(text, font: Font(CaptionFont.status(size: 22)))
    }

    func testInterruptedLoadingFreezesOnlyTheLatestNumericValue() throws {
        var motion = TextMotionState().updating(to: snapshot("carregando 30%"))
        motion = motion.updating(to: snapshot("carregando 60%"))
        XCTAssertNil(motion.change, "numeric-only updates keep the native transition")
        motion = motion.updating(to: snapshot("IA desativada"))
        let change = try XCTUnwrap(motion.change)
        XCTAssertEqual(change.outgoing.text, "carregando 60%")
        XCTAssertEqual(change.outgoing.font, snapshot("carregando 60%").font)
        XCTAssertEqual(change.incoming.text, "IA desativada")
        XCTAssertEqual(change.incoming.font, snapshot("IA desativada").font)
        XCTAssertNotEqual(change.incoming.font, change.outgoing.font, "the outgoing progress digits keep their own feature settings")
    }

    func testRapidWordChangesCannotResurrectAnOlderPhraseOrClearANewerOne() throws {
        var motion = TextMotionState().updating(to: snapshot("carregando 30%"))
        motion = motion.updating(to: snapshot("IA desativada"))
        let first = try XCTUnwrap(motion.change)
        motion = motion.updating(to: snapshot("carregando 10%"))
        let second = try XCTUnwrap(motion.change)
        XCTAssertEqual(second.outgoing.text, "IA desativada")
        XCTAssertEqual(second.incoming.text, "carregando 10%")
        XCTAssertNotEqual(first.id, second.id)
        motion.complete(first.id)
        XCTAssertEqual(motion.change?.id, second.id, "a canceled playback cannot clear its replacement")
        motion = motion.updating(to: snapshot("carregando 60%"))
        XCTAssertEqual(motion.change?.id, second.id, "a counter update must not restart the word entrance")
        XCTAssertEqual(motion.change?.incoming.text, "carregando 60%")
        motion.complete(second.id)
        XCTAssertNil(motion.change)
        XCTAssertEqual(motion.current?.text, "carregando 60%")
    }

    /// A unit shared by two legend lines moves sideways as the name before it changes width: it rolls with the rest, never jumps.
    func testAWordThatMovesSidewaysIsNotKeptStill() {
        let change = WordChange(id: 1, outgoing: snapshot("Apps 120 MB"), incoming: snapshot("Documents 340 MB"))
        XCTAssertEqual(change.unchanged().outgoing, [])
        XCTAssertEqual(change.unchanged().incoming, [])
    }

    func testUnchangedWordsAreDrawnOnceAndUnicodeWhitespaceIsPreserved() {
        let change = WordChange(id: 1, outgoing: snapshot("Free 20 MB"), incoming: snapshot("Free 20 GB"))
        XCTAssertEqual(change.unchanged().outgoing, [0, 1])
        XCTAssertEqual(change.unchanged().incoming, [0, 1])
        let trailing = WordChange(id: 2, outgoing: snapshot("Free 20 MB"), incoming: snapshot("Keep 20 MB"))
        XCTAssertEqual(trailing.unchanged(alignment: .trailing).incoming, [1, 2], "drawn from the trailing edge, the shared end stays put")
        XCTAssertEqual(trailing.unchanged(alignment: .center).incoming, [])
        for text in ["liberar 2,21 GB", "Free\u{00A0}20 MB", "IA\ndesativada", "正在加载 ٤٢٪", "選択した項目を解放"] {
            XCTAssertEqual(WordChange.pieces(text).map(\.text).joined(), text)
        }
    }

    private func bitmap<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private func scene(_ change: WordChange, elapsed: Double, alignment: Alignment = .trailing, reduceMotion: Bool = false) -> some View {
        // Padding leaves room to detect escaped glyphs/blur; the caption's right anchor is x = 32 + 340.
        WordChangeFrame(change: change, elapsed: elapsed, alignment: alignment, reduceMotion: reduceMotion)
            .lineLimit(1).multilineTextAlignment(.trailing)
            .frame(width: 340, height: 64, alignment: alignment)
            .padding(32)
            .foregroundStyle(.white)
    }

    func testIntermediateFramesNeverPaintPastTheSharedRightAnchor() throws {
        for (from, to) in [("carregando 60%", "IA desativada"), ("IA desativada", "carregando 100%"),
                           ("Liberar", "Liberando espaço"), ("Liberando espaço", "Liberando em segundo plano"),
                           ("1 MB freed", "2 GB freed")] {
            let change = WordChange(id: 1, outgoing: snapshot(from), incoming: snapshot(to))
            for time in [0.0, 0.025, 0.08, 0.15, 0.22, 0.3, 0.4, 0.5, 0.7] {
                let image = try bitmap(scene(change, elapsed: time))
                let values = try pixels(image)
                let right = 2 * (32 + 340)
                for x in right..<image.width {
                    XCTAssertFalse((0..<image.height).contains { y in values[(y * image.width + x) * 4 + 3] > 8 }, "escaped ink in \(from) → \(to) at \(time)s, column \(x)")
                }
            }
        }
    }

    /// Mid-change, the words are drawn on their way (each a layer of its own since the motion left `TextRenderer`), not skipped.
    func testIntermediateFramesDrawTheRollingWords() throws {
        let change = WordChange(id: 1, outgoing: snapshot("carregando 60%"), incoming: snapshot("IA desativada"))
        let final = try pixels(bitmap(scene(change, elapsed: 2)))
        for time in [0.05, 0.1, 0.15, 0.25] {
            let frame = try pixels(bitmap(scene(change, elapsed: time)))
            XCTAssertTrue(stride(from: 3, to: frame.count, by: 4).contains { frame[$0] > 8 }, "no ink at \(time)s")
            XCTAssertNotEqual(frame, final, "the words have not arrived yet at \(time)s")
        }
    }

    func testCompletedWordFrameMatchesTheNaturalTargetExactly() throws {
        let contexts: [(Font, Alignment)] = [(Font(CaptionFont.status(size: 22)), .trailing),
            (.system(size: 11, weight: .semibold), .leading), (.system(size: 13, weight: .semibold), .leading),
            (Font(CaptionFont.status(size: 22)), .center)]
        for (font, alignment) in contexts {
            for text in ["IA desativada", "carregando 59%", "Liberando espaço", "2,21 GB liberados", "選択した項目を解放"] {
                let target = TextMotionSnapshot(text, font: font)
                let change = WordChange(id: 1, outgoing: TextMotionSnapshot("carregando 60%", font: font), incoming: target)
                let actual = try bitmap(scene(change, elapsed: 2, alignment: alignment))
                let expected = try bitmap(Text(verbatim: text).font(target.font).lineLimit(1).multilineTextAlignment(.trailing)
                    .frame(width: 340, height: 64, alignment: alignment).padding(32).foregroundStyle(.white))
                XCTAssertEqual(actual.width, expected.width)
                XCTAssertEqual(actual.height, expected.height)
                XCTAssertTrue(try pixels(actual) == pixels(expected), "finishing the word animation cannot move/re-space the final line")
            }
        }
    }

    func testWrappedOutgoingTextRetainsItsMeasuredWidthAndFont() throws {
        let font = Font(CaptionFont.status(size: 16))
        let text = "Free selected application caches after closing the listed applications"
        let label = Text(verbatim: text).font(font).fixedSize(horizontal: false, vertical: true).frame(width: 180, alignment: .trailing)
        let renderer = ImageRenderer(content: label)
        var size: CGSize?
        renderer.render { value, _ in size = value }
        let outgoing = TextMotionSnapshot(text, font: font, size: try XCTUnwrap(size))
        let change = WordChange(id: 1, outgoing: outgoing, incoming: TextMotionSnapshot("Done", font: font))
        let actual = try bitmap(WordChangeFrame(change: change, elapsed: 0, alignment: .trailing, singleLine: false)
            .frame(width: 340, height: 140, alignment: .trailing).padding(32).foregroundStyle(.white))
        let expected = try bitmap(label.frame(width: 340, height: 140, alignment: .trailing).padding(32).foregroundStyle(.white))
        XCTAssertTrue(try pixels(actual) == pixels(expected), "the outgoing paragraph must not rewrap to the short target's width")
    }

    func testLongButtonWordChangesKeepNativeTruncationAtBothEnds() throws {
        let contexts: [(Font, CGFloat, Alignment)] = [(.system(size: 13, weight: .semibold), 130, .leading),
            (.system(size: 11, weight: .semibold), 90, .leading), (Font(CaptionFont.status(size: 22)), 180, .trailing)]
        for (font, width, alignment) in contexts {
            for long in ["This warning is too long to fit in the available orange button width",
                         "A warning which needs to be truncated at the button's available width",
                         "Carregando os arquivos selecionados para liberar espaço"] {
                let renderer = ImageRenderer(content: Text(verbatim: long).font(font).lineLimit(1))
                renderer.proposedSize = ProposedViewSize(width: width, height: nil)
                var size: CGSize?
                renderer.render { value, _ in size = value }
                let limited = TextMotionSnapshot(long, font: font, size: try XCTUnwrap(size))
                let short = TextMotionSnapshot("Liberar", font: font)
                let expected = try bitmap(Text(verbatim: long).font(font).lineLimit(1)
                    .frame(width: limited.size?.width, height: limited.size?.height, alignment: alignment)
                    .frame(width: 340, height: 64, alignment: alignment).padding(32).foregroundStyle(.white))
                for (from, to, time) in [(limited, short, 0.0), (short, limited, 2.0)] {
                    let change = WordChange(id: 1, outgoing: from, incoming: to)
                    let actual = try bitmap(scene(change, elapsed: time, alignment: alignment))
                    let actualPixels = try pixels(actual), expectedPixels = try pixels(expected)
                    // Native truncation and TextRenderer quantize fractional glyph origins differently. Compare the full
                    // glyph contours within one device pixel, including the ellipsis; fitting labels above match exactly.
                    func followsContour(_ source: [UInt8], _ reference: [UInt8]) -> Bool {
                        for y in 0..<actual.height {
                            for x in 0..<actual.width where source[(y * actual.width + x) * 4 + 3] > 96 {
                                let matches = (max(0, y - 1)...min(actual.height - 1, y + 1)).contains { row in
                                    (max(0, x - 1)...min(actual.width - 1, x + 1)).contains { column in
                                        reference[(row * actual.width + column) * 4 + 3] > 48
                                    }
                                }
                                if !matches { return false }
                            }
                        }
                        return true
                    }
                    XCTAssertTrue(followsContour(actualPixels, expectedPixels) && followsContour(expectedPixels, actualPixels), "native truncation contour mismatch: \(long), \(alignment)")
                }
            }
        }
    }

    func testChangedWordsCascadeWhileReduceMotionHasNoTravelOrBlur() {
        let first = WordMotionSample.at(0.1, ordinal: 0, outgoing: false, reduceMotion: false, delay: 0)
        let second = WordMotionSample.at(0.1, ordinal: 1, outgoing: false, reduceMotion: false, delay: 0)
        XCTAssertLessThan(first.y, second.y, "later words follow the existing stagger")
        XCTAssertGreaterThan(first.opacity, second.opacity)
        for time in [0.0, 0.1, 0.2, 0.5] {
            for outgoing in [false, true] {
                let sample = WordMotionSample.at(time, ordinal: 1, outgoing: outgoing, reduceMotion: true, delay: 0.2)
                XCTAssertEqual(sample.y, 0)
                XCTAssertEqual(sample.blur, 0)
            }
        }
    }

    func testExportApprovedTransitionFramesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["MACSPACE_WORD_MOTION_FRAMES"] else { throw XCTSkip("Optional frame export") }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let change = WordChange(id: 1, outgoing: snapshot("carregando 60%"), incoming: snapshot("IA desativada"))
        for (index, time) in [0.0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5].enumerated() {
            let image = try bitmap(scene(change, elapsed: time))
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("frame-\(index).png"))
        }
    }
}
