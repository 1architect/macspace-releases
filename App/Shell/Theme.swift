import AppKit
import SwiftUI

import MacSpaceSdk

/// The look of the glass window: sizes, the colors, the motion, and the shared controls.
///
/// Each tile and page is drawn on one deep color (`TileTint`), and one warm color, amber, means "you can act on this" wherever it
/// appears: the part Clean frees, a setting macOS undid, the main action of a page, Apple Intelligence switched on.
enum Theme {
    static let action = Color(hex: 0xEF9F27)
    static let actionLight = Color(hex: 0xFAC775)
    static let actionDeep = Color(hex: 0x412402)

    /// The glass frame around the tiles, and the space between tiles.
    static let frame: CGFloat = 11
    static let spacing: CGFloat = 10
    static let windowRadius: CGFloat = 28
    /// An invisible band around the glass that belongs to the window: the resize zone, where macOS puts it for other windows, just
    /// outside the visible edge. Without it, a drag started there (or on a rounded corner) went to the app behind.
    static let resizeMargin: CGFloat = 8
    static let tileRadius: CGFloat = 19
    static let defaultSize = CGSize(width: 700, height: 490)
    static let minimumSize = CGSize(width: 520, height: 360)

    // Motion. Springs everywhere, so movements that are interrupted carry on from where they are.
    static let open = Animation.spring(duration: 0.55, bounce: 0.12)
    /// No bounce: the card has to land exactly on its tile, which then takes its place.
    static let close = Animation.spring(duration: 0.5, bounce: 0)
    static let hover = Animation.spring(duration: 0.35, bounce: 0.3)
    /// The lift and lean with the temporary Quick Lift switch on: shorter and with less bounce, so a hover draws fewer frames.
    static let quickHover = Animation.spring(duration: 0.22, bounce: 0.12)
    static let quickLean = Animation.interactiveSpring(duration: 0.16)
    /// A color answering the pointer: quick and without bounce, so it lets go as soon as the pointer leaves.
    static let highlight = Animation.easeOut(duration: 0.12)
    /// How dark the shade over glass under the pointer is: a chart element, and a whole tile.
    static let highlightDarkening = 0.18
    static let tileHoverShade = 0.1
    static let press = Animation.spring(duration: 0.22, bounce: 0.2)
    static let layout = Animation.spring(duration: 0.55, bounce: 0.18)
    /// The window opening: the glass grows in, then the tiles come in one after another (`layout`, `populateStagger` apart).
    static let windowIn = Animation.spring(duration: 0.45, bounce: 0.15)
    static let populateStagger = 0.06
    /// The window closing: the tiles leave in reverse order, quickly and without bounce, then the glass shrinks away.
    static let depopulate = Animation.smooth(duration: 0.26)
    static let depopulateStagger = 0.035
    static let windowOut = Animation.smooth(duration: 0.28)
    static let value = Animation.smooth(duration: 0.9)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// One tile color and its steps: `base` is the tile, `steps` go from just off the base to the strongest mark, `text` reads on all of
/// them. The schemes live in `PaletteScheme`.
struct TintPalette {
    let base: Color
    let steps: [Color]
    let text: Color

    /// A step by position, 0 the closest to the base; clamped.
    func step(_ index: Int) -> Color { steps[min(max(index, 0), steps.count - 1)] }
    /// For secondary text and quiet marks.
    var soft: Color { step(4) }
}


/// The bold title and light status line in a tile's bottom-right corner. The status rolls when its numbers change.
struct TileCaption: View {
    let title: String
    let status: String
    var size: CGFloat = 22
    var loading = false
    @Environment(\.design) private var design

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(title).font(.system(size: size, weight: .bold))
            Text(status)
                .font(.system(size: size, weight: .light))
                .contentTransition(.numericText())
                .opacity(loading ? 0.65 : 1)
        }
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .foregroundStyle(design.ink)
        // No shadow behind the text: a blurred shadow of every caption was redrawn on every frame any tile moved.
        .animation(Theme.value, value: status)
    }
}

/// The page's main action is the amber pill, the action color; `.normal` actions get a quiet translucent one. With Liquid Glass on,
/// both are glass, the main one tinted with the action color.
struct PillButtonStyle: ButtonStyle {
    var prominent = true
    var destructive = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.design) private var design
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 13, weight: .semibold))
            .foregroundStyle(prominent ? design.actionDeep : (destructive ? Color(hex: design.isLight ? 0xA32D2D : 0xF7C1C1) : design.ink))
            .padding(.horizontal, compact ? 10 : 15)
            .padding(.vertical, compact ? 4 : 7)
            .background {
                if design.glass {
                    Color.clear.glassEffect(.regular.tint(prominent ? (hovering ? design.actionLight : design.action) : nil).interactive(), in: .capsule)
                } else {
                    Capsule().fill(prominent ? AnyShapeStyle(hovering ? design.actionLight : design.action) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.16 : 0.09)))
                    Capsule().strokeBorder(Color.primary.opacity(prominent ? 0 : 0.12), lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.94 : (hovering ? 1.03 : 1))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
            .onHover { hovering = $0 && isEnabled }
            .animation(Theme.press, value: configuration.isPressed)
            .animation(Theme.hover, value: hovering)
    }
}

/// A round glass button, as MacBat's onboarding draws it (`BotaoRedondoDeVidro`): AppKit's clear glass in the dark appearance with a
/// light dark tint, 36 points, a white symbol that turns while busy. Under the pointer it grows a little and lightens; pressed, it
/// shrinks and the symbol dims. Used for close/back and Refresh in the top-left corner.
struct GlassCircleButton: View {
    static let diameter: CGFloat = 36
    static let margin: CGFloat = 8

