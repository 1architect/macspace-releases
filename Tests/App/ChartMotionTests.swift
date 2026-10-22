import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

final class ChartMotionTests: XCTestCase {
    private let weights: [Double] = [10, 6.4, 3.5, 3.3, 3, 1, 1, 0.7]
    private let chart = CGRect(x: 0, y: 0, width: 800, height: 240)

    private func plan() -> (GrowPlan, [CGRect]) {
        let rects = Treemap.arranged(weights, in: chart, style: .treemap)
        return (GrowPlan(rects: rects, weights: weights), rects)
    }

    func testFillCurveRunsFromZeroToOneWithoutGoingBack() {
        XCTAssertEqual(ChartMotion.fill(0), 0, accuracy: 0.001)
        XCTAssertEqual(ChartMotion.fill(1), 1, accuracy: 0.001)
        var last = 0.0
        for step in 0...100 {
            let value = ChartMotion.fill(Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, last - 1e-9)
            last = value
        }
    }

    /// A block opens with the reading: most of it once its part is found, the rest slowly until a little after the next block starts,
    /// so one block is still opening when the next appears.
    func testABlockKeepsOpeningUntilAfterTheNextStarts() {
        let (plan, _) = plan()
        for (earlier, later) in zip(plan.sequence, plan.sequence.dropFirst()) {
            let nextStart = plan.windows[later].start
            XCTAssertEqual(plan.target(earlier, at: plan.windows[earlier].start), 0, accuracy: 0.001)
            XCTAssertGreaterThan(plan.target(earlier, at: nextStart), 0.6, "well open when the next one starts")
            XCTAssertLessThan(plan.target(earlier, at: nextStart), 1, "still opening when the next one starts")
            XCTAssertEqual(plan.target(earlier, at: plan.windows[earlier].end), 1, accuracy: 0.001)
            var last = 0.0
            for step in 0...100 {
                let value = plan.target(earlier, at: Double(step) / 100)
                XCTAssertGreaterThanOrEqual(value, last - 1e-9)
                last = value
            }
        }
        XCTAssertEqual(plan.windows[plan.sequence.last!].end, 1)
    }

    /// The reading drawn never stands still while the real one does, nor goes back, and catches up with it.
    func testTheReadingDrawnCreepsOnAndNeverGoesBack() {
        var drawn = 0.0
        for _ in 0..<600 { drawn = ChartMotion.drawnReading(drawn, reading: 0.3, stalled: 0, over: 1 / 60) }
        XCTAssertEqual(drawn, 1 - pow(0.7, ChartMotion.ahead), accuracy: 0.03, "ahead of the real reading")
        XCTAssertGreaterThan(drawn, 0.3)
        var stalledFor = 0.0, previous = drawn
        for _ in 0..<120 {
            stalledFor += 1 / 60
            drawn = ChartMotion.drawnReading(drawn, reading: 0.3, stalled: stalledFor, over: 1 / 60)
            XCTAssertGreaterThan(drawn, previous, "still moving while the reading says nothing new")
            previous = drawn
        }
        XCTAssertLessThan(drawn, 1 - pow(0.7, ChartMotion.ahead) + ChartMotion.creep)
        XCTAssertEqual(ChartMotion.drawnReading(0.6, reading: 0.2, stalled: 0, over: 1 / 60), 0.6, "never back")
        XCTAssertEqual(ChartMotion.drawnReading(0.99, reading: 1, stalled: 0, over: 10), 1, accuracy: 0.001, "ends where the reading ends")
    }

    /// A block's width follows its target as a spring: past it a little, then at rest on it.
    func testAWidthFollowsAsASpring() {
        var width = (x: 0.0, v: 0.0), most = 0.0
        for _ in 0..<180 {
            ChartMotion.follow(&width, to: 1, over: 1 / 60)
            most = max(most, width.x)
        }
        XCTAssertGreaterThan(most, 1)
        XCTAssertLessThan(most, 1.15)
        XCTAssertEqual(width.x, 1, accuracy: 0.003)
    }

