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
            GlassPane(corners: .radius(cornerRadius), style: design.clearTileGlass ? .clear : .regular,
                      color: palette.base, opacity: cover, shade: darkened ? Theme.tileHoverShade * 2 * cover : 0)
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
            // Darkened inside the glass, so the shade is the glass's own shape.
            let dark = highlighted && design.hoverShade
            let tinted = shape.fill((dark ? color.mix(with: .black, by: Theme.highlightDarkening) : color).opacity(0.7 * strength))
                .animation(Theme.highlight, value: dark)
            if !glass {
                tinted
            } else if let corners = Self.corners(of: shape) {
                GlassPane(corners: corners, color: color, opacity: 0.7 * strength, shade: dark ? Theme.highlightDarkening * 0.7 : 0)
            } else {
                // A shape AppKit's glass cannot take stays SwiftUI's glass.
                tinted.glassEffect(.regular, in: shape)
            }
        } else {
            // A light laid over the color, not a brightness filter, which stays on even at 0 and costs an extra pass every frame.
            shape.fill(color)
                .overlay { shape.fill(.white.opacity(highlighted ? 0.1 : 0)) }
                .animation(Theme.highlight, value: highlighted)
                .opacity(strength)
        }
    }

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

    /// The narrowest block drawn as glass (`Surface.glass`).
    static let smallestGlass: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let rects = Treemap.layout(segments.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: proxy.size))
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !loading || reduceMotion)) { context in
                // Two layers moved alike: the blocks, then their names over them.
                ZStack(alignment: .topLeading) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        let rect = inset(rects[index])
                        let fill = BlockColor.fill(segment, rank: index, tint: tint, design: design)
                        placed(Surface(shape: RoundedRectangle(cornerRadius: 6, style: .continuous), color: fill, highlighted: hovered == segment.id,
                                       strength: appeared ? wave(context.date, index) : 0,
                                       glass: min(rect.width, rect.height) >= Self.smallestGlass),
                               index: index, rect: rect)
                    }
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        let rect = inset(rects[index])
                        placed(overlay(segment, index: index, rect: rect).opacity(appeared ? wave(context.date, index) : 0), index: index, rect: rect)
                    }
                }
            }
            .animation(Theme.layout, value: segments)
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
    private func overlay(_ segment: UsageSegment, index: Int, rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            if !design.glassElements {
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

/// A switch drawn as macOS draws one: a capsule track, grey when off and colored when on, and a white knob with a soft shadow that
/// slides across. It only shows a state (the tile opens on a click), so it is drawn rather than a real `Toggle`, which would also
/// grey out with the window inactive. On is the action color, as everywhere that something can be acted on.
struct SwitchMark: View {
    let on: Bool
    static let size = CGSize(width: 40, height: 24)
    private static let inset: CGFloat = 2
    @Environment(\.design) private var design

    var body: some View {
        let knob = Self.size.height - 2 * Self.inset
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? design.action : (design.isLight ? Color.black.opacity(0.1) : Color.white.opacity(0.18)))
            // The knob's shadow is a darker disc just under it, not a blurred shadow, which is redrawn on every frame the tile moves.
            Circle()
                .fill(.white)
                .background { Circle().fill(.black.opacity(0.2)).padding(-0.5).offset(y: 0.75) }
                .frame(width: knob, height: knob)
                .padding(Self.inset)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: on)
    }
}

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
                SwitchMark(on: on)
                    .opacity(wave(0))
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
                                .modifier(AnimatedLength(value: proxy.size.width * CGFloat(meter) * fill, kind: .width))
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
            .accessibilityLabel("Needs attention")
    }
}
