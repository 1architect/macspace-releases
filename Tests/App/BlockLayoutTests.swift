import XCTest
import MacSpaceSdk
import MacSpacePlatform
@testable import MacSpaceApp

final class BlockLayoutTests: XCTestCase {
    private func segment(_ id: String, _ gb: Double, caution: Bool = false) -> UsageSegment {
        UsageSegment(id: id, label: id, bytes: UInt64(gb * 1_000_000_000), tone: caution ? .caution : .series(0))
    }

    /// Parts under 2% of the total are drawn as one block; every block keeps a minimum share, the amber one more, up to the part above it; sizes stay real.
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
        // The amber block's 7% would pass brew (2.1 GB): it is held to brew's size.
        XCTAssertEqual(blocks.first { $0.segment.id == "free" }?.weight, blocks.first { $0.segment.id == "brew" }?.weight)
        XCTAssertEqual(blocks.map(\.weight), blocks.map(\.weight).sorted(by: >), "largest first")
        XCTAssertEqual(blocks.first?.segment.id, "macos", "largest first")
        let smallerIndex = try! XCTUnwrap(blocks.firstIndex { $0.segment.id == BlockLayout.smallerID })
        XCTAssertEqual(BlockLayout.shade(of: segment("cloud", 0.014), in: blocks), BlockLayout.shade(at: smallerIndex, in: blocks), "drawn in the smaller ones' block")
    }

    /// What can be freed is never drawn larger than a part that is larger: held to the part above it, not raised past it.
    func testTheAmberBlockIsNotDrawnLargerThanLargerParts() {
        let parts = [segment("macos", 14.4), segment("support", 7.46), segment("protected", 3.4), segment("brew", 2.57),
                     segment("apple", 2.36), segment("shared", 2.24), segment("rest", 0.764), segment("free", 0.0885, caution: true)]
        let blocks = BlockLayout.blocks(parts)
        let weight = { (id: String) in blocks.first { $0.segment.id == id }?.weight ?? 0 }
        XCTAssertLessThanOrEqual(weight("free"), weight("rest"))
        XCTAssertLessThanOrEqual(weight("rest"), weight("shared"))
        XCTAssertEqual(blocks.last?.segment.id, "free")
    }

    /// The blocks stand in columns: any two blocks share their left and right edges or do not overlap across the chart at all.
    func testBlocksStandInColumns() {
        let values = [14.41, 7.45, 3.42, 2.57, 2.35, 2.24, 0.76, 0.15].map { $0 * 1e9 }
        for size in [CGSize(width: 320, height: 120), CGSize(width: 600, height: 300), CGSize(width: 200, height: 180)] {
            let rects = Treemap.arranged(values, in: CGRect(origin: .zero, size: size))
            for a in rects { for b in rects where a != b {
                let same = abs(a.minX - b.minX) < 0.01 && abs(a.maxX - b.maxX) < 0.01
                let apart = a.maxX <= b.minX + 0.01 || b.maxX <= a.minX + 0.01
                XCTAssertTrue(same || apart, "\(a) and \(b) at \(size)")
            } }
        }
    }

    /// Only the corners on the chart's own corners take the tile's concentric radius.
    func testOnlyTheChartsOuterCornersFollowTheTile() {
        let size = CGSize(width: 300, height: 100)
        let corner = BlocksView.shape(CGRect(x: 0, y: 0, width: 100, height: 100), in: size, corner: 4, outer: 7).cornerRadii
        XCTAssertEqual([corner.topLeading, corner.bottomLeading, corner.topTrailing, corner.bottomTrailing], [7, 7, 4, 4])
        let inside = BlocksView.shape(CGRect(x: 100, y: 0, width: 100, height: 50), in: size, corner: 4, outer: 7).cornerRadii
        XCTAssertEqual([inside.topLeading, inside.bottomLeading, inside.topTrailing, inside.bottomTrailing], [4, 4, 4, 4])
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

final class TreemapRestingOrderTests: XCTestCase {
    /// A tile on its way to another cell keeps the arrangement its blocks have at rest: they only stretch. Arranged at every size, the
    /// blocks re-flowed into another arrangement and back.
    func testBlocksKeepTheirRestingArrangementWhileTheTileMoves() {
        let values = [6.0, 3, 2, 1.4, 1]
        let rest = CGRect(x: 0, y: 0, width: 400, height: 90)
        let atRest = Treemap.arranged(values, in: rest)
        for size in [CGSize(width: 407, height: 92), CGSize(width: 300, height: 160), CGSize(width: 820, height: 330)] {
            let rects = Treemap.arranged(values, in: CGRect(origin: .zero, size: size), orderIn: rest)
            let sx = size.width / rest.width, sy = size.height / rest.height
            // The resting arrangement, stretched: the same blocks side by side, never another arrangement.
            for (moved, resting) in zip(rects, atRest) {
                XCTAssertEqual(moved.minX, resting.minX * sx, accuracy: 0.001)
                XCTAssertEqual(moved.minY, resting.minY * sy, accuracy: 0.001)
                XCTAssertEqual(moved.width, resting.width * sx, accuracy: 0.001)
                XCTAssertEqual(moved.height, resting.height * sy, accuracy: 0.001)
            }
        }
        XCTAssertEqual(Treemap.arranged(values, in: rest), Treemap.arranged(values, in: rest, orderIn: rest))
    }
}
