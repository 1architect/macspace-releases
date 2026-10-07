import MacSpacePlatform
import MacSpaceSdk
import SwiftUI

/// A tile's ground: its color, lit faintly from the top left. With Liquid Glass on it is glass with that color inside it (`GlassPane`).
/// The glass is not interactive: the system's pointer response lags behind the pointer and ignores the tile's tilt and lift, and the
/// tile answers hover and press itself.
struct TileBackdrop: View {
    let tint: TileTint
    /// Under the pointer: a shade inside the glass, over its color, so the shade is part of the glass and moves exactly with it.
    var darkened = false
    /// The corners: a tile's, growing to the window's as the tile becomes a page.
    var cornerRadius: CGFloat = Theme.tileRadius
    @Environment(\.design) private var design

    var body: some View {
        let palette = design.palette(tint)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if design.glass {
            // The color is drawn inside the glass, so it shows whatever the glass picks up behind it. A tile that has become a page
            // keeps its glass: swapping it for a flat color at the end of the zoom flickered however it was cross-faded, glass and a
            // flat color never looking alike. The window's own glass gives way under it instead (`MainView`), so a page is still
            // one layer of glass.
            let cover = design.isLight ? 0.5 : 0.62
            let shading = design.lab.shading(.tile(tint))
            if design.fill(.tile(tint)).map({ $0.kind != .solid }) ?? false || shading != nil {
                // The Color Lab's gradient or the studio's shading, under clear glass: AppKit's glass takes one color, so they lie
                // behind it.
                ZStack {
                    ShadedFill(shape: shape, color: palette.base, accent: palette.step(3), fill: design.fill(.tile(tint)), shading: shading,
                               light: design.isLight)
                        .opacity(cover)
                    GlassPane(corners: .radius(cornerRadius), style: design.clearTileGlass ? .clear : .regular,
                              color: .clear, opacity: 0, shade: darkened ? Theme.tileHoverShade * 2 * cover : 0)
                }
            } else {
                GlassPane(corners: .radius(cornerRadius), style: design.clearTileGlass ? .clear : .regular,
                          color: design.fill(.tile(tint))?.average(palette.base) ?? palette.base, opacity: cover,
                          shade: darkened ? Theme.tileHoverShade * 2 * cover : 0)
            }
        } else {
            // Rounded itself: the tiles are no longer clipped to their shape. Lit by the studio's shading, by default the faint light
            // from the top left.
            ShadedFill(shape: shape, color: palette.base, accent: palette.step(3), fill: design.fill(.tile(tint)),
                       shading: design.shading(.tile(tint)), light: design.isLight)
        }
    }
}

/// The darkening of glass under the pointer. It lies on top of the glass, in the glass's shape: glass adapts slowly to what it sees
/// behind it, so anything that changes behind or inside it on hover lingers after the pointer has left.
struct HoverShade<S: Shape>: View {
    let shape: S
    let on: Bool
    var amount = Theme.highlightDarkening

    var body: some View {
        shape.fill(.black.opacity(on ? amount : 0))
            .animation(Theme.highlight, value: on)
            .allowsHitTesting(false)
    }
}

/// A chart element's surface: flat color, or Liquid Glass with that color inside it when glass chart elements are on, whether the
/// tiles are glass or not. Highlighted, flat color lightens
/// and glass is shaded.
struct Surface<S: Shape>: View, @preconcurrency Animatable {
    let shape: S
    let color: Color
    var highlighted = false
    /// How much of the color shows, 0...1: the loading pulse, and a block coming in. It thins the color inside the glass. Animated
    /// frame by frame, so the glass's color follows it.
    var strength: Double = 1
    /// False for an element too small for glass: AppKit's glass keeps a size of its own below about ten points, and a sliver of a
    /// block drawn as glass spread over its neighbours and past the chart. It gets the color the glass would show, without the glass.
    var glass = true
    @Environment(\.design) private var design

    var animatableData: Double {
        get { strength }
        set { strength = newValue }
    }

