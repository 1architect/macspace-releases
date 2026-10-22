import AppKit
import MacSpacePlatform
import MacSpaceSdk
import SwiftUI

/// A tile's ground: its color, lit faintly from the top left.
struct TileBackdrop: View {
    let tint: TileTint
    /// The corners: a tile's, growing to the window's as the tile becomes a page.
    var cornerRadius: CGFloat = Theme.tileRadius
    /// The module is reading the Mac: the ground darkens and lifts, again and again (`LoadingGlow`).
    var loading = false
    @Environment(\.design) private var design

    var body: some View {
        ground
            .overlay {
                if loading {
                    LoadingGlow(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .transition(.opacity.animation(.smooth(duration: 0.4)))
                }
            }
    }

    private var ground: some View {
        // Rounded itself: the tiles are no longer clipped to their shape. Lit by the studio's shading, by default the faint light from
        // the top left.
        let palette = design.palette(tint)
        return ShadedFill(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), color: palette.base, accent: palette.step(3),
                          fill: design.fill(.tile(tint)), shading: design.shading(.tile(tint)), light: design.isLight)
    }
}

/// A chart element's surface: flat color, lightened when highlighted.
struct Surface<S: Shape>: View, @preconcurrency Animatable {
    let shape: S
    let color: Color
    var highlighted = false
    /// How much of the color shows, 0...1: used by non-chart loading indicators and a block coming in. Animated frame by frame.
    var strength: Double = 1
    @Environment(\.design) private var design

    var animatableData: Double {
        get { strength }
        set { strength = newValue }
    }

    var body: some View {
        // A light laid over the color, not a brightness filter, which stays on even at 0 and costs an extra pass every frame.
        ShadedFill(shape: shape, color: color, accent: color.mix(with: .white, by: 0.4), fill: design.fill(.chartElements),
                   shading: design.shading(.chartElements), light: design.isLight)
            .overlay { shape.fill(.white.opacity(highlighted ? Self.flatHighlight : 0)) }
            .animation(Theme.highlight, value: highlighted)
            .opacity(strength)
    }

    /// How much a flat element lightens under the pointer.
    static var flatHighlight: Double { 0.1 }
}

extension View {
    /// The pointer tilt of a tile.
    func tilted(_ tilt: UnitPoint) -> some View {
        rotation3DEffect(.degrees((tilt.x - 0.5) * 5), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees((0.5 - tilt.y) * 5), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
    }
}

// MARK: Loading

/// A wave of brightness running through small progress indicators (loading dots, row flags, the menu bar icon). With Reduce Motion
/// they stay dimmed instead. Charts do not use this: their loading feedback is geometry from `ChartMotion`.
enum LoadingWave {
    static let period = 1.4

    /// How bright element `index` of `count` is at `date`: 1 when not loading.
    static func opacity(_ date: Date, index: Int, count: Int, loading: Bool, reduceMotion: Bool) -> Double {
        guard loading else { return 1 }
        guard !reduceMotion else { return 0.55 }
        let t = date.timeIntervalSinceReferenceDate / period - Double(index) / Double(max(count, 1)) * 0.8
        return 0.35 + 0.65 * (0.5 + 0.5 * cos(2 * .pi * t))
    }

    /// Where a running highlight is along its track, 0...1, looping.
    static func position(_ date: Date, period: Double = 1.2) -> Double {
        (date.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 1)
    }

    /// Blocks to animate while a tile has nothing to show yet.
    static let placeholderBlocks: [UsageSegment] = [6, 3, 2, 1.4, 1].enumerated().map { index, weight in
        UsageSegment(id: "loading-\(index)", label: "", bytes: UInt64(weight * 1_000), tone: .series(index))
    }

    /// These are the placeholders, not a module's figures.
    static func isPlaceholder(_ segments: [UsageSegment]) -> Bool {
        segments.contains { $0.id.hasPrefix("loading-") }
    }
}

// MARK: Blocks

/// Squarified treemap: rectangles with areas proportional to the values, kept as close to square as the space allows. Values are laid
/// out in the order given (largest first reads best), in columns side by side across the chart's long side, each column's blocks
/// stacked down it (rows down a chart taller than wide). The design tools' Widget Type window also offers one row of bars and the
/// classic treemap (`ChartStyle`).
enum Treemap {
    /// The squarified layout whose thinnest block is widest, over the orders of the blocks after the largest: laid out largest first,
    /// the last block took whatever strip was left (25 points wide and full height on a page, too narrow for its size). Returns where
    /// each value goes, in the order given. Up to seven values every order is tried; past that, the given one.
    ///
    /// `orderIn` is where the blocks are arranged, when it is not `rect`: a tile's resting chart. The arrangement found there is
    /// stretched to `rect`. Arranged anew in every frame of a tile growing into another cell, two orders that score alike took
    /// turns, and even in one order the rows broke differently as the chart's proportions changed: the blocks re-flowed into another
    /// arrangement and back (2026-10-12). Arranged at rest, they only stretch while the tile moves.
    static func arranged(_ values: [Double], in rect: CGRect, orderIn: CGRect? = nil, style: ChartStyle = .columns) -> [CGRect] {
        let base = orderIn ?? rect
        let order = style == .bars ? Array(values.indices) : order(values, in: base, style: style)
        let rects = layout(order.map { values[$0] }, in: base, style: style)
        var result = [CGRect](repeating: .zero, count: values.count)
        for (position, index) in order.enumerated() { result[index] = rects[position] }
        guard base != rect, base.width > 0, base.height > 0 else { return result }
        let sx = rect.width / base.width, sy = rect.height / base.height
        return result.map { r in
            CGRect(x: rect.minX + (r.minX - base.minX) * sx, y: rect.minY + (r.minY - base.minY) * sy, width: r.width * sx, height: r.height * sy)
        }
    }

    /// The order `arranged` lays the values out in, by index.
    /// Orders already worked out: the search below lays the blocks out up to 720 times, and every drawing of a chart and every
    /// pointer move over one asked again for the same figures.
    private static let ordersLock = NSLock()
    nonisolated(unsafe) private static var orders: [String: [Int]] = [:]

