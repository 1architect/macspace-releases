import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceApp

final class BlockLayoutTests: XCTestCase {
    private func segment(_ id: String, _ gb: Double, caution: Bool = false) -> UsageSegment {
        UsageSegment(id: id, label: id, bytes: UInt64(gb * 1_000_000_000), tone: caution ? .caution : .series(0))
    }

    /// Parts under 2% of the total are drawn as one block; every block keeps a minimum share, the amber one more; sizes stay real.
    func testSmallPartsMergeAndNoBlockIsASliver() {
        let parts = [segment("macos", 17.7), segment("support", 7.9), segment("apple", 3), segment("shared", 2.3), segment("caches", 2.2),
                     segment("brew", 2.1), segment("free", 0.62, caution: true), segment("cloud", 0.014), segment("tiny", 0.2)]
        let blocks = BlockLayout.blocks(parts)
        let total = parts.map { Double($0.bytes) }.reduce(0, +)
        XCTAssertFalse(blocks.contains { ["cloud", "tiny"].contains($0.segment.id) })
        let smaller = blocks.first { $0.segment.id == BlockLayout.smallerID }
        XCTAssertEqual(smaller?.segment.label, "2 smaller")
        XCTAssertEqual(smaller?.segment.bytes, 214_000_000, "the real size")
        XCTAssertTrue(blocks.allSatisfy { $0.weight >= total * BlockLayout.minimumShare - 1 })
        XCTAssertGreaterThanOrEqual(blocks.first { $0.segment.id == "free" }?.weight ?? 0, total * BlockLayout.actionShare - 1)
        XCTAssertEqual(blocks.first?.segment.id, "macos", "largest first")
        let smallerIndex = try! XCTUnwrap(blocks.firstIndex { $0.segment.id == BlockLayout.smallerID })
        XCTAssertEqual(BlockLayout.shade(of: segment("cloud", 0.014), in: blocks), BlockLayout.shade(at: smallerIndex, in: blocks), "drawn in the smaller ones' block")
    }

    /// One small part is kept as it is (merging one into "1 smaller" would only rename it), with its minimum share.
    func testOneSmallPartIsKept() {
        let blocks = BlockLayout.blocks([segment("big", 10), segment("small", 0.1)])
        XCTAssertEqual(blocks.map(\.segment.id), ["big", "small"])
    }

    /// A lone part under half a percent is left to the legend rather than drawn at the minimum share.
    func testALoneTinyPartIsLeftToTheLegend() {
        let blocks = BlockLayout.blocks([segment("big", 30), segment("mid", 4), segment("cloud", 0.014)])
        XCTAssertEqual(blocks.map(\.segment.id), ["big", "mid"])
    }

    /// No two blocks share a shade, however many there are; the shades run evenly from the largest to the smallest, and the amber
    /// block takes no place on the ramp. A part left out of the blocks has no shade.
    func testEveryBlockHasItsOwnShade() {
        for count in 2...9 {
            let parts = (0..<count).map { segment("p\($0)", Double(count - $0) * 3) } + [segment("free", 1, caution: true)]
            let blocks = BlockLayout.blocks(parts)
            let shades = blocks.indices.filter { blocks[$0].segment.tone != .caution }.map { BlockLayout.shade(at: $0, in: blocks) }
            XCTAssertEqual(Set(shades).count, shades.count, "\(count) blocks")
            XCTAssertEqual(shades.first, 0)
            XCTAssertEqual(shades.last, 1)
        }
        let blocks = BlockLayout.blocks([segment("big", 30), segment("mid", 4), segment("cloud", 0.014)])
        XCTAssertNil(BlockLayout.shade(of: segment("cloud", 0.014), in: blocks))
    }

    /// Arranged, no block is a thin strip: one large block and three small ones in a wide chart (Other System Files: the update,
    /// purgeable app files, container caches, the smaller ones) put the small ones in one column, each wide enough for its size.
    func testArrangementKeepsTheThinnestBlockWide() {
        let values = [10.7, 1.61, 1.16, 0.62]
        let rect = CGRect(x: 0, y: 0, width: 640, height: 146)
        let plain = Treemap.layout(values, in: rect).map { min($0.width, $0.height) }.min() ?? 0
        let arranged = Treemap.arranged(values, in: rect)
        let thinnest = arranged.map { min($0.width, $0.height) }.min() ?? 0
        XCTAssertGreaterThanOrEqual(thinnest, plain)
        XCTAssertGreaterThan(thinnest, 25)
        let area = arranged.map { $0.width * $0.height }.reduce(0, +)
        XCTAssertEqual(Double(area), Double(rect.width * rect.height), accuracy: 1, "the same space, filled")
        XCTAssertEqual(arranged[0].width * arranged[0].height, Treemap.layout(values, in: rect)[0].width * Treemap.layout(values, in: rect)[0].height,
                       accuracy: 1, "each block keeps its area")
    }

    /// A narrow block shows its size as the number over the unit.
    func testSizeSplitsIntoNumberAndUnit() {
        XCTAssertEqual(BlocksView.sizeParts(201_700_000).count, 2)
        XCTAssertEqual(BlocksView.sizeParts(201_700_000).joined(separator: " "), ByteFormat.string(201_700_000))
    }

    /// Corners shrink with the block: a tile's small blocks are not pills.
    func testCornerRadiusFollowsTheBlock() {
        XCTAssertEqual(BlocksView.radius(CGRect(x: 0, y: 0, width: 300, height: 140)), 6)
        XCTAssertLessThan(BlocksView.radius(CGRect(x: 0, y: 0, width: 40, height: 18)), 3)
        XCTAssertEqual(BlocksView.radius(CGRect(x: 0, y: 0, width: 4, height: 4)), 2)
    }
}

final class DitheredLightTests: XCTestCase {
    /// Averaged over a ring, the dithered light is the gradient it replaces (white at the peak in the middle, clear at the edge), to a
    /// small fraction of one level; pixel to pixel it varies, which is what hides the steps.
    func testDitheredLightAveragesToTheGradient() throws {
        let peak = 0.07
        let image = DitheredLight.make(peak: peak)
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let side = image.width, center = Double(side) / 2
        var sums = [Double](repeating: 0, count: 10), expected = [Double](repeating: 0, count: 10), counts = [Double](repeating: 0, count: 10)
        var values = Set<UInt8>()
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) + 0.5 - center, dy = Double(y) + 0.5 - center
                let t = (dx * dx + dy * dy).squareRoot() / center
                guard t < 1 else { continue }
                let ring = Int(t * 10)
                let alpha = data[(y * side + x) * 2 + 1]
                XCTAssertEqual(data[(y * side + x) * 2], alpha, "premultiplied white")
                sums[ring] += Double(alpha)
                expected[ring] += peak * (1 - t) * 255
                counts[ring] += 1
                if ring == 5 { values.insert(alpha) }
            }
        }
        for ring in 0..<10 {
            XCTAssertEqual(sums[ring] / counts[ring], expected[ring] / counts[ring], accuracy: 0.1, "ring \(ring)")
        }
        XCTAssertGreaterThan(values.count, 2, "neighbouring pixels are rounded differently")
    }
}