    var body: some View {
        if design.glassElements {
            // On glass tiles, darkened inside the glass, so the shade is the glass's own shape. On flat tiles nothing changes under
            // the pointer.
            let dark = highlighted && design.hoverShade && design.glass
            let base = color
            let shown = dark ? base.mix(with: .black, by: Theme.highlightDarkening) : base
            let tinted = ShadedFill(shape: shape, color: shown, accent: shown.mix(with: .white, by: 0.4), fill: design.fill(.chartElements),
                                    shading: design.shading(.chartElements), light: design.isLight)
                .opacity(0.7 * strength)
                .animation(Theme.highlight, value: highlighted)
            if !glass {
                tinted
            } else if let corners = Self.corners(of: shape),
                      design.fill(.chartElements).map({ $0.kind != .solid }) ?? false || design.shading(.chartElements) != nil {
                // The Color Lab's gradient, under clear glass: AppKit's glass takes one color, so the gradient lies behind it.
                ZStack {
                    tinted
                    GlassPane(corners: corners, color: .clear, opacity: 0, shade: dark ? Theme.highlightDarkening * 0.7 : 0)
                }
            } else if let corners = Self.corners(of: shape) {
                GlassPane(corners: corners, color: design.fill(.chartElements)?.average(base) ?? base, opacity: 0.7 * strength,
                          shade: dark ? Theme.highlightDarkening * 0.7 : 0)
            } else {
                // A shape AppKit's glass cannot take stays SwiftUI's glass.
                tinted.glassEffect(.regular, in: shape)
            }
        } else {
            // A light laid over the color, not a brightness filter, which stays on even at 0 and costs an extra pass every frame.
            ShadedFill(shape: shape, color: color, accent: color.mix(with: .white, by: 0.4), fill: design.fill(.chartElements),
                       shading: design.shading(.chartElements), light: design.isLight)
                .overlay { shape.fill(.white.opacity(highlighted ? Self.flatHighlight : 0)) }
                .animation(Theme.highlight, value: highlighted)
                .opacity(strength)
        }
    }

    /// How much a flat element lightens under the pointer.
    static var flatHighlight: Double { 0.1 }

    /// The corners AppKit's glass gives a shape, or nil for a shape it cannot take.
    private static func corners(of shape: S) -> GlassPane.Corners? {
        if let rectangle = shape as? RoundedRectangle { return .radius(rectangle.cornerSize.width) }
        if shape is Circle || shape is Capsule { return .round }
        return nil
    }
}

extension View {
    /// The pointer tilt of a flat tile. Glass tiles get none at all, not a turn of 0°: a 3D effect puts the tile in a projection layer
    /// even when it does not turn, and glass under it is drawn the expensive way.
    @ViewBuilder
    func tilted(_ tilt: UnitPoint, active: Bool) -> some View {
        if active {
            rotation3DEffect(.degrees((tilt.x - 0.5) * 5), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees((0.5 - tilt.y) * 5), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        } else {
            self
        }
    }
}

// MARK: Loading

/// While a tile's figures load, its chart's own elements breathe one after another, a wave running through them, instead of a band of
/// light sweeping over the tile. With Reduce Motion they stay dimmed instead.
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
}

// MARK: Blocks