    static func order(_ values: [Double], in rect: CGRect, style: ChartStyle = .columns) -> [Int] {
        guard values.count > 2, values.count <= 7 else { return Array(values.indices) }
        let key = "\(style)|\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))|" + values.map { String($0) }.joined(separator: ",")
        if let known = ordersLock.withLock({ orders[key] }) { return known }
        let found = searchOrder(values, in: rect, style: style)
        ordersLock.withLock {
            if orders.count > 256 { orders.removeAll() }
            orders[key] = found
        }
        return found
    }

    private static func searchOrder(_ values: [Double], in rect: CGRect, style: ChartStyle) -> [Int] {
        func thinnest(_ rects: [CGRect]) -> CGFloat {
            rects.filter { $0.width > 0.5 && $0.height > 0.5 }.map { min($0.width, $0.height) }.min() ?? 0
        }
        var best: (order: [Int], rects: [CGRect], score: CGFloat)?
        func visit(_ order: [Int], _ rest: [Int]) {
            guard !rest.isEmpty else {
                let rects = layout(order.map { values[$0] }, in: rect, style: style)
                let score = thinnest(rects)
                // Only a clearly wider thinnest block replaces an earlier order: the given one first, so it wins ties.
                if best == nil || score > best!.score + 0.5 { best = (order, rects, score) }
                return
            }
            for (index, next) in rest.enumerated() {
                var remaining = rest
                remaining.remove(at: index)
                visit(order + [next], remaining)
            }
        }
        visit([0], Array(1..<values.count))
        return best?.order ?? Array(values.indices)
    }

    static func layout(_ values: [Double], in rect: CGRect, style: ChartStyle = .columns) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        if style == .bars { return bars(values, total: total, in: rect) }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = Array(areas.indices)
        var space = rect
        let wide = rect.width >= rect.height

        func worst(_ row: [Int], _ side: Double) -> Double {
            let sum = row.reduce(0) { $0 + areas[$1] }
            guard sum > 0, side > 0 else { return .infinity }
            let largest = row.map { areas[$0] }.max() ?? 0, smallest = row.map { areas[$0] }.min() ?? 0
            guard smallest > 0 else { return .infinity }
            return max(side * side * largest / (sum * sum), (sum * sum) / (side * side * smallest))
        }

        while !remaining.isEmpty {
            // The space is used up (only empty values left, or what rounding leaves): the rest take no room at its corner. Divided by
            // a side of zero, they came out at an infinite size.
            guard space.width > 0.001, space.height > 0.001 else {
                for index in remaining { result[index] = CGRect(origin: space.origin, size: .zero) }
                break
            }
            // Always columns across a wide chart: the squarified layout turns its strips to the shorter side of what is left, and
            // once the space left was taller than wide, its blocks were laid in rows across a column, a block of a row reaching
            // under two columns beside it and blocks of different heights side by side (2026-10-13).
            // The classic treemap turns each strip to the shorter side of the space left.
            let columns = style == .treemap ? space.width >= space.height : wide
            let side = Double(columns ? space.height : space.width)
            var row = [remaining.removeFirst()]
            while let next = remaining.first, worst(row + [next], side) <= worst(row, side) {
                row.append(remaining.removeFirst())
            }
            let sum = row.reduce(0) { $0 + areas[$1] }
            if columns {
                let width = CGFloat(sum / Double(space.height))
                var y = space.minY
                for index in row {
                    let height = CGFloat(areas[index]) / max(width, 0.0001)
                    result[index] = CGRect(x: space.minX, y: y, width: width, height: height)
                    y += height
                }
                space = CGRect(x: space.minX + width, y: space.minY, width: max(space.width - width, 0), height: space.height)
            } else {
                let height = CGFloat(sum / Double(space.width))
                var x = space.minX
                for index in row {
                    let width = CGFloat(areas[index]) / max(height, 0.0001)
                    result[index] = CGRect(x: x, y: space.minY, width: width, height: height)
                    x += width
                }
                space = CGRect(x: space.minX, y: space.minY + height, width: space.width, height: max(space.height - height, 0))
            }
        }
        return result
    }

    /// One row of bars across the chart's long side, each its share of it and the chart's whole other side.
    private static func bars(_ values: [Double], total: Double, in rect: CGRect) -> [CGRect] {
        var offset: CGFloat = 0
        return values.map { value in
            let share = CGFloat(value / total)
            defer { offset += share }
            return rect.width >= rect.height
                ? CGRect(x: rect.minX + offset * rect.width, y: rect.minY, width: share * rect.width, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY + offset * rect.height, width: rect.width, height: share * rect.height)
        }
    }
}

/// What the blocks draw, so that every part can be seen and pointed at. Parts under 2% of the total are drawn as one block ("3
/// smaller"), and every block takes at least a share of the area, more for what can be freed (the page's main action). The sizes
/// shown stay the real ones, and no block is drawn larger than a part that is larger; the legend still lists every part. Drawn to scale, a part was a sliver a pixel or two wide, or nothing
/// at all (13.8 MB of 35 GB), and the amber block a thin strip at the far edge.
enum BlockLayout {
    static let mergeBelow = 0.02
    /// A part this small with no other small part to join is left to the legend: drawn at the minimum share, 13.8 MB of 35 GB looked
    /// like a gigabyte.
    static let dropBelow = 0.005
    static let minimumShare = 0.035
    static let actionShare = 0.07
    static let smallerID = "blocks.smaller"

