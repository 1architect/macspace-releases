import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

final class BlockGeometryCacheTests: XCTestCase {
    func testPointerReadsReuseGeometryAndResizeOrValuesInvalidateIt() {
        let cache = BlockGeometryCache()
        let segments = (0..<1000).map { UsageSegment(id: "\($0)", label: "Folder \($0)", bytes: UInt64(1000 - $0), tone: .series($0), pageID: "folder:\($0)") }
        let size = CGSize(width: 820, height: 400)
        let first = cache.value(segments: segments, size: size)
        for _ in 0..<100 { XCTAssertEqual(cache.value(segments: segments, size: size).rects, first.rects) }
        XCTAssertEqual(cache.computations, 1)
        _ = cache.value(segments: segments, size: CGSize(width: 700, height: 400))
        XCTAssertEqual(cache.computations, 2)
        var changed = segments; changed[0].bytes += 1
        _ = cache.value(segments: changed, size: size)
        XCTAssertEqual(cache.computations, 3)
        let shades = BlockLayout.shades(in: first.blocks)
        for i in [0, 1, 400, 999] { XCTAssertEqual(shades[i], BlockLayout.shade(at: i, in: first.blocks)) }
        XCTAssertEqual(first.blocks.count, segments.count, "Navigable folders must remain selectable")
    }
}