    func testRefreshClosesToNothing() {
        XCTAssertEqual(ChartMotion.closed(after: 0), 1)
        XCTAssertLessThan(ChartMotion.closed(after: ChartMotion.closing / 2), 1)
        XCTAssertEqual(ChartMotion.closed(after: ChartMotion.closing), 0, accuracy: 0.001)
    }

    /// Top to bottom, and left to right along a row, never right to left.
    func testBlocksAreFoundTopToBottomThenLeftToRight() {
        let (plan, rects) = plan()
        for (earlier, later) in zip(plan.sequence, plan.sequence.dropFirst()) {
            let a = rects[earlier], b = rects[later]
            XCTAssertTrue(a.minY < b.minY - 0.5 || (abs(a.minY - b.minY) <= 0.5 && a.minX < b.minX), "\(a) before \(b)")
            XCTAssertLessThan(plan.windows[earlier].start, plan.windows[later].start)
        }
        XCTAssertEqual(plan.windows[plan.sequence[0]].start, 0)
        XCTAssertLessThan(plan.windows[plan.sequence.last!].start, 0.95, "the last part is found before an estimated reading stops short")
    }

    /// A block opens from its left side, at its full height.
    func testABlockOpensFromItsLeftSide() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(GrowPlan.drawn(rect, open: 0.5), CGRect(x: 10, y: 20, width: 50, height: 50))
        XCTAssertEqual(GrowPlan.drawn(rect, open: 1), rect)
        XCTAssertEqual(GrowPlan.drawn(rect, open: 0).width, 0)
    }

    func testOnlyTheAmberPartsCountAsFreeable() {
        let parts = [UsageSegment(id: "a", label: "a", bytes: 100, tone: .caution), UsageSegment(id: "b", label: "b", bytes: 900, tone: .series(0))]
        XCTAssertEqual(BlocksView.amber(parts), 100)
    }

    func testPlaceholdersAreTold() {
        XCTAssertTrue(LoadingWave.isPlaceholder(LoadingWave.placeholderBlocks))
        XCTAssertFalse(LoadingWave.isPlaceholder([UsageSegment(id: "caches", label: "Caches", bytes: 1, tone: .series(0))]))
    }

    /// Settings saved before a key existed keep its default, and the defaults are the motion as designed.
    func testMotionSettingsKeepTheirDefaults() throws {
        let empty = try JSONDecoder().decode(MotionTuning.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, MotionTuning())
        let partial = try JSONDecoder().decode(MotionTuning.self, from: Data(#"{"speed": 2}"#.utf8))
        XCTAssertEqual(partial.speed, 2)
        XCTAssertEqual(partial.ahead, MotionTuning().ahead)
        let defaults = MotionTuning()
        XCTAssertEqual(defaults.glideBounce, 0.18, "the glide to new figures is the app's own (Theme.layout)")
        XCTAssertEqual(defaults.glideDuration, 0.55)
        XCTAssertEqual(defaults.speed, 2.5)
        XCTAssertGreaterThan(defaults.finishRoom, 0, "the chart keeps room for its finish")
    }

    /// The finish springs past the chart's edge a little and comes to rest on it.
    func testTheFinishSpringsIntoTheRoom() {
        let values = stride(from: 0.0, through: 1.5, by: 0.01).map { ChartMotion.spring($0, bounce: 0.5, duration: 0.35) }
        XCTAssertEqual(values.first!, 0)
        XCTAssertGreaterThan(values.max()!, 1)
        XCTAssertEqual(values.last!, 1, accuracy: 0.005)
        XCTAssertEqual(BlocksView.narrowed(CGRect(x: 100, y: 5, width: 50, height: 20), to: 0.9), CGRect(x: 90, y: 5, width: 45, height: 20))
    }
}