    /// The blocks in the order they are laid out, largest first, with what each one is drawn at.
    /// `limit` is the most blocks drawn, the orange one included (a tile's, `ChartLook.limit`): past it, the smallest parts are
    /// drawn as one block with the ones under 2%.
    static func blocks(_ segments: [UsageSegment], limit: Int? = nil) -> [(segment: UsageSegment, weight: Double)] {
        let total = Double(segments.map(\.bytes).reduce(0, +))
        guard total > 0 else { return segments.map { ($0, Double($0.bytes)) } }
        var shown = segments
        var small = segments.filter { $0.tone != .caution && Double($0.bytes) < total * mergeBelow }
        if let limit {
            let cautions = segments.filter { $0.tone == .caution }.count
            let others = segments.filter { $0.tone != .caution }.sorted { $0.bytes > $1.bytes }
            let alone = others.filter { part in !small.contains { $0.id == part.id } }
            // One place for the block of the smaller ones, once any part goes into it.
            let room = max(limit - cautions - 1, 1)
            if alone.count + cautions + min(small.count, 1) > limit, alone.count > room {
                small += alone[room...]
            }
        }
        if small.count >= 2 {
            let ids = Set(small.map(\.id))
            shown = segments.filter { !ids.contains($0.id) }
            shown.append(UsageSegment(id: smallerID, label: String(localized: "\(small.count) smaller"), bytes: small.map(\.bytes).reduce(0, +), tone: .series(segments.count)))
        } else if let only = small.first, Double(only.bytes) < total * dropBelow {
            shown = segments.filter { $0.id != only.id }
        }
        // No block drawn larger than a part that is really larger: the amber block's share is a floor, not a lift past its
        // neighbours. Raised to its 7% on its own, 88.5 MB of 33 GB drew larger than 764 MB and 2.24 GB beside it, and 10.1 MB
        // larger than 68.5 MB (2026-10-13). Held to the part above it, it is drawn as large as that one at most.
        var cap = Double.infinity
        return shown.sorted { $0.bytes > $1.bytes }.map { segment in
            let weight = min(max(Double(segment.bytes), total * (segment.tone == .caution ? actionShare : minimumShare)), cap)
            cap = weight
            return (segment, weight)
        }
    }

    /// Where a block's color sits on its tile's ramp, 0 (the largest, close to the ground) to 1 (the smallest, the strongest):
    /// spread evenly over the blocks drawn, so no two share a color however many there are. A fixed step per rank ran out after five,
    /// and the sixth and seventh blocks took the colors of the fourth and fifth. What can be freed is the action color and takes no
    /// place on the ramp.
    static func shade(at index: Int, in blocks: [(segment: UsageSegment, weight: Double)]) -> Double {
        let ramp = blocks.indices.filter { blocks[$0].segment.tone != .caution }
        guard ramp.count > 1, let position = ramp.firstIndex(of: index) else { return 0 }
        return Double(position) / Double(ramp.count - 1)
    }

    /// The shade of the block a part is drawn in: its own, or the block of the smaller ones. nil for a part left to the legend.
    static func shade(of segment: UsageSegment, in blocks: [(segment: UsageSegment, weight: Double)]) -> Double? {
        if let index = blocks.firstIndex(where: { $0.segment.id == segment.id }) { return shade(at: index, in: blocks) }
        let drawnAlone = segments(drawnIn: blocks)
        guard !drawnAlone.contains(segment.id), let smaller = blocks.firstIndex(where: { $0.segment.id == smallerID }) else { return nil }
        return shade(at: smaller, in: blocks)
    }

    private static func segments(drawnIn blocks: [(segment: UsageSegment, weight: Double)]) -> Set<String> { Set(blocks.map(\.segment.id)) }
}

/// The color of a block: what can be freed is the action color; the rest go from close to the ground (the largest) to strong (the
/// smallest), at their shade (`BlockLayout.shade`), mixed between the palette's steps.
enum BlockColor {
    /// Where a shade falls among the palette's steps: 1 (just off the ground) to 5.
    static func position(_ shade: Double) -> Double { 1 + min(max(shade, 0), 1) * 4 }

    static func fill(_ segment: UsageSegment, shade: Double, tint: TileTint, design: Design) -> Color {
        if segment.tone == .caution { return design.action }
        let palette = design.palette(tint)
        let position = position(shade)
        let lower = Int(position.rounded(.down))
        guard lower < 5 else { return palette.step(5) }
        return palette.step(lower).mix(with: palette.step(lower + 1), by: position - Double(lower), in: .perceptual)
    }

    static func label(_ segment: UsageSegment, shade: Double, tint: TileTint, design: Design) -> Color {
        if segment.tone == .caution { return design.actionDeep }
        let palette = design.palette(tint)
        // The strong end of the ramp is light by night and dark by day: the ground color reads on it, the text color does not.
        return position(shade) >= 3.6 ? palette.base : palette.text
    }
}

/// Blocks sized by bytes. Large enough blocks carry their name and size; the hovered block lights up. They grow in one after another
/// when they appear and glide to new sizes. While their figures are read anew they open out with the reading, and the amber block
/// drains as it is freed (`ChartMotion`).
struct BlocksView: View {
    let segments: [UsageSegment]
    let tint: TileTint
    var labels = true
    var hovered: String?
    var gap: CGFloat = 3
    /// The radius of the chart's outer corners, when it sits in a rounded tile: concentric with the tile's corners (the tile's radius
    /// less the margin to the chart). Only the corners on the chart's edge take it; the corners between blocks keep the blocks' own.
    var outerRadius: CGFloat?
    /// The layout and the most blocks drawn: a page's unless the tile says (`ChartLook.tile`).
    var look = ChartLook.page
    var loading = false
    /// The figures are being read anew, and the blocks open out with it (`ChartMotion`): last session's figures, or the user's
    /// Refresh. Not a cleanup's reading, nor one in the background. `fill` is how far it has come.
    var reading = false
    var fill: LoadFill?
    /// A page action is changing the figures represented by this chart. It uses the same geometric opening motion as a reading,
    /// driven by the action's progress when it has one. `loading` remains the page/tile state and never animates block opacity.
    var working = false
    var workingFraction: Double?
    /// Where the blocks are arranged (`Treemap.arranged`), when not at the size drawn: a tile's chart at rest, so a tile moving to
    /// another cell only stretches its blocks. Each chart is arranged at its own shape, as in 1.0.3: one shape for every chart
    /// (320 by 120, stretched to each) drew blocks that did not fit the chart around them, tall slivers on a large tile (2026-10-13).
    var orderSize: CGSize?
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var appeared = false
    /// The blocks are opening out with a reading (`ChartMotion`); nil otherwise, and once every block is open.
    @State private var growth: Growth?
    /// The figures still drawn while the blocks open or the amber block drains: the new ones come in after, as the usual glide.
    @State private var held: [UsageSegment]?
    /// When the amber block, draining by itself, is done.
    @State private var drainEnds: Date?
    /// A pretend reading the Chart Motion window plays (development builds), in place of the module's.
    @State private var rehearsal: LoadFill?
    @State private var motion = BlockMotion()

    struct Growth: Hashable {
        /// nil while the placeholders are drawn: the first figures start closed.
        var start: Date?
        /// Refresh: the blocks first close into their corners.
        var closing = false
    }

