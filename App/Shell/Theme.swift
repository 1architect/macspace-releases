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
    /// A switch flipping, and flipping back when its change failed.
    static let toggle = Animation.spring(duration: 0.3, bounce: 0.15)
    /// One page giving way to another in the same window: a group's items, or Settings over a module's page.
    static let push = Animation.spring(duration: 0.45, bounce: 0.1)
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
                if design.glass && prominent {
                    // The action color is drawn inside the glass, not given as its tint: macOS greys a glass's tint out while the window
                    // is not the active one, and the main action lost its color whenever another app was in front.
                    Capsule().fill(hovering ? design.actionLight : design.action)
                        .glassEffect(.regular.interactive(), in: .capsule)
                } else if design.glass {
                    Color.clear.glassEffect(.regular.interactive(), in: .capsule)
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
/// light dark tint, 36 points, a symbol in the text's color, loading dots while busy. Under the pointer it grows a little and
/// lightens; pressed, it shrinks and the symbol dims. Used for close/back in the top-left corner and Refresh in the top-right one.
struct GlassCircleButton: View {
    static let diameter: CGFloat = 36
    static let margin: CGFloat = 8

    let symbol: String
    let help: String
    var busy = false
    let action: () -> Void
    @Environment(\.design) private var design

    /// Each symbol's height. The symbol is drawn to its own outline, not as text: as text it kept room below for a baseline and sat
    /// low in the circle.
    private static func glyphHeight(_ symbol: String) -> CGFloat {
        switch symbol {
        case "xmark": return 12
        case "chevron.left": return 14
        default: return 16
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Busy, the symbol makes way for the loading dots, in the same color: the system spinner drew grey on the clear glass.
                if busy {
                    LoadingDots()
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    Image(systemName: symbol)
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.medium)
                        .frame(height: Self.glyphHeight(symbol))
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            // The text's color: white on the deep palettes, ink on paper, where white was lost on the light page.
            .foregroundStyle(design.ink)
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(Circle())
            .animation(Theme.press, value: busy)
        }
        .buttonStyle(GlassCircleStyle(diameter: Self.diameter))
        .disabled(busy)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Three dots pulsing one after another, as the charts do while they load: what a busy round button shows in place of its
/// symbol. With Reduce Motion they stay dimmed instead.
struct LoadingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            HStack(spacing: 3.5) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = LoadingWave.opacity(context.date, index: index, count: 3, loading: true, reduceMotion: reduceMotion)
                    Circle()
                        .frame(width: 4.5, height: 4.5)
                        .scaleEffect(0.75 + 0.25 * wave)
                        .opacity(wave)
                }
            }
        }
    }
}

/// The glass goes in the style, under the label, so it grows and shrinks with the symbol.
private struct GlassCircleStyle: ButtonStyle {
    let diameter: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .opacity(pressed ? 0.55 : 1)
            .background {
                Group {
                    if reduceTransparency {
                        // With Reduce Transparency the system draws glass as an opaque disc in its own default colors: one button came
                        // out near black and another white, its white symbol lost. A solid light over the page's color instead, the
                        // same for every button, with a fine edge.
                        Circle().fill(.white.opacity(0.18))
                            .overlay { Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.5) }
                    } else {
                        ClearGlassCircle(diameter: diameter)
                    }
                }
                // A light over the button under the pointer, a little less while pressed.
                .overlay { Circle().fill(.white.opacity(hovering ? (pressed ? 0.06 : 0.12) : 0)) }
            }
            .scaleEffect(pressed ? 0.88 : (hovering ? 1.08 : 1))
            .onHover { hovering = $0 && isEnabled }
            .onChange(of: isEnabled) { _, enabled in if !enabled { hovering = false } }
            .animation(Theme.press, value: pressed)
            .animation(Theme.hover, value: hovering)
    }
}

/// `NSGlassEffectView` dressed like MacBat's unselected pill: dark appearance, the clear style and a 14 % black tint. Not used with
/// Reduce Transparency (`GlassCircleStyle`). It never takes clicks; the SwiftUI button above it does.
private struct ClearGlassCircle: NSViewRepresentable {
    let diameter: CGFloat

    final class GlassView: NSGlassEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> GlassView {
        let glass = GlassView()
        glass.cornerRadius = diameter / 2
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.style = .clear
        glass.tintColor = NSColor.black.withAlphaComponent(0.14)
        return glass
    }

    func updateNSView(_ nsView: GlassView, context: Context) {
        nsView.cornerRadius = diameter / 2
    }
}