    let symbol: String
    let help: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Busy, the symbol itself turns, in the same white: the system spinner drew grey on the clear glass, whatever its tint.
            SpinningSymbol(symbol: symbol, spinning: busy)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
        }
        .buttonStyle(GlassCircleStyle(diameter: Self.diameter))
        .disabled(busy)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A symbol that turns while `spinning`. It gathers speed instead of jumping to it, turns at an even pace (the system's rotate effect
/// eased in and out of every turn, so it went in jerks), and when it stops it slows down from the speed it had to upright, instead of
/// snapping back. The whole movement is worked out from the clock, so speed never jumps. With Reduce Motion it dims while busy instead.
struct SpinningSymbol: View {
    let symbol: String
    let spinning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = Motion.rest

    enum Motion: Equatable {
        case rest
        /// Speeding up from `from` degrees and 0, then turning evenly.
        case spinning(since: Date, from: Double)
        /// Slowing from `from` degrees at `speed` degrees a second to a stop at `to`, a whole number of turns, in `duration`.
        case settling(since: Date, from: Double, speed: Double, to: Double, duration: Double)
    }

    /// Seconds per turn at full speed, and how quickly it gets there.
    nonisolated static let turn = 0.85
    nonisolated static let rampUp = 0.22

    nonisolated static func speed(after elapsed: TimeInterval) -> Double {
        360 / turn * (1 - exp(-max(elapsed, 0) / rampUp))
    }

    nonisolated static func angle(_ motion: Motion, at date: Date) -> Double {
        switch motion {
        case .rest:
            return 0
        case let .spinning(since, from):
            let t = max(date.timeIntervalSince(since), 0)
            return from + 360 / turn * (t - rampUp * (1 - exp(-t / rampUp)))
        case let .settling(since, from, speed, to, duration):
            // A curve that leaves at `speed` and arrives at `to` with none (cubic Hermite); it never passes `to`.
            let s = min(max(date.timeIntervalSince(since) / duration, 0), 1)
            let s2 = s * s, s3 = s2 * s
            return (2 * s3 - 3 * s2 + 1) * from + (s3 - 2 * s2 + s) * duration * speed + (-2 * s3 + 3 * s2) * to
        }
    }

    /// Where a spin that is going at `speed` from `angle` comes to rest, and how long it takes: the next upright position at least a
    /// fifth of a second's travel ahead, reached in 0.35 to 0.8 seconds.
    nonisolated static func settle(from angle: Double, speed: Double) -> (to: Double, duration: Double) {
        let to = ((angle + max(speed * 0.2, 30)) / 360).rounded(.up) * 360
        let duration = speed > 0 ? min(max(2 * (to - angle) / speed, 0.35), 0.8) : 0.8
        return (to, duration)
    }

    var body: some View {
        TimelineView(.animation(paused: motion == .rest)) { context in
            Image(systemName: symbol)
                .rotationEffect(.degrees(Self.angle(motion, at: context.date)))
        }
        .opacity(reduceMotion && spinning ? 0.5 : 1)
        .animation(.smooth(duration: 0.3), value: spinning)
        .onChange(of: spinning, initial: true) { _, now in
            guard !reduceMotion else { motion = .rest; return }
            let date = Date()
            switch (now, motion) {
            case (true, .rest):
                motion = .spinning(since: date, from: 0)
            case (true, .settling):
                motion = .spinning(since: date, from: Self.angle(motion, at: date).truncatingRemainder(dividingBy: 360))
            case let (false, .spinning(since, _)):
                let angle = Self.angle(motion, at: date)
                let speed = Self.speed(after: date.timeIntervalSince(since))
                let end = Self.settle(from: angle, speed: speed)
                let settling = Motion.settling(since: date, from: angle, speed: speed, to: end.to, duration: end.duration)
                motion = settling
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(end.duration))
                    // Upright again: a whole number of turns is the same as none, and the clock can stop.
                    if motion == settling { motion = .rest }
                }
            default:
                break
            }
        }
    }
}

/// The glass goes in the style, under the label, so it grows and shrinks with the symbol.
private struct GlassCircleStyle: ButtonStyle {
    let diameter: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .opacity(pressed ? 0.55 : 1)
            .background {
                ClearGlassCircle(diameter: diameter)
                    // A light over the glass under the pointer, a little less while pressed.
                    .overlay { Circle().fill(.white.opacity(hovering ? (pressed ? 0.06 : 0.12) : 0)) }
            }
            .scaleEffect(pressed ? 0.88 : (hovering ? 1.08 : 1))
            .onHover { hovering = $0 && isEnabled }
            .onChange(of: isEnabled) { _, enabled in if !enabled { hovering = false } }
            .animation(Theme.press, value: pressed)
            .animation(Theme.hover, value: hovering)
    }
}

/// `NSGlassEffectView` dressed like MacBat's unselected pill: dark appearance, the clear style and a 14 % black tint. With Reduce
/// Transparency it keeps the system's default glass. It never takes clicks; the SwiftUI button above it does.
private struct ClearGlassCircle: NSViewRepresentable {
    let diameter: CGFloat

    final class GlassView: NSGlassEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> GlassView {
        let glass = GlassView()
        glass.cornerRadius = diameter / 2
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            glass.appearance = NSAppearance(named: .darkAqua)
            glass.style = .clear
            glass.tintColor = NSColor.black.withAlphaComponent(0.14)
        }
        return glass
    }

    func updateNSView(_ nsView: GlassView, context: Context) {
        nsView.cornerRadius = diameter / 2
    }
}

/// A band of light sweeping across, for things that are still loading.
struct Shimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: (phase * 1.6 - 0.6) * proxy.size.width)
            }
        }
        .allowsHitTesting(false)
        .clipped()
    }
}