    init(segments: [UsageSegment], tint: TileTint, labels: Bool = true, hovered: String? = nil, gap: CGFloat = 3, outerRadius: CGFloat? = nil,
         look: ChartLook = .page, loading: Bool = false, reading: Bool = false, fill: LoadFill? = nil,
         working: Bool = false, workingFraction: Double? = nil, orderSize: CGSize? = nil) {
        self.segments = segments
        self.tint = tint
        self.labels = labels
        self.hovered = hovered
        self.gap = gap
        self.outerRadius = outerRadius
        self.look = look
        self.loading = loading
        self.reading = reading
        self.fill = fill
        self.working = working
        self.workingFraction = workingFraction
        self.orderSize = orderSize
        // Drawn while its figures are being read: the blocks open with it. Drawn with placeholders: the first figures open when they come.
        _growth = State(initialValue: LoadingWave.isPlaceholder(segments) ? Growth(start: nil) : (reading || working) ? Growth(start: Date()) : nil)
    }

    /// A size split into its number and unit ("201,7 MB" -> ["201,7", "MB"]), for a narrow block.
    static func sizeParts(_ bytes: UInt64) -> [String] {
        let text = ByteFormat.string(bytes)
        guard let space = text.lastIndex(of: " ") else { return [text] }
        return [String(text[..<space]), String(text[text.index(after: space)...])]
    }

    /// A block's corner radius: 6 points on a page's large blocks, less on a tile's small ones, where 6 made them pills.
    static func radius(_ rect: CGRect) -> CGFloat { min(6, max(2, min(rect.width, rect.height) * 0.16)) }

    /// One radius for every block of a chart: the smallest block's. Each block sized its own, and on a small tile the large blocks
    /// were rounder than the small ones beside them (2026-10-12).
    static func radius(for rects: [CGRect]) -> CGFloat {
        rects.filter { $0.width > 0.5 && $0.height > 0.5 }.map(radius).min() ?? 6
    }

    /// A block's shape: `corner` at each corner, but `outer` at the corners on the chart's own corners (`outerRadius`), never more
    /// than half the block's shorter side.
    static func shape(_ rect: CGRect, in size: CGSize, corner: CGFloat, outer: CGFloat?) -> UnevenRoundedRectangle {
        guard let outer, outer > corner else { return UnevenRoundedRectangle(cornerRadii: .init(topLeading: corner, bottomLeading: corner, bottomTrailing: corner, topTrailing: corner), style: .continuous) }
        let round = min(outer, min(rect.width, rect.height) / 2)
        let left = rect.minX < 0.5, right = rect.maxX > size.width - 0.5, top = rect.minY < 0.5, bottom = rect.maxY > size.height - 0.5
        return UnevenRoundedRectangle(cornerRadii: .init(topLeading: top && left ? round : corner, bottomLeading: bottom && left ? round : corner,
                                                         bottomTrailing: bottom && right ? round : corner, topTrailing: top && right ? round : corner),
                                      style: .continuous)
    }

