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
    /// The glass window's corners, set in the Design menu (`DesignSettings.windowRadius`).
    static var windowRadius: CGFloat { CornerRadii.window }
    /// An invisible band around the glass that belongs to the window: the resize zone, where macOS puts it for other windows, just
    /// outside the visible edge. Without it, a drag started there (or on a rounded corner) went to the app behind.
    static let resizeMargin: CGFloat = 8
    /// The tiles' corners, set in the Design menu (`DesignSettings.tileRadius`).
    static var tileRadius: CGFloat { CornerRadii.tile }
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

/// The corner radii chosen in the Design menu, read straight from the defaults so any view (and the shadow window) can read them.
/// `Design` carries them too, so changing one redraws every view that reads the design.
enum CornerRadii {
    static let defaultTile: CGFloat = 19
    static let defaultWindow: CGFloat = 28
    static let choices: [CGFloat] = [0, 6, 10, 14, 19, 24, 28, 34, 40]

    #if MACSPACE_DEV
    static var tile: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "design.tileRadius") as? Double ?? Double(defaultTile)) }
    static var window: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "design.windowRadius") as? Double ?? Double(defaultWindow)) }
    #else
    // A release has no Design menu: the corners are always the defaults.
    static var tile: CGFloat { defaultTile }
    static var window: CGFloat { defaultWindow }
    #endif
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


/// The caption's typeface at one optical size whatever its point size. The system font follows its size with its optical size (17
/// at 17 points and below, 22 at 22): a caption sized to its tile (`CaptionSize`) changed its cut as the tile grew, and its strokes
/// thinned out as the tile was resized. Pinned to the small sizes' cut, it keeps one weight from the smallest tile to the largest.
///
/// The typeface, weights and optical size can be changed in the design tools' Widget Type window (`TileType`).
enum CaptionFont {
    private static let opticalSizeAxis = NSNumber(value: 0x6F70_737A) // 'opsz'

    static func font(size: CGFloat, weight: TypeWeight) -> NSFont {
        let type = TileType.current
        // SF Pro Display and Text are the system font's own cuts, at their optical sizes: installed only with Apple's fonts, they are
        // drawn from the system font on every Mac.
        let systemCuts = ["SF Pro Display": 28.0, "SF Pro Text": 17.0, "SF Pro": type.opticalSize]
        if let family = type.family, systemCuts[family] == nil,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: weight.managerWeight, size: size) {
            return font
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight.weight)
        // The weight is part of the variation too: the new one is added to it, not put in its place.
        var variation = (CTFontCopyVariation(base) as? [NSNumber: NSNumber]) ?? [:]
        variation[opticalSizeAxis] = NSNumber(value: type.family.flatMap { systemCuts[$0] } ?? type.opticalSize)
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.variation: variation]), size: size) ?? base
    }

    /// A tile's title and its figure: bold.
    static func title(size: CGFloat) -> NSFont { font(size: size, weight: TileType.current.titleWeight) }

    /// The status line under a title: regular, at its title's size, as it first was. At the page rows' 13 points, or at the smallest
    /// tile's title size on every tile, it read too small under a large tile's title (2026-10-12).
    static func status(size: CGFloat) -> NSFont {
        let type = TileType.current
        return font(size: (size * type.statusScale).rounded(), weight: type.statusWeight)
    }
}

/// How a tile's caption is laid out in `width`: the title and its figure on one line where they fit; otherwise the title, which may
/// take two lines, with the figure on a line of its own under it. The text keeps its size either way: shrunk to fit, a long title ("outros
/// arquivos do sistema 2,46 GB") came out smaller than its neighbours' (2026-10-12). `TileFace` keeps the chart clear of the lines.
struct CaptionLayout {
    let oneLine: Bool
    /// Lines the title and its figure take.
    let lines: Int
    /// What those lines take beyond the one line a caption always has.
    let extraHeight: CGFloat
    /// What those lines take.
    let titleHeight: CGFloat
    /// The widest of those lines.
    let titleWidth: CGFloat

