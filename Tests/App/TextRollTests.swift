import XCTest
@testable import MacSpaceApp

final class TextRollTests: XCTestCase {
    func testCounterGrowthKeepsTheLabelAndUnitOutOfTheTransition() {
        for (before, after) in [("Free 9,9 GB", "Free 10,4 GB"), ("Loading 9%", "Loading 10%"), ("Free 999 MB", "Free 1999 MB")] {
            let change = TextRollChange(from: before, to: after)
            XCTAssertFalse(change.removed.contains(0), "the unchanged label must stay still")
            XCTAssertFalse(change.inserted.contains(0))
            XCTAssertFalse(change.removed.contains(change.old.count - 1), "the unchanged unit must stay still when a digit is added")
            XCTAssertFalse(change.inserted.contains(change.new.count - 1))
        }
    }

    func testOnlyChangedDigitRolls() {
        let change = TextRollChange(from: "Loading 41%", to: "Loading 42%")
        XCTAssertEqual(change.removed.map { change.old[$0].text }, ["1"])
        XCTAssertEqual(change.inserted.map { change.new[$0].text }, ["2"])
        let same = TextRollChange(from: "Loading 42%", to: "Loading 42%")
        XCTAssertTrue(same.removed.isEmpty && same.inserted.isEmpty)
    }

    func testWordChangesRollWithoutReplacingTheUnchangedNumberAndUnit() {
        let change = TextRollChange(from: "Free 25 GB", to: "Removing 25 GB")
        XCTAssertEqual(change.removed.map { change.old[$0].text }, ["Free "])
        XCTAssertEqual(change.inserted.map { change.new[$0].text }, ["Removing "])
        for text in ["加载 42%", "解放 2,5 GB\n完了", "تنزيل ٤٢٪"] {
            let value = TextRollChange(from: "", to: text)
            XCTAssertEqual(value.new.map(\.text).joined(), text, "shaping must retain the original spaces and line breaks")
        }
    }

    func testEveryRollingFrameHasZeroHorizontalTravelIncludingSpringOvershoot() {
        for outgoing in [true, false] {
            for rank in [0, 1, 5, 20] {
                for progress in stride(from: 0.0, through: 1.2, by: 0.025) {
                    let frame = TextRollMotion(progress: progress, rank: rank, outgoing: outgoing, lineHeight: 14)
                    XCTAssertEqual(frame.translation.width, 0)
                    XCTAssertTrue(frame.translation.height.isFinite)
                    XCTAssertTrue((0...1).contains(frame.opacity))
                }
            }
        }
        let start = TextRollMotion(progress: 0, rank: 0, outgoing: false, lineHeight: 14)
        XCTAssertGreaterThan(start.translation.height, 0)
        XCTAssertGreaterThan(start.blur, 0, "keep the established roll's blur, rather than a fade-only replacement")
        let end = TextRollMotion(progress: 1, rank: 0, outgoing: false, lineHeight: 14)
        XCTAssertEqual(end.translation, .zero)
        XCTAssertEqual(end.opacity, 1)
    }

    func testReduceMotionUsesOnlyOpacity() {
        let frame = TextRollMotion(progress: 0.5, rank: 10, outgoing: false, reduceMotion: true, lineHeight: 14)
        XCTAssertEqual(frame.translation, .zero)
        XCTAssertEqual(frame.blur, 0)
        XCTAssertEqual(frame.opacity, 0.5)
    }
}