    /// What can be freed, in bytes: the amber parts.
    static func amber(_ segments: [UsageSegment]) -> UInt64 {
        segments.filter { $0.tone == .caution }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        let segments = held ?? self.segments
        GeometryReader { proxy in
            let blocks = BlockLayout.blocks(segments, limit: look.limit)
            let shown = blocks.map(\.segment)
            let shades = shown.indices.map { BlockLayout.shade(at: $0, in: blocks) }
            let rects = Treemap.arranged(blocks.map(\.weight), in: CGRect(origin: .zero, size: proxy.size),
                                         orderIn: CGRect(origin: .zero, size: orderSize ?? proxy.size), style: look.style)
            let corner = Self.radius(for: rects.map(inset))
            // Opening with a reading, draining what was freed: not the placeholders, nor with Reduce Motion.
            let plan = growth != nil && !reduceMotion && !LoadingWave.isPlaceholder(segments) && !blocks.isEmpty
                ? GrowPlan(rects: rects.map(inset), weights: blocks.map(\.weight)) : nil
            let draining = !reduceMotion && drainEnds != nil && shown.contains { $0.tone == .caution }
            let moving = plan != nil || draining
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !moving || reduceMotion || !appearsActive)) { context in
                let growing = plan.map { opening($0, ids: shown.map(\.id), at: context.date) }
                let opens = growing?.opens
                // The chart's width while it grows: some room kept empty at its right, sprung into at the end (`ChartMotion.finishRoom`).
                let width = growing?.width ?? 1
                let drain = draining ? drained(at: context.date) : 0
                // Two layers moved alike: the blocks, then their names over them.
                ZStack(alignment: .topLeading) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, segment in
                        let rect = Self.narrowed(inset(rects[index]), to: width)
                        let drawn = motionRect(rect, index: index, amber: segment.tone == .caution, opens: opens, drain: drain)
                        let fill = BlockColor.fill(segment, shade: shades[index], tint: tint, design: design)
                        let shape = Self.shape(rects[index], in: proxy.size, corner: corner, outer: outerRadius.map { $0 - gap / 2 })
                        placed(Surface(shape: shape, color: fill, highlighted: hovered == segment.id,
                                       strength: appeared || plan != nil ? 1 : 0),
                               index: index, rect: drawn, grown: appeared || plan != nil ? 1 : 0.6)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, segment in
                        let rect = Self.narrowed(inset(rects[index]), to: width)
                        let drawn = motionRect(rect, index: index, amber: segment.tone == .caution, opens: opens, drain: drain)
                        let moved = drawn != rect
                        let shape = Self.shape(rects[index], in: proxy.size, corner: corner, outer: outerRadius.map { $0 - gap / 2 })
                        // While the block opens or drains, its name is laid out for the whole block and the block shows it as it moves,
                        // rather than wrapping it anew at every frame. Otherwise the frames are nil: the name fills the block as it always did.
                        // Its outline is the block's as drawn: laid out with the name at the whole block's size, it lost its right
                        // edge while the block opened (2026-10-22).
                        placed(overlay(segment, shade: shades[index], rect: rect, shape: shape, outlined: !moved)
                                   .opacity(appeared ? 1 : 0)
                                   .frame(width: moved ? rect.width : nil, height: moved ? rect.height : nil)
                                   .frame(width: moved ? drawn.width : nil, height: moved ? drawn.height : nil, alignment: .topLeading)
                                   .clipped()
                                   .overlay { if moved { outline(segment, shape: shape) } },
                               index: index, rect: drawn, grown: appeared || plan != nil ? 1 : 0.6)
                    }
                }
            }
            .animation(ChartMotion.glide, value: shown)
        }
        .onAppear { appeared = true }
        // Refresh: the chart on screen closes into its corners and opens again with the reading.
        .onChange(of: reading) { _, reading in
            guard reading, growth == nil, !reduceMotion, !LoadingWave.isPlaceholder(self.segments) else { return }
            motion.restartGrowth()
            growth = Growth(start: Date(), closing: true)
        }
        // A page action uses the chart's geometric motion too. The old loading pulse is intentionally not restored: the current
        // figures close, then open with the action's progress while the work runs.
        .onChange(of: working) { _, working in
            guard working, growth == nil, !reduceMotion, !LoadingWave.isPlaceholder(self.segments) else { return }
            motion.restartGrowth()
            growth = Growth(start: Date(), closing: true)
        }
        .onChange(of: self.segments) { old, new in received(old, new) }
        // The Chart Motion window's Replay (development builds): the reading again, a pretend one of the seconds it says.
        .onReceive(NotificationCenter.default.publisher(for: ChartMotion.replay)) { note in
            guard !reduceMotion, !LoadingWave.isPlaceholder(self.segments) else { return }
            let start = Date(), count = BlockLayout.blocks(self.segments, limit: look.limit).count
            motion.restartGrowth()
            rehearsal = LoadFill(started: start.addingTimeInterval(ChartMotion.closingTotal(count: count)), expected: note.object as? Double ?? 3)
            growth = Growth(start: start, closing: true)
        }
        // Every block open: the figures read meanwhile come in.
        .task(id: growth) {
            guard let start = growth?.start else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.25))
                let stuck = reduceMotion || (held ?? self.segments).isEmpty || Date().timeIntervalSince(start) > 120
                if stuck || motion.settled {
                    growth = nil
                    held = nil
                    rehearsal = nil
                    motion.restartGrowth()
                    return
                }
            }
        }
        // The amber block drained by itself: the other blocks take its room.
        .task(id: drainEnds) {
            guard let drainEnds else { return }
            try? await Task.sleep(for: .seconds(max(drainEnds.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled else { return }
            motion.endDrain()
            held = nil
            self.drainEnds = nil
        }
    }

    /// New figures. The first ones, after the placeholders, open from their left sides. While the blocks open or the amber block drains,
    /// they wait for it to end. When less can be freed than before (something was), the amber block first drains by the share that
    /// went, then the chart glides to them. Otherwise they come in as they always did.
    private func received(_ old: [UsageSegment], _ new: [UsageSegment]) {
        if LoadingWave.isPlaceholder(old), !LoadingWave.isPlaceholder(new) {
            held = nil
            motion.restartGrowth()
            growth = reduceMotion ? nil : Growth(start: Date())
            return
        }
        guard !reduceMotion else { held = nil; return }
        if growth != nil || drainEnds != nil {
            if held == nil { held = old }
            return
        }
        let before = Self.amber(old), after = Self.amber(new)
        if before > 0, after < before, old.contains(where: { $0.tone == .caution }) {
            held = old
            motion.swap = (Date(), 0, 1 - Double(after) / Double(before))
            drainEnds = Date().addingTimeInterval(ChartMotion.draining / ChartMotion.speed)
        } else {
            held = nil
        }
    }

    /// How much of its width each block has opened to at `date`: after a Refresh, closing onto its left side, last first; then opening
    /// with the reading, each over its stretch of it (`GrowPlan`), its width following as a spring. The reading drawn is smoothed and
    /// creeps on while the real one says nothing new (`ChartMotion.drawnReading`); once it is over, it runs to the end.
    private func opening(_ plan: GrowPlan, ids: [String], at date: Date) -> (opens: [CGFloat], width: CGFloat) {
        var opens = [CGFloat](repeating: 0, count: ids.count)
        let room = min(max(ChartMotion.finishRoom, 0), 0.5)
        guard let growth, let start = growth.start else { return (opens, CGFloat(1 - room)) }
        var from = start
        if growth.closing {
            let closing = ChartMotion.closingTotal(count: ids.count)
            let closed = start.addingTimeInterval(closing)
            if date < closed {
                for (position, index) in plan.sequence.reversed().enumerated() {
                    opens[index] = ChartMotion.closed(after: date.timeIntervalSince(start) * ChartMotion.speed - Double(position) * ChartMotion.closeStagger)
                }
                // The room opens as the blocks close.
                return (opens, CGFloat(1 - room * ChartMotion.easeInOut(date.timeIntervalSince(start) / max(closing, 0.01))))
            }
            from = closed
        }
        // Seconds since the last frame, at the speed set.
        let dt = (motion.frame.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0) * ChartMotion.speed
        motion.frame = date
        let active: Bool, real: Double
        if let rehearsal {
            active = date < rehearsal.started.addingTimeInterval(rehearsal.expected)
            real = active ? rehearsal.fraction(at: date) : 1
        } else if working {
            active = true
            if let workingFraction, workingFraction.isFinite {
                real = min(max(workingFraction, 0), 1)
            } else {
                // An action with no measured progress still gets the same quick-then-slow geometric motion as an unmeasured read.
                real = LoadFill(started: from, expected: LoadFill.firstGuess).fraction(at: date)
            }
        } else {
            active = self.reading
            real = active ? (fill ?? LoadFill(started: from, expected: LoadFill.firstGuess)).fraction(at: date) : 1
        }
        if real > motion.lastReal + 0.0001 || motion.lastMoved == nil {
            motion.lastReal = max(real, motion.lastReal)
            motion.lastMoved = date
        }
        let stalled = active ? date.timeIntervalSince(motion.lastMoved ?? date) * ChartMotion.speed : 0
        // The reading is over: the reading drawn catches up at once (`ChartMotion.ending`) rather than at its usual smoothing, so the
        // finish comes with the end of the load and not seconds after it.
        if !active, motion.endedAt == nil { motion.endedAt = date }
        motion.reading = motion.endedAt == nil
            ? ChartMotion.drawnReading(motion.reading, reading: motion.lastReal, stalled: stalled, over: dt)
            : motion.reading + (1 - motion.reading) * (1 - exp(-dt / ChartMotion.ending))
        var open = true
        for index in plan.sequence {
            var width = motion.widths[ids[index]] ?? (0, 0)
            ChartMotion.follow(&width, to: plan.target(index, at: motion.reading), over: dt)
            motion.widths[ids[index]] = width
            if abs(width.x - 1) > 0.003 || abs(width.v) > 0.02 { open = false }
            opens[index] = CGFloat(min(max(width.x, 0), 1.15))
        }
        // The load is over and the reading drawn has caught up: the finish springs the chart into its room, while the last blocks
        // still settle; the growth is over once both have come to rest.
        if motion.endedAt != nil, motion.reading > 0.98, motion.openedAt == nil { motion.openedAt = date }
        guard let openedAt = motion.openedAt else {
            motion.settled = false
            return (opens, CGFloat(1 - room))
        }
        let finish = date.timeIntervalSince(openedAt)
        motion.settled = open && finish >= ChartMotion.finishTotal
        let sprung = finish >= ChartMotion.finishTotal ? 1 : ChartMotion.spring(finish * ChartMotion.speed, bounce: ChartMotion.finishBounce, duration: ChartMotion.finishSpring)
        return (opens, CGFloat(1 - room * (1 - sprung)))
    }

    /// A block's rectangle in a chart drawn at `width` of its own width, from its left edge.
    static func narrowed(_ rect: CGRect, to width: CGFloat) -> CGRect {
        guard width != 1 else { return rect }
        return CGRect(x: rect.minX * width, y: rect.minY, width: rect.width * width, height: rect.height)
    }

    /// How much of the amber block has drained at `date`: by the share that was freed, while its place stays.
    private func drained(at date: Date) -> Double {
        guard let swap = motion.swap else { return 0 }
        motion.drain = swap.from + (swap.to - swap.from) * ChartMotion.easeInOut(date.timeIntervalSince(swap.start) * ChartMotion.speed / max(ChartMotion.draining, 0.01))
        return motion.drain
    }

    /// Where a block is drawn while it opens or drains: from its left side, as far as it has opened; the amber block drains back onto
    /// its left side.
    private func motionRect(_ rect: CGRect, index: Int, amber: Bool, opens: [CGFloat]?, drain: Double) -> CGRect {
        var open = opens?[index] ?? 1
        if amber, drain > 0 { open *= CGFloat(1 - min(max(drain, 0), 1)) }
        return open == 1 ? rect : GrowPlan.drawn(rect, open: open)
    }

    /// A block's rectangle less its share of the gap. A block thinner than the gap keeps its place at no width; inset as usual, it
    /// became a null rectangle, at infinity, and its glass stayed wherever it had last been drawn.
    private func inset(_ rect: CGRect) -> CGRect {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { return .zero }
        return rect.insetBy(dx: min(gap / 2, rect.width / 2), dy: min(gap / 2, rect.height / 2))
    }

    /// A block's place and its coming in (growing from its middle); the same for the block and for its name. The color comes in with
    /// it (`appeared` in the surface's strength). A block opening with a reading (`ChartMotion`) is placed where it has opened to,
    /// `grown` 1 and no fade.
    private func placed(_ view: some View, index: Int, rect: CGRect, grown: Double) -> some View {
        view
            .modifier(BlockFrame(rect: rect, grown: grown))
            .animation(Theme.layout.delay(Double(index) * 0.05), value: appeared)
    }

    /// A block's outline: shown when hovered.
    private func outline(_ segment: UsageSegment, shape: UnevenRoundedRectangle) -> some View {
        shape
            .strokeBorder(.white.opacity(hovered == segment.id ? 0.5 : 0), lineWidth: 1)
            .animation(Theme.highlight, value: hovered)
    }

    /// What is drawn over a block: its name and size when it is large enough, and an outline when hovered.
    private func overlay(_ segment: UsageSegment, shade: Double, rect: CGRect, shape: UnevenRoundedRectangle, outlined: Bool = true) -> some View {
        ZStack(alignment: .topLeading) {
            if outlined { outline(segment, shape: shape) }
            // A name comes and goes as resizing the window gives its block room or takes it: the name and size where they fit (the
            // name on two lines in a tall block rather than cut short), the size alone in a narrow one.
            if labels, rect.width > 46, rect.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    // As many lines as the block has room for under the size, up to three, rather than a name cut short.
                    ChangingText(text: segment.label).font(.system(size: 11, weight: .medium)).lineLimit(max(1, min(3, Int((rect.height - 26) / 14))))
                        .minimumScaleFactor(0.8)
                    ChangingText(text: ByteFormat.string(segment.bytes)).font(.system(size: 11)).opacity(0.8).lineLimit(1).minimumScaleFactor(0.75)
                }
                .foregroundStyle(BlockColor.label(segment, shade: shade, tint: tint, design: design))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .transition(.opacity.combined(with: .scale(scale: 0.86, anchor: .topLeading)).animation(Theme.layout))
            } else if labels, rect.width > 34, rect.height > 20 {
                // The size alone: on one line, or the number over its unit in a narrow block; never cut.
                ViewThatFits(in: .horizontal) {
                    ChangingText(text: ByteFormat.string(segment.bytes)).font(.system(size: 10)).lineLimit(1).fixedSize()
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(Self.sizeParts(segment.bytes).enumerated()), id: \.offset) { ChangingText(text: $0.element).font(.system(size: 10)).lineLimit(1).fixedSize() }
                    }
                    Color.clear.frame(width: 0, height: 0)
                }
                .foregroundStyle(BlockColor.label(segment, shade: shade, tint: tint, design: design).opacity(0.85))
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .transition(.opacity.animation(Theme.layout))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    /// The block under a point, for hover: a part's own block, or the block of the smaller ones (`BlockLayout`).
    static func segment(at point: CGPoint, in size: CGSize, segments: [UsageSegment], orderSize: CGSize? = nil,
                        look: ChartLook = .page) -> UsageSegment? {
        let blocks = BlockLayout.blocks(segments, limit: look.limit)
        let rects = Treemap.arranged(blocks.map(\.weight), in: CGRect(origin: .zero, size: size),
                                     orderIn: CGRect(origin: .zero, size: orderSize ?? size), style: look.style)
        return zip(blocks, rects).first { $0.1.contains(point) }?.0.segment
    }
}