    init(info: TileInfo, size: CGFloat, width: CGFloat) {
        let font = CaptionFont.title(size: size)
        func measure(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let available = max(width, 1)
        let joined = TileCaption.joined(info.title, info.figure)
        let full = measure(joined)
        if full <= available || info.figure == nil && measure(info.title) <= available {
            oneLine = true
            lines = 1
            titleWidth = full
        } else {
            oneLine = false
            let title = measure(info.title)
            let titleLines = min(2, Int(ceil(title / available)))
            lines = (info.figure == nil ? 0 : 1) + titleLines
            titleWidth = min(max(title, info.figure.map(measure) ?? 0), available)
        }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        extraHeight = CGFloat(max(lines - 1, 0)) * lineHeight
        titleHeight = CGFloat(lines) * lineHeight
    }
}

/// The bold title and the status line in a tile's bottom-right corner, both at the tile's caption size; the status in regular, not
/// light, which read thin and washed out on the pale tiles (`CaptionFont.status`). The title's figure goes after it, or under it where the tile is too narrow (`CaptionLayout`). It rolls when
/// its numbers change.
struct TileCaption: View, @preconcurrency Animatable {
    let title: String
    var figure: String?
    let status: String
    var size: CGFloat = 22
    var loading = false
    /// The destination width is known before the tile begins its entrance animation.
    var layoutWidth: CGFloat?
    @Environment(\.design) private var design

    /// The size follows the tile into another cell frame by frame, as the tile grows or shrinks: set at once, the text took its new
    /// size at the start, squeezed into the tile on its way, and settled at the end.
    var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }

    static func joined(_ title: String, _ figure: String?) -> String { figure.map { "\(title) \($0)" } ?? title }

    var body: some View {
        let bold = Font(CaptionFont.title(size: size))
        VStack(alignment: .trailing, spacing: 0) {
            Group {
                if let layoutWidth {
                    let layout = CaptionLayout(info: TileInfo(title: title, figure: figure, status: status), size: size, width: layoutWidth)
                    if layout.oneLine {
                        Text(Self.joined(title, figure)).font(bold).lineLimit(1).fixedSize()
                    } else {
                        stackedTitle(bold)
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        Text(Self.joined(title, figure)).font(bold).lineLimit(1).fixedSize()
                        stackedTitle(bold)
                    }
                }
            }
            .contentTransition(.numericText())
            Text(status)
                .font(Font(CaptionFont.status(size: size)))
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .multilineTextAlignment(.trailing)
        .foregroundStyle(design.ink)
        // No shadow behind the text: a blurred shadow of every caption was redrawn on every frame any tile moved.
        .animation(Theme.value, value: status)
    }

    private func stackedTitle(_ font: Font) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(title).font(font).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let figure { Text(figure).font(font).lineLimit(1) }
        }
        .frame(width: layoutWidth, alignment: .trailing)
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
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !appearsActive)) { context in
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
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .opacity(pressed ? 0.55 : 1)
            .background {
                GlassGround(width: diameter, height: diameter)
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

/// The round buttons' glass, as a capsule of any width (a circle when as wide as high): the active clear glass, or its look drawn
/// by hand where macOS would draw something else (`GlassCircleStyle`). Its width animates frame by frame, so the glass of a pill that
/// grows (`WindowControls`) follows the movement instead of jumping to its new size.
struct GlassGround: View, @preconcurrency Animatable {
    var width: CGFloat
    let height: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var activeState

    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }

    var body: some View {
        Group {
            if activeState != .key && !reduceTransparency {
                // Glass in a window that is not key is drawn in its inactive look, a dark grey disc, by AppKit's glass and
                // SwiftUI's alike, whatever the view asks for (tried 2026-10-12). The buttons keep their look instead: the
                // active glass drawn as it shows.
                // As the active clear glass shows (`ClearGlassCircle`): its 14 % black tint over the page, and light caught on
                // both rims, strongest at the top left. A dark top edge read as a hole, not glass (2026-10-13).
                Capsule().fill(.black.opacity(0.14))
                    .overlay {
                        Capsule().fill(RadialGradient(colors: [.white.opacity(0.10), .clear], center: .topLeading,
                                                      startRadius: 0, endRadius: height))
                    }
                    .overlay {
                        Capsule().strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.6), location: 0),
                                                                      .init(color: .white.opacity(0.08), location: 0.45),
                                                                      .init(color: .white.opacity(0.08), location: 0.6),
                                                                      .init(color: .white.opacity(0.35), location: 1)],
                                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    }
            } else if reduceTransparency {
                // With Reduce Transparency the system draws glass as an opaque disc in its own default colors: one button came
                // out near black and another white, its white symbol lost. A solid light over the page's color instead, the
                // same for every button, with a fine edge.
                Capsule().fill(.white.opacity(0.18))
                    .overlay { Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5) }
            } else {
                ClearGlassCircle(diameter: height)
            }
        }
        .frame(width: width, height: height)
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
