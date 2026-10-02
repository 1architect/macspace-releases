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
    static let tileRadius: CGFloat = 19
    static let defaultSize = CGSize(width: 700, height: 490)
    static let minimumSize = CGSize(width: 520, height: 360)

    // Motion. Springs everywhere, so movements that are interrupted carry on from where they are.
    static let open = Animation.spring(duration: 0.55, bounce: 0.12)
    /// No bounce: the card has to land exactly on its tile, which then takes its place.
    static let close = Animation.spring(duration: 0.5, bounce: 0)
    static let hover = Animation.spring(duration: 0.35, bounce: 0.3)
    /// A color answering the pointer: quick and without bounce, so it lets go as soon as the pointer leaves.
    static let highlight = Animation.easeOut(duration: 0.12)
    /// How much glass under the pointer darkens its color.
    static let highlightDarkening = 0.22
    static let press = Animation.spring(duration: 0.22, bounce: 0.2)
    static let layout = Animation.spring(duration: 0.55, bounce: 0.18)
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
        .shadow(color: .black.opacity(design.isLight ? 0 : 0.18), radius: 6)
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
/// light dark tint, 36 points, a white symbol that dims while pressed. Used for close/back and Refresh in the top-left corner.
struct GlassCircleButton: View {
    static let diameter: CGFloat = 36
    static let margin: CGFloat = 8

    let symbol: String
    let help: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .foregroundStyle(.white)
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(Circle())
        }
        .buttonStyle(DimWhenPressed())
        .background(ClearGlassCircle(diameter: Self.diameter))
        .disabled(busy)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct DimWhenPressed: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.5 : 1)
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