/// Sizes and places a block by layout, worked out again on every frame of a movement, so its glass (an AppKit view, which SwiftUI does
/// not size frame by frame) grows and moves with it.
private struct BlockFrame: ViewModifier, @preconcurrency Animatable {
    var rect: CGRect
    /// The share of its size the block has while it comes in, from its middle.
    var grown: Double

    var animatableData: AnimatablePair<CGRect.AnimatableData, Double> {
        get { AnimatablePair(rect.animatableData, grown) }
        set {
            rect.animatableData = newValue.first
            grown = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: max(rect.width * grown, 0), height: max(rect.height * grown, 0))
            .position(x: rect.midX, y: rect.midY)
    }
}

/// A loading tile or page: a shade over its ground that deepens and lifts, again and again, while its chart uses geometric motion. A
/// shade, not a light: brightening washed the pale grounds out. A timeline of 30 frames a second that rests while its window is not
/// in front: a repeating animation was worked out by the app at every frame of the display (120 a second), and went on in a closed
/// or hidden window, keeping MacSpace at 5% CPU in the menu bar.
struct LoadingGlow<S: Shape>: View {
    let shape: S
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.design) private var design

    var body: some View {
        let deepest = design.isLight ? 0.09 : 0.18
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !appearsActive)) { context in
            // Deepens and lifts every 1.8 seconds, easing at both ends.
            let phase = 0.5 - 0.5 * cos(2 * .pi * context.date.timeIntervalSinceReferenceDate / 1.8)
            shape.fill(.black).opacity(reduceMotion ? 0.05 : deepest * phase)
        }
        .allowsHitTesting(false)
    }
}

