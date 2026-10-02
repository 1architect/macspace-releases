import MacSpacePlatform
import MacSpaceSdk
import SwiftUI

/// A tile's ground: its color, lit faintly from the top left. With Liquid Glass on it is glass tinted with that color. The glass is not
/// interactive: the system's pointer response lags behind the pointer and ignores the tile's tilt and lift, and the tile answers hover
/// and press itself.
struct TileBackdrop: View {
    let tint: TileTint
    @Environment(\.design) private var design

    var body: some View {
        let palette = design.palette(tint)
        if design.glass {
            // The color is drawn inside the glass, so it shows whatever the glass picks up behind it.
            let shape = RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
            shape.fill(palette.base.opacity(design.isLight ? 0.5 : 0.62))
                .glassEffect(.regular, in: shape)
        } else {
            palette.base
                .overlay {
                    RadialGradient(colors: [.white.opacity(design.isLight ? 0.5 : 0.07), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
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
    @Environment(\.design) private var design

    var body: some View {
        if design.glass {
            shape.fill(color.opacity(0.7))
                .glassEffect(.regular, in: shape)
                .overlay { HoverShade(shape: shape, on: highlighted && design.hoverShade) }
        } else {
            shape.fill(color)
                .brightness(highlighted ? 0.08 : 0)
                .animation(Theme.highlight, value: highlighted)
        }
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
    @Environment(\.design) private var design
    @State private var appeared = false

    var body: some View {
        GeometryReader { proxy in
            let rects = Treemap.layout(segments.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    let rect = rects[index].insetBy(dx: gap / 2, dy: gap / 2)
                    let fill = BlockColor.fill(segment, rank: index, tint: tint, design: design)
                    Surface(shape: RoundedRectangle(cornerRadius: 6, style: .continuous), color: fill, highlighted: hovered == segment.id)
                        .overlay {
                            // Glass has its own edge; an outline would sit inside it.
                            if !design.glass {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.white.opacity(hovered == segment.id ? 0.5 : 0), lineWidth: 1)
                                    .animation(Theme.highlight, value: hovered)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if labels, rect.width > 74, rect.height > 34 {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(segment.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Text(ByteFormat.string(segment.bytes)).font(.system(size: 11)).opacity(0.8).contentTransition(.numericText())
                                }
                                .foregroundStyle(BlockColor.label(segment, rank: index, tint: tint, design: design))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                            }
                        }
                        .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                        .offset(x: rect.minX, y: rect.minY)
                        .scaleEffect(appeared ? 1 : 0.85, anchor: .topLeading)
                        .opacity(appeared ? 1 : 0)
                        .animation(Theme.layout.delay(Double(index) * 0.05), value: appeared)
                }
            }
            .animation(Theme.layout, value: segments)
        }
        .onAppear { appeared = true }
    }

    /// The block under a point, for hover.
    static func segment(at point: CGPoint, in size: CGSize, segments: [UsageSegment]) -> UsageSegment? {
        let rects = Treemap.layout(segments.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: size))
        return zip(segments, rects).first { $0.1.contains(point) }?.0
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
    @Environment(\.design) private var design
    @State private var appeared = false

    var body: some View {
        let palette = design.palette(tint)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(diameter), spacing: spacing), count: columns), alignment: .leading, spacing: spacing) {
            ForEach(Array(dots.enumerated()), id: \.offset) { index, dot in
                ZStack {
                    Circle().strokeBorder(palette.step(3), lineWidth: 1.5)
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
    let on: Bool
    let detail: String
    let meter: Double?
    let meterIsActionable: Bool
    let tint: TileTint
    @Environment(\.design) private var design
    @State private var fill: CGFloat = 0

    var body: some View {
        let palette = design.palette(tint)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                ZStack(alignment: on ? .trailing : .leading) {
                    Surface(shape: Capsule(), color: on ? design.action.opacity(0.35) : palette.step(1))
                    Surface(shape: Circle(), color: on ? design.action : palette.step(4)).padding(3)
                }
                .frame(width: 44, height: 24)
                Text(on ? "on" : "off").font(.system(size: 12, weight: .medium)).foregroundStyle(on ? design.actionLight : palette.soft)
            }
            .animation(Theme.hover, value: on)
            Text(detail).font(.system(size: 11)).foregroundStyle(palette.soft).lineLimit(2)
            if let meter {
                GeometryReader { proxy in
                    Surface(shape: Capsule(), color: palette.step(1))
                        .overlay(alignment: .leading) {
                            Surface(shape: Capsule(), color: meterIsActionable ? design.action : palette.step(4))
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

/// An arc filled to a share, a lighter part right after it, and the share written in the middle. It draws in when it appears.
struct GaugeView: View {
    let value: Double
    let extra: Double
    let label: String
    let sublabel: String
    let tint: TileTint
    @Environment(\.design) private var design
    @State private var drawn: Double = 0

    private static let sweep = 0.75

    var body: some View {
        GeometryReader { proxy in
            gauge(side: min(proxy.size.width, proxy.size.height))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(Theme.value, value: value)
        .onAppear { withAnimation(.smooth(duration: 1.1).delay(0.2)) { drawn = 1 } }
    }

    /// The ring and the text scale with the gauge, so a short tile gets a small gauge rather than text spilling out of it; the
    /// sublabel goes when there is no room for it.
    private func gauge(side: CGFloat) -> some View {
        let palette = design.palette(tint)
        let used = min(max(value, 0), 1) * Self.sweep * drawn
        let more = min(max(extra, 0), 1 - min(value, 1)) * Self.sweep * drawn
        let band = min(9, max(4, side * 0.07))
        return ZStack {
            Surface(shape: ArcBand(from: 0, to: Self.sweep, width: band, round: true), color: palette.step(1))
            Surface(shape: ArcBand(from: used, to: used + more, width: band, round: false), color: palette.step(3))
            Surface(shape: ArcBand(from: 0, to: used, width: band, round: true), color: palette.step(5))
            // Glass is not drawn inside a rotated view, so the arc is placed by its angles instead of rotating the gauge.
            VStack(spacing: 1) {
                Text(label).font(.system(size: min(24, side * 0.2), weight: .semibold)).foregroundStyle(palette.text).contentTransition(.numericText())
                if side >= 90 { Text(sublabel).font(.system(size: 11)).foregroundStyle(palette.soft) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: side - 2 * band - 8)
        }
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(design.actionDeep)
                .frame(width: 19, height: 19)
                .background(Circle().fill(design.action))
                .background(Circle().stroke(design.action, lineWidth: 1.5).scaleEffect(1 + phase * 0.9).opacity(1 - phase))
        }
        .accessibilityLabel("Needs attention")
    }
}
