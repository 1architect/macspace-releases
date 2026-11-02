import CoreGraphics
import MacSpaceSdk

/// One arrangement per live chart. Pointer movement reuses its geometry instead of sorting and tessellating the map again.
final class BlockGeometryCache {
    struct Value {
        var blocks: [(segment: UsageSegment, weight: Double)]
        var rects: [CGRect]
        var shades: [Double]
    }
    private var segments: [UsageSegment] = []
    private var size: CGSize = .zero
    private var order: CGSize = .zero
    private var look: ChartLook?
    private var cached: Value?
    private(set) var computations = 0
    func value(segments: [UsageSegment], size: CGSize, order: CGSize? = nil, look: ChartLook = .page) -> Value {
        let order = order ?? size
        if self.size == size, self.order == order, self.look == look, self.segments == segments, let cached { return cached }
        let blocks = BlockLayout.blocks(segments, limit: look.limit)
        let result = Value(blocks: blocks,
            rects: Treemap.arranged(blocks.map(\.weight), in: CGRect(origin: .zero, size: size), orderIn: CGRect(origin: .zero, size: order), style: look.style),
            shades: BlockLayout.shades(in: blocks))
        self.segments = segments; self.size = size; self.order = order; self.look = look; cached = result; computations += 1
        return result
    }
}