// MARK: Dots

/// One dot per item: filled when done, a ring while not, amber when it needs the user. They fill in one after another.
struct DotsView: View {
    let dots: [TileDot]
    let tint: TileTint
    var diameter: CGFloat = 15
    var spacing: CGFloat = 7
    var columns = 7
    var loading = false
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var appeared = false

    /// As many columns as make the rows even: up to `columns` a row, and the dots shared out over the rows that takes, so 12 dots are
    /// two rows of 6, not 7 and 5.
    static func columns(for count: Int, atMost columns: Int) -> Int {
        guard count > 0, columns > 0 else { return max(columns, 1) }
        let rows = (count + columns - 1) / columns
        return (count + rows - 1) / rows
    }

    var body: some View {
        let palette = design.palette(tint)
        let columns = Self.columns(for: dots.count, atMost: columns)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(diameter), spacing: spacing), count: columns), alignment: .leading, spacing: spacing) {
            ForEach(Array(dots.enumerated()), id: \.offset) { index, dot in
                ZStack {
                    // Only an open dot is a ring: under a filled one it showed through, and the dot looked hollow.
                    Circle().strokeBorder(palette.step(3), lineWidth: 1.5)
                        .opacity(appeared && dot != .open ? 0 : 1)
                    Surface(shape: Circle(), color: dot == .attention ? design.action : palette.step(5))
                        .scaleEffect(appeared && dot != .open ? 1 : 0.2)
                        .opacity(appeared && dot != .open ? 1 : 0)
                }
                .frame(width: diameter, height: diameter)
                .animation(Theme.layout.delay(appeared ? 0 : 0.2 + Double(index) * 0.035), value: appeared)
                .animation(Theme.layout, value: dot)
            }
        }
        .fixedSize()
        .onAppear { appeared = true }
    }
}

// MARK: State

/// A feature that should stay off, as a switch: off and quiet, or on and glowing. Below it one line of detail and, when there is
/// something to remove, a meter.
struct StateView: View {
    /// What of it is drawn. On the dashboard the switch is drawn over the tile's button, apart from the rest (`TileSwitch`): inside the
    /// button, a click on it also opened the tile.
    enum Part {
        case all
        /// Everything but the switch, whose place is kept empty for the one drawn over it.
        case allButSwitch
        case switchOnly
    }

    let on: Bool
    let detail: String
    let meter: Double?
    let meterIsActionable: Bool
    let tint: TileTint
    var loading = false
    var part = Part.all
    /// Makes the change when the switch is flipped (true when it was made). nil only shows the state.
    var flip: (@MainActor (Bool) async -> Bool)?
    /// The module offers no change: the switch is dimmed, as a page's switch row that cannot be flipped.
    var disabled = false
    /// The detail has room in `detailLines` lines (`detailFits`); measured by the tile, which knows its width. On one line only, it
    /// folded away on a tile 230 points wide, where "367,3 MB de modelos mantidos pelo macOS" needs 220 and has 206 (2026-10-13).
    var showsDetail = true

    static var detailFont: NSFont { NSFont.systemFont(ofSize: TileType.current.smallTextSize) }
    static let detailLines = 2

    /// Whether `detail` fits in `width` at its size, in `detailLines` lines at most, its words unbroken.
    static func detailFits(_ detail: String, width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        let detailFont = detailFont
        let words = detail.split(separator: " ").map { ceil((String($0) as NSString).size(withAttributes: [.font: detailFont]).width) }
        guard words.allSatisfy({ $0 <= width }) else { return false }
        let bounds = (detail as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin], attributes: [.font: detailFont])
        // One line, measured the same way.
        let line = (detail as NSString).boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin], attributes: [.font: detailFont]).height
        return bounds.height <= line * CGFloat(detailLines) + 1
    }
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var fill: CGFloat = 0

    var body: some View {
        content { _ in 1 }
    }

    private func content(_ wave: (Int) -> Double) -> some View {
        let palette = design.palette(tint)
        return VStack(alignment: .leading, spacing: 10) {
            // The system's switch, as on the page; it moves at once and the module follows (`LiveSwitch`). The wave is read here:
            // the switch's closure outlives this call.
            let switchOpacity = part == .allButSwitch ? 0 : wave(0)
            LiveSwitch(isOn: on, apply: { value in await flip?(value) ?? false }) { isOn in
                HStack(spacing: 9) {
                    Toggle("", isOn: isOn)
                        .toggleStyle(.switch)
                        // The size a grouped form gives the page's switch rows.
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(disabled)
                        // The click is taken by the row below: the system switch does not claim it from SwiftUI's gestures, and
                        // it went through to the tile's button and opened the page.
                        .allowsHitTesting(false)
                }
                .opacity(switchOpacity)
                // No "on"/"off" beside it: the switch says so itself.
                .contentShape(Rectangle())
                .onTapGesture { if !disabled { isOn.wrappedValue.toggle() } }
                .allowsHitTesting(flip != nil && part != .allButSwitch)
            }
            if part != .switchOnly {
                // Never shrunk: on two lines where one is too short, and folded away only where two are too (`showsDetail`).
                if showsDetail {
                    Text(detail).font(TileType.current.smallText).foregroundStyle(palette.soft).lineLimit(Self.detailLines)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(wave(1))
                }
                if let meter {
                    // Read here: the geometry reader's closure outlives this call and cannot hold `wave`.
                    let strength = wave(2)
                    GeometryReader { proxy in
                        Surface(shape: Capsule(), color: palette.step(1), strength: strength)
                            .overlay(alignment: .leading) {
                                Surface(shape: Capsule(), color: meterIsActionable ? design.action : palette.step(4), strength: strength)
                                    .modifier(AnimatedLength(value: proxy.size.width * CGFloat(meter) * fill, kind: .width))
                            }
                    }
                    .frame(height: 6)
                    .frame(maxWidth: 200)
                    .onAppear { withAnimation(.smooth(duration: 1).delay(0.3)) { fill = 1 } }
                }
            }
        }
    }
}

