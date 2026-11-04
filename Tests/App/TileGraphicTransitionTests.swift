import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

final class TileGraphicTransitionTests: XCTestCase {
    func testReturningGraphicKeepsOneLayoutThroughTheWholeMovingCard() {
        let resting = CGSize(width: 420, height: 260)
        let target = CGSize(width: 1464, height: 880)
        for step in 0...120 {
            let progress = CGFloat(step) / 120
            let proposed = CGSize(width: ZoomMath.lerp(resting.width, target.width, progress), height: ZoomMath.lerp(resting.height, target.height, progress))
            let layout = ZoomMath.graphicLayout(proposed: proposed, resting: resting, returning: true)
            XCTAssertEqual(layout, resting, "The entrance must never retarget its layout during the shrink")
            let scale = ZoomMath.graphicScale(layout: layout, proposed: proposed)
            XCTAssertEqual(layout.width * scale.width, proposed.width, accuracy: 0.0001)
            XCTAssertEqual(layout.height * scale.height, proposed.height, accuracy: 0.0001)
            XCTAssertEqual(ZoomMath.graphicLayout(proposed: proposed, resting: resting, returning: false), proposed,
                "Normal dashboard drawing and module opening retain their prior layout")
        }
        XCTAssertEqual(ZoomMath.graphicScale(layout: resting, proposed: resting), CGSize(width: 1, height: 1),
            "At handoff, the graphic has exactly its normal tile geometry")
        XCTAssertEqual(ZoomMath.graphicLayout(proposed: target, resting: .zero, returning: true), target)
        XCTAssertEqual(ZoomMath.graphicLayout(proposed: target, resting: nil, returning: true), target)
    }

    func testReturningTreemapReusesGeometryInsteadOfRebuildingAtEveryZoomFrame() {
        let segments = (0..<1000).map { UsageSegment(id: "folder-\($0)", label: "Folder \($0)", bytes: UInt64(1000 - $0), tone: .series($0), pageID: "folder:\($0)") }
        let info = TileInfo(title: "Module", status: "Ready", graphic: .blocks(segments))
        let resting = CGSize(width: 420, height: 260)
        let order = TileFace.chartArea(in: resting, info: info, captionSize: 22, restingSize: resting).size
        let moving = BlockGeometryCache(), stable = BlockGeometryCache()
        let started = Date()
        var movingSeconds: TimeInterval = 0, stableSeconds: TimeInterval = 0
        for frame in 0...120 {
            let progress = 1 - CGFloat(frame) / 120
            let proposed = CGSize(width: ZoomMath.lerp(resting.width, 1464, progress), height: ZoomMath.lerp(resting.height, 880, progress))
            let oldArea = TileFace.chartArea(in: proposed, info: info, captionSize: 22, restingSize: resting).size
            let before = Date()
            _ = moving.value(segments: segments, size: oldArea, order: order, look: .tile)
            movingSeconds += Date().timeIntervalSince(before)
            let layout = ZoomMath.graphicLayout(proposed: proposed, resting: resting, returning: true)
            let area = TileFace.chartArea(in: layout, info: info, captionSize: 22, restingSize: resting).size
            let after = Date()
            _ = stable.value(segments: segments, size: area, order: order, look: .tile)
            stableSeconds += Date().timeIntervalSince(after)
        }
        XCTAssertEqual(moving.computations, 121, "The previous path changed chart layout every frame")
        XCTAssertEqual(stable.computations, 1, "The returning graphic keeps its prepared geometry throughout the movement")
        XCTAssertEqual(stable.value(segments: segments, size: order, order: order, look: .tile).rects,
                       moving.value(segments: segments, size: order, order: order, look: .tile).rects)
        print("WIDGET_RETURN_GEOMETRY frames=121 before=\(moving.computations) after=\(stable.computations) beforeSeconds=\(movingSeconds) afterSeconds=\(stableSeconds) totalSeconds=\(Date().timeIntervalSince(started))")
    }

    func testBackMountsTheGraphicBeforeTheFirstShrinkingFrame() {
        XCTAssertFalse(ZoomMath.drawsGraphic(progress: 1, returning: false), "A covered page releases its hidden widget drawing")
        XCTAssertTrue(ZoomMath.drawsGraphic(progress: 1, returning: true), "Back must create the graphic while the card is still fully expanded")
        XCTAssertEqual(ZoomMath.graphicOpacity(progress: 1, returning: true), 0)
        for progress in stride(from: 0.99, through: 0.01, by: -0.01) {
            XCTAssertTrue(ZoomMath.drawsGraphic(progress: progress, returning: true))
            XCTAssertGreaterThan(ZoomMath.graphicOpacity(progress: progress, returning: true), 0,
                "Every shrinking frame can reveal the running entrance, not only the final 35%")
        }
    }

    func testReturnRevealIsContinuousAndOpeningKeepsItsExistingTiming() {
        var previous: CGFloat = 0
        for step in 0...100 {
            let progress = 1 - CGFloat(step) / 100
            let opacity = ZoomMath.graphicOpacity(progress: progress, returning: true)
            XCTAssertGreaterThanOrEqual(opacity, previous)
            XCTAssertLessThanOrEqual(opacity - previous, 0.016)
            previous = opacity
            XCTAssertEqual(ZoomMath.graphicOpacity(progress: progress, returning: false), 1 - ZoomMath.ramp(progress, 0, 0.35))
        }
        XCTAssertEqual(previous, 1)
        XCTAssertGreaterThan(ZoomMath.graphicOpacity(progress: 0.9, returning: true), 0)
        XCTAssertEqual(ZoomMath.graphicOpacity(progress: 0.9, returning: false), 0)
    }

    func testReversingAnOpeningStartsReturnImmediatelyAndReopeningReleasesTheGraphicAgain() {
        for progress: CGFloat in [1, 0.9, 0.6, 0.3, 0] {
            XCTAssertTrue(ZoomMath.drawsGraphic(progress: progress, returning: true))
        }
        XCTAssertFalse(ZoomMath.drawsGraphic(progress: 1, returning: false))
        XCTAssertTrue(ZoomMath.drawsGraphic(progress: 0, returning: false))
    }
}