/// Squarified treemap: rectangles with areas proportional to the values, kept as close to square as the space allows. Values are laid
/// out in the order given (largest first reads best).
enum Treemap {
    /// The squarified layout whose thinnest block is widest, over the orders of the blocks after the largest: laid out largest first,
    /// the last block took whatever strip was left (25 points wide and full height on a page, too narrow for its size). Returns where
    /// each value goes, in the order given. Up to seven values every order is tried; past that, the given one.
    static func arranged(_ values: [Double], in rect: CGRect) -> [CGRect] {
        guard values.count > 2, values.count <= 7 else { return layout(values, in: rect) }
        func thinnest(_ rects: [CGRect]) -> CGFloat {
            rects.filter { $0.width > 0.5 && $0.height > 0.5 }.map { min($0.width, $0.height) }.min() ?? 0
        }
        var best: (order: [Int], rects: [CGRect], score: CGFloat)?
        func visit(_ order: [Int], _ rest: [Int]) {
            guard !rest.isEmpty else {
                let rects = layout(order.map { values[$0] }, in: rect)
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
        guard let best else { return layout(values, in: rect) }
        var result = [CGRect](repeating: .zero, count: values.count)
        for (position, index) in best.order.enumerated() { result[index] = best.rects[position] }
        return result
    }

    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = Array(areas.indices)
        var space = rect

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
            let side = Double(min(space.width, space.height))
            var row = [remaining.removeFirst()]
            while let next = remaining.first, worst(row + [next], side) <= worst(row, side) {
                row.append(remaining.removeFirst())
            }
            let sum = row.reduce(0) { $0 + areas[$1] }
            if space.width >= space.height {
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
}

/// What the blocks draw, so that every part can be seen and pointed at. Parts under 2% of the total are drawn as one block ("3
/// smaller"), and every block takes at least a share of the area, more for what can be freed (the page's main action). The sizes
/// shown stay the real ones; the legend still lists every part. Drawn to scale, a part was a sliver a pixel or two wide, or nothing
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
    static func blocks(_ segments: [UsageSegment]) -> [(segment: UsageSegment, weight: Double)] {
        let total = Double(segments.map(\.bytes).reduce(0, +))
        guard total > 0 else { return segments.map { ($0, Double($0.bytes)) } }
        var shown = segments
        let small = segments.filter { $0.tone != .caution && Double($0.bytes) < total * mergeBelow }
        if small.count >= 2 {
            let ids = Set(small.map(\.id))
            shown = segments.filter { !ids.contains($0.id) }
            shown.append(UsageSegment(id: smallerID, label: String(localized: "\(small.count) smaller"), bytes: small.map(\.bytes).reduce(0, +), tone: .series(segments.count)))
        } else if let only = small.first, Double(only.bytes) < total * dropBelow {
            shown = segments.filter { $0.id != only.id }
        }
        return shown.map { segment in
            (segment, max(Double(segment.bytes), total * (segment.tone == .caution ? actionShare : minimumShare)))
        }.sorted { $0.weight > $1.weight }
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
/// when they appear and glide to new sizes.
struct BlocksView: View {
    let segments: [UsageSegment]
    let tint: TileTint
    var labels = true
    var hovered: String?
    var gap: CGFloat = 3
    var loading = false
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// The narrowest block drawn as glass (`Surface.glass`).
    static let smallestGlass: CGFloat = 12

    /// A size split into its number and unit ("201,7 MB" -> ["201,7", "MB"]), for a narrow block.
    static func sizeParts(_ bytes: UInt64) -> [String] {
        let text = ByteFormat.string(bytes)
        guard let space = text.lastIndex(of: " ") else { return [text] }
        return [String(text[..<space]), String(text[text.index(after: space)...])]
    }

    /// A block's corner radius: 6 points on a page's large blocks, less on a tile's small ones, where 6 made them pills.
    static func radius(_ rect: CGRect) -> CGFloat { min(6, max(2, min(rect.width, rect.height) * 0.16)) }

    var body: some View {
        GeometryReader { proxy in
            let blocks = BlockLayout.blocks(segments)
            let shown = blocks.map(\.segment)
            let shades = shown.indices.map { BlockLayout.shade(at: $0, in: blocks) }
            let rects = Treemap.arranged(blocks.map(\.weight), in: CGRect(origin: .zero, size: proxy.size))
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !loading || reduceMotion)) { context in
                // Two layers moved alike: the blocks, then their names over them.
                ZStack(alignment: .topLeading) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, segment in
                        let rect = inset(rects[index])
                        let fill = BlockColor.fill(segment, shade: shades[index], tint: tint, design: design)
                        placed(Surface(shape: RoundedRectangle(cornerRadius: Self.radius(rect), style: .continuous), color: fill, highlighted: hovered == segment.id,
                                       strength: appeared ? wave(context.date, index) : 0,
                                       glass: min(rect.width, rect.height) >= Self.smallestGlass),
                               index: index, rect: rect)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, segment in
                        let rect = inset(rects[index])
                        placed(overlay(segment, shade: shades[index], rect: rect).opacity(appeared ? wave(context.date, index) : 0), index: index, rect: rect)
                    }
                }
            }
            .animation(Theme.layout, value: shown)
            .animation(.smooth(duration: 0.4), value: loading)
        }
        .onAppear { appeared = true }
    }

    /// A block's rectangle less its share of the gap. A block thinner than the gap keeps its place at no width; inset as usual, it
    /// became a null rectangle, at infinity, and its glass stayed wherever it had last been drawn.
    private func inset(_ rect: CGRect) -> CGRect {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { return .zero }
        return rect.insetBy(dx: min(gap / 2, rect.width / 2), dy: min(gap / 2, rect.height / 2))
    }

    /// A block's place and its coming in (growing from its middle); the same for the block and for its name. The color comes in with
    /// it (`appeared` in the surface's strength).
    private func placed(_ view: some View, index: Int, rect: CGRect) -> some View {
        view
            .modifier(BlockFrame(rect: rect, grown: appeared ? 1 : 0.6))
            .animation(Theme.layout.delay(Double(index) * 0.05), value: appeared)
    }

    /// Block `index`'s loading pulse: given to the block's surface (glass ignores an opacity) and laid on its name.
    private func wave(_ date: Date, _ index: Int) -> Double {
        LoadingWave.opacity(date, index: index, count: segments.count, loading: loading, reduceMotion: reduceMotion)
    }