/// The edge Apple Intelligence draws around what it touches, turning slowly. Only for a state that should not be.
struct GlowEdge: View {
    var radius: CGFloat = Theme.tileRadius
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        // It turns while MacSpace is in front, and rests in the background: shown for as long as Apple Intelligence is on, its two
        // blurred strokes were redrawn 30 times a second behind whatever app was in front.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !appearsActive)) { context in
            let angle = Angle.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * 40)
            let colors: [Color] = [Color(hex: 0x3A8BFF), Color(hex: 0xB04CFF), Color(hex: 0xFF5C9A), Color(hex: 0xFF9F2E), Color(hex: 0x3A8BFF)]
            let gradient = AngularGradient(colors: colors, center: .center, angle: angle)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                shape.strokeBorder(gradient, lineWidth: 8).blur(radius: 9).opacity(0.75)
                shape.strokeBorder(gradient, lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Gauge

/// The disk's gauge: a bar across the tile filled to the share. The share and the disk's size are left to the caption.
struct BarGaugeView: View {
    static let height: CGFloat = 10

    let value: Double
    let tint: TileTint
    var loading = false
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var drawn: Double = 0

    var body: some View {
        let palette = design.palette(tint)
        let used = min(max(value, 0), 1) * drawn
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Surface(shape: Capsule(), color: palette.step(1))
                Surface(shape: Capsule(), color: palette.step(5))
                    .modifier(AnimatedLength(value: proxy.size.width * used, kind: .width))
                // While loading, a light runs along the bar.
                if loading && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: !appearsActive)) { context in
                        let runner = 0.22
                        let from = LoadingWave.position(context.date) * (1 + runner) - runner
                        Surface(shape: Capsule(), color: palette.step(5))
                            .frame(width: proxy.size.width * (min(from + runner, 1) - max(from, 0)))
                            .offset(x: proxy.size.width * max(from, 0))
                    }
                    .transition(.opacity)
                }
            }
        }
        .frame(height: Self.height)
        .animation(.smooth(duration: 0.4), value: loading)
        .animation(Theme.value, value: value)
        .onAppear { withAnimation(.smooth(duration: 1.1).delay(0.2)) { drawn = 1 } }
    }
}

/// The amber "!" with a ring that keeps pulsing out of it.
struct AttentionMark: View {
    static let pulse = 1.8
    static let rest = 1.6
    static let diameter: CGFloat = 19
    static var inset: CGFloat { max(Theme.tileRadius, diameter) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.design) private var design

    var body: some View {
        // One pulse, then a rest, at 30 frames a second while the window is in front; still otherwise. A repeating animation was
        // worked out at every frame of the display, rests included, and went on in a closed window.
        Image(systemName: "exclamationmark")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(design.actionDeep)
            .frame(width: Self.diameter, height: Self.diameter)
            .background(Circle().fill(design.action))
            .background {
                TimelineView(PulseSchedule(pulse: Self.pulse, rest: Self.rest, paused: reduceMotion || !appearsActive)) { context in
                    let progress = Self.progress(at: context.date)
                    Circle().strokeBorder(design.action, lineWidth: 1.5)
                        .frame(width: Self.diameter, height: Self.diameter)
                        .scaleEffect(1 + (2 * (Self.inset - 1) / Self.diameter - 1) * progress)
                        .opacity(reduceMotion ? 0 : 1 - progress)
                }
            }
            .frame(width: 2 * Self.inset, height: 2 * Self.inset)
            .accessibilityLabel(String(localized: "Needs attention"))
    }

    /// How far the ring has gone out, 0...1, easing out; 0 during the rest.
    /// 30 frames a second through the pulse, and none through the rest, when nothing moves: the mark stays on a tile for as long as
    /// it needs the user, and was redrawn all that time.
    struct PulseSchedule: TimelineSchedule {
        let pulse: Double
        let rest: Double
        let paused: Bool

        func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
            var next: Date? = start
            return AnyIterator {
                guard let current = next else { return nil }
                if paused { next = nil; return current }
                let t = current.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: pulse + rest)
                next = current.addingTimeInterval(t < rest ? max(rest - t, 1.0 / 30) : 1.0 / 30)
                return current
            }
        }
    }

    static func progress(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: pulse + rest)
        guard t >= rest else { return 0 }
        let x = (t - rest) / pulse
        return 1 - (1 - x) * (1 - x)
    }
}

/// A width or a leading inset laid out again on every frame while it changes, not animated by SwiftUI from where it starts to where it
/// ends up.
struct AnimatedLength: ViewModifier, @preconcurrency Animatable {
    enum Kind {
        case width
        case leading
    }

    var value: CGFloat
    let kind: Kind

    var animatableData: CGFloat {
        get { value }
        set { value = newValue }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        switch kind {
        case .width: content.frame(width: max(value, 0))
        case .leading: content.padding(.leading, max(value, 0))
        }
    }
}
