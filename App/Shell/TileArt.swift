import MacSpacePlatform
import MacSpaceSdk
import SwiftUI

/// A tile's ground: its color, lit faintly from the top left. With Liquid Glass on it is glass tinted with that color. The glass is not
/// interactive: the system's pointer response lags behind the pointer and ignores the tile's tilt and lift, and the tile answers hover
/// and press itself.
struct TileBackdrop: View {
    let tint: TileTint
    /// Under the pointer: the tint inside the glass darkens, so the shade is part of the glass and moves exactly with it.
    var darkened = false
    @Environment(\.design) private var design

    var body: some View {
        let palette = design.palette(tint)
        let shape = RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
        let color = darkened ? palette.base.mix(with: .black, by: Theme.tileHoverShade * 2) : palette.base
        if design.glass {
            // The color is drawn inside the glass, so it shows whatever the glass picks up behind it. A tile that has become a page
            // keeps its glass: swapping it for a flat color at the end of the zoom flickered however it was cross-faded, glass and a
            // flat color never looking alike. The window's own glass gives way under it instead (`MainView`), so a page is still
            // one layer of glass.
            shape.fill(color.opacity(design.isLight ? 0.5 : 0.62))
                .animation(Theme.highlight, value: darkened)
                .glassEffect(design.clearTileGlass ? .clear : .regular, in: shape)
        } else {
            // Rounded itself: the tiles are no longer clipped to their shape.
            shape.fill(palette.base)
                .overlay {
                    shape.fill(RadialGradient(colors: [.white.opacity(design.isLight ? 0.5 : 0.07), .clear], center: .topLeading, startRadius: 0, endRadius: 420))
                }
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

/// A chart element's surface: flat color, or Liquid Glass tinted with that color when glass is on. Highlighted, flat color lightens
/// and glass is shaded.
struct Surface<S: Shape>: View {
    let shape: S
    let color: Color
    var highlighted = false
    /// How much of the color shows, 0...1: the loading pulse. On glass it thins the color inside the glass, since the glass itself
    /// ignores an opacity laid on it, so a pulse laid over the chart only reached its text.
    var strength: Double = 1
    @Environment(\.design) private var design

    var body: some View {
        if design.glass && design.glassElements {
            // Darkened inside the glass. A shade laid over it was lost once the chart's glass was drawn in a glass container.
            let dark = highlighted && design.hoverShade
            shape.fill((dark ? color.mix(with: .black, by: Theme.highlightDarkening) : color).opacity(0.7 * strength))
                .animation(Theme.highlight, value: dark)
                .glassEffect(.regular, in: shape)
        } else {
            // A light laid over the color, not a brightness filter, which stays on even at 0 and costs an extra pass every frame.
            shape.fill(color)
                .overlay { shape.fill(.white.opacity(highlighted ? 0.1 : 0)) }
                .animation(Theme.highlight, value: highlighted)
                .opacity(strength)
        }
    }
}

/// Draws the glass elements inside it together, in one pass, as Apple recommends for groups of glass; drawn one by one, each element
/// sampled and blurred what is behind it separately. Spacing 0: elements a few points apart (the blocks) must not melt into each other.
struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GlassEffectContainer(spacing: 0) { content }
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

/// The color of a block: what can be freed is the action color; the rest step from close to the ground (the largest) to strong
/// (the smallest).
enum BlockColor {
    static func fill(_ segment: UsageSegment, rank: Int, tint: TileTint, design: Design) -> Color {
        if segment.tone == .caution { return design.action }
        let steps = [1, 2, 2, 3, 3, 4]
        return design.palette(tint).step(steps[min(rank, steps.count - 1)])
    }

    static func label(_ segment: UsageSegment, rank: Int, tint: TileTint, design: Design) -> Color {
        if segment.tone == .caution { return design.actionDeep }
        let palette = design.palette(tint)
        return rank >= 5 ? palette.base : palette.text
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

    var body: some View {
        GeometryReader { proxy in
            let rects = Treemap.layout(segments.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: proxy.size))
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !loading || reduceMotion)) { context in
                // Two layers moved alike: the blocks, whose glass is drawn together in a glass container, and their names over them. The
                // container draws only glass, so names inside it were lost.
                ZStack(alignment: .topLeading) {
                    GlassGroup {
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                                let rect = rects[index].insetBy(dx: gap / 2, dy: gap / 2)
                                let fill = BlockColor.fill(segment, rank: index, tint: tint, design: design)
                                placed(Surface(shape: RoundedRectangle(cornerRadius: 6, style: .continuous), color: fill, highlighted: hovered == segment.id,
                                               strength: appeared ? wave(context.date, index) : 0),
                                       index: index, rect: rect)
                            }
                        }
                    }
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        let rect = rects[index].insetBy(dx: gap / 2, dy: gap / 2)
                        placed(overlay(segment, index: index, rect: rect).opacity(appeared ? wave(context.date, index) : 0), index: index, rect: rect)
                    }
                }
            }
            .animation(Theme.layout, value: segments)
            .animation(.smooth(duration: 0.4), value: loading)
        }
        .onAppear { appeared = true }
    }

    /// A block's place and its coming in (growing from its middle); the same for the block and for its name. The color comes in with
    /// it (`appeared` in the surface's strength): glass ignores an opacity.
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
    private func overlay(_ segment: UsageSegment, index: Int, rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            if !design.glass {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(hovered == segment.id ? 0.5 : 0), lineWidth: 1)
                    .animation(Theme.highlight, value: hovered)
            }
            // A name comes and goes as resizing the window gives its block room or takes it.
            if labels, rect.width > 74, rect.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(segment.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(ByteFormat.string(segment.bytes)).font(.system(size: 11)).opacity(0.8).contentTransition(.numericText())
                }
                .foregroundStyle(BlockColor.label(segment, rank: index, tint: tint, design: design))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .transition(.opacity.combined(with: .scale(scale: 0.86, anchor: .topLeading)).animation(Theme.layout))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    /// The block under a point, for hover.
    static func segment(at point: CGPoint, in size: CGSize, segments: [UsageSegment]) -> UsageSegment? {
        let rects = Treemap.layout(segments.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: size))
        return zip(segments, rects).first { $0.1.contains(point) }?.0
    }
}