    /// What is drawn over a block: its name and size when it is large enough, and on flat blocks an outline when hovered (glass has its
    /// own edge; an outline would sit inside it).
    private func overlay(_ segment: UsageSegment, shade: Double, rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            if !design.glassElements {
                RoundedRectangle(cornerRadius: Self.radius(rect), style: .continuous)
                    .strokeBorder(.white.opacity(hovered == segment.id ? 0.5 : 0), lineWidth: 1)
                    .animation(Theme.highlight, value: hovered)
            }
            // A name comes and goes as resizing the window gives its block room or takes it: the name and size where they fit (the
            // name on two lines in a tall block rather than cut short), the size alone in a narrow one.
            if labels, rect.width > 46, rect.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    // As many lines as the block has room for under the size, up to three, rather than a name cut short.
                    Text(segment.label).font(.system(size: 11, weight: .medium)).lineLimit(max(1, min(3, Int((rect.height - 26) / 14))))
                        .minimumScaleFactor(0.8)
                    Text(ByteFormat.string(segment.bytes)).font(.system(size: 11)).opacity(0.8).lineLimit(1).minimumScaleFactor(0.75)
                        .contentTransition(.numericText())
                }
                .foregroundStyle(BlockColor.label(segment, shade: shade, tint: tint, design: design))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .transition(.opacity.combined(with: .scale(scale: 0.86, anchor: .topLeading)).animation(Theme.layout))
            } else if labels, rect.width > 34, rect.height > 20 {
                // The size alone: on one line, or the number over its unit in a narrow block; never cut.
                ViewThatFits(in: .horizontal) {
                    Text(ByteFormat.string(segment.bytes)).font(.system(size: 10)).lineLimit(1).fixedSize()
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Self.sizeParts(segment.bytes), id: \.self) { Text($0).font(.system(size: 10)).lineLimit(1).fixedSize() }
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
    static func segment(at point: CGPoint, in size: CGSize, segments: [UsageSegment]) -> UsageSegment? {
        let blocks = BlockLayout.blocks(segments)
        let rects = Treemap.arranged(blocks.map(\.weight), in: CGRect(origin: .zero, size: size))
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
    @State private var appeared = false

    var body: some View {
        let palette = design.palette(tint)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !loading || reduceMotion)) { context in
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(diameter), spacing: spacing), count: columns), alignment: .leading, spacing: spacing) {
                ForEach(Array(dots.enumerated()), id: \.offset) { index, dot in
                    let wave = LoadingWave.opacity(context.date, index: index, count: dots.count, loading: loading, reduceMotion: reduceMotion)
                    ZStack {
                        Circle().strokeBorder(palette.step(3), lineWidth: 1.5)
                            .opacity(wave)
                        Surface(shape: Circle(), color: dot == .attention ? design.action : palette.step(5), strength: wave)
                            .scaleEffect(appeared && dot != .open ? 1 : 0.2)
                            .opacity(appeared && dot != .open ? 1 : 0)
                    }
                    .frame(width: diameter, height: diameter)
                    .animation(Theme.layout.delay(appeared ? 0 : 0.2 + Double(index) * 0.035), value: appeared)
                    .animation(Theme.layout, value: dot)
                }
            }
        }
        .animation(.smooth(duration: 0.4), value: loading)
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
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fill: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !loading || reduceMotion)) { context in
            content { index in LoadingWave.opacity(context.date, index: index, count: 3, loading: loading, reduceMotion: reduceMotion) }
        }
        .animation(.smooth(duration: 0.4), value: loading)
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
                Text(detail).font(.system(size: 11)).foregroundStyle(palette.soft).lineLimit(2)
                    .opacity(wave(1))
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
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
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.design) private var design
    @State private var pulsing = false

    var body: some View {
        // One pulse, then a rest, repeated by the animation itself: the view is not redrawn every frame by a timeline, and the window
        // (all glass) is not recomposited between pulses.
        Image(systemName: "exclamationmark")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(design.actionDeep)
            .frame(width: 19, height: 19)
            .background(Circle().fill(design.action))
            .background(Circle().stroke(design.action, lineWidth: 1.5).scaleEffect(pulsing ? 1.9 : 1).opacity(pulsing ? 0 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.8).delay(1.6).repeatForever(autoreverses: false)) { pulsing = true }
            }
            .accessibilityLabel(String(localized: "Needs attention"))
    }
}