/// Sizes and places a block by layout, worked out again on every frame of a movement. Moved and scaled by render effects
/// (offset, scale), the blocks' glass, which the glass container draws from the layout, stayed at the final size and place while
/// the colors moved: large dark shapes showed behind smaller blocks.
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
    let on: Bool
    let detail: String
    let meter: Double?
    let meterIsActionable: Bool
    let tint: TileTint
    var loading = false
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
            HStack(spacing: 9) {
                GlassGroup {
                    ZStack(alignment: on ? .trailing : .leading) {
                        Surface(shape: Capsule(), color: on ? design.action.opacity(0.35) : palette.step(1), strength: wave(0))
                        Surface(shape: Circle(), color: on ? design.action : palette.step(4), strength: wave(0)).padding(3)
                    }
                }
                .frame(width: 44, height: 24)
                Text(on ? "on" : "off").font(.system(size: 12, weight: .medium)).foregroundStyle(on ? design.actionLight : palette.soft)
                    .opacity(wave(0))
            }
            .animation(Theme.hover, value: on)
            Text(detail).font(.system(size: 11)).foregroundStyle(palette.soft).lineLimit(2)
                .opacity(wave(1))
            if let meter {
                // Read here: the geometry reader's closure outlives this call and cannot hold `wave`.
                let strength = wave(2)
                GeometryReader { proxy in
                    Surface(shape: Capsule(), color: palette.step(1), strength: strength)
                        .overlay(alignment: .leading) {
                            Surface(shape: Capsule(), color: meterIsActionable ? design.action : palette.step(4), strength: strength)
                                .frame(width: proxy.size.width * CGFloat(meter) * fill)
                        }
                }
                .frame(height: 6)
                .onAppear { withAnimation(.smooth(duration: 1).delay(0.3)) { fill = 1 } }
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

/// An arc filled to a share, and the share written in the middle. It draws in when it appears.
struct GaugeView: View {
    let value: Double
    let label: String
    let sublabel: String
    let tint: TileTint
    var loading = false
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: Double = 0

    private static let sweep = 0.75
    /// The length of the light that runs along the track while loading, as a share of the track.
    private static let runner = 0.16

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let band = min(9, max(4, side * 0.07))
            gauge(side: side)
                .overlay {
                    if loading && !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                            let from = LoadingWave.position(context.date) * (1 + Self.runner) - Self.runner
                            Surface(shape: ArcBand(from: max(from, 0) * Self.sweep, to: min(from + Self.runner, 1) * Self.sweep, width: band, round: true),
                                    color: design.palette(tint).step(5))
                        }
                        .transition(.opacity)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.smooth(duration: 0.4), value: loading)
        .animation(Theme.value, value: value)
        .onAppear { withAnimation(.smooth(duration: 1.1).delay(0.2)) { drawn = 1 } }
    }

    /// The ring and the text scale with the gauge, so a short tile gets a small gauge rather than text spilling out of it; the
    /// sublabel goes when there is no room for it.
    private func gauge(side: CGFloat) -> some View {
        let palette = design.palette(tint)
        let used = min(max(value, 0), 1) * Self.sweep * drawn
        let band = min(9, max(4, side * 0.07))
        return ZStack {
            // Only the arcs in the glass container: it draws only glass, and the share written inside it was lost.
            GlassGroup {
                ZStack {
                    Surface(shape: ArcBand(from: 0, to: Self.sweep, width: band, round: true), color: palette.step(1))
                    Surface(shape: ArcBand(from: 0, to: used, width: band, round: true), color: palette.step(5))
                }
            }
            // Glass is not drawn inside a rotated view, so the arc is placed by its angles instead of rotating the gauge.
            VStack(spacing: 1) {
                Text(label).font(.system(size: min(24, side * 0.2), weight: .semibold)).foregroundStyle(palette.text).contentTransition(.numericText())
                if side >= 90 {
                    Text(sublabel).font(.system(size: 11)).foregroundStyle(palette.soft)
                        .transition(.opacity.combined(with: .scale(scale: 0.86)).animation(Theme.layout))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: side - 2 * band - 8)
        }
    }
}

/// The gauge for a short tile: a bar across the tile filled to the share. The share and the disk's size are left to the caption.
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
                GlassGroup {
                    ZStack(alignment: .leading) {
                        Surface(shape: Capsule(), color: palette.step(1))
                        Surface(shape: Capsule(), color: palette.step(5)).frame(width: proxy.size.width * used)
                    }
                }
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

/// A band along a circle, from `from` to `to` (fractions of a turn, clockwise from `start`), as a filled shape so it can be glass.
/// The default start, 135°, is the lower left: a gauge opening at the bottom.
struct ArcBand: Shape {
    var from: Double
    var to: Double
    let width: CGFloat
    let round: Bool
    var start: Double = 135

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(from, to) }
        set { from = newValue.first; to = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        guard to > from else { return Path() }
        let radius = min(rect.width, rect.height) / 2 - width / 2
        var arc = Path()
        arc.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: max(radius, 0), startAngle: .degrees(start + from * 360), endAngle: .degrees(start + to * 360), clockwise: false)
        return arc.strokedPath(StrokeStyle(lineWidth: width, lineCap: round ? .round : .butt))
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
            .accessibilityLabel("Needs attention")
    }
}
