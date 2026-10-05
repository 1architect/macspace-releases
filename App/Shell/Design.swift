import AppKit
import MacSpaceSdk
import SwiftUI

/// The color schemes the tiles and pages can be drawn in. Temporary: they are here to compare looks, switched from the Design menu
/// or from Settings. Every scheme keeps the same roles: one ground per tile color, steps for marks, and one action color.
public enum PaletteScheme: String, CaseIterable, Identifiable, Sendable {
    case deep
    case mono
    case sketch
    case nord
    case paper
    // The three night and day pairs, drawn on the system's own window background (Window Glass off). Day and night of a pair share
    // their hues; the night ramp runs dark to light, the day ramp light to dark, so a mark keeps its place in both.
    case auroraNight
    case auroraDay
    case terraNight
    case terraDay
    case inkNight
    case inkDay

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .deep: return "Deep"
        case .mono: return "Mono"
        case .sketch: return "Sketch"
        case .nord: return "Nord"
        case .paper: return "Paper (light)"
        case .auroraNight: return "Aurora, night"
        case .auroraDay: return "Aurora, day"
        case .terraNight: return "Terra, night"
        case .terraDay: return "Terra, day"
        case .inkNight: return "Ink, night"
        case .inkDay: return "Ink, day"
        }
    }

    /// Light grounds take dark text.
    var isLight: Bool {
        switch self {
        case .paper, .auroraDay, .terraDay, .inkDay: return true
        default: return false
        }
    }

    var action: (fill: Color, light: Color, deep: Color) {
        switch self {
        case .sketch: return (Color(hex: 0xF5B800), Color(hex: 0xFFD54D), Color(hex: 0x3D2C00))
        case .nord: return (Color(hex: 0xEBCB8B), Color(hex: 0xF3DDB0), Color(hex: 0x3B3220))
        case .paper, .auroraDay: return (Color(hex: 0xE58A12), Color(hex: 0xF0A848), Color(hex: 0x412402))
        case .auroraNight: return (Color(hex: 0xEF9F27), Color(hex: 0xFAC775), Color(hex: 0x412402))
        case .terraNight: return (Color(hex: 0xF2B134), Color(hex: 0xF8CF7A), Color(hex: 0x3D2800))
        case .terraDay: return (Color(hex: 0xD98A00), Color(hex: 0xB86F00), Color(hex: 0x3D2400))
        case .inkNight: return (Color(hex: 0xC6F135), Color(hex: 0xDDF98A), Color(hex: 0x26300A))
        // Light and deep lime read on a near-white tile, where the night's pale lime would vanish.
        case .inkDay: return (Color(hex: 0x9BC900), Color(hex: 0x6E9100), Color(hex: 0x1F2A00))
        case .deep, .mono: return (Color(hex: 0xEF9F27), Color(hex: 0xFAC775), Color(hex: 0x412402))
        }
    }

    func palette(_ tint: TileTint) -> TintPalette {
        func make(_ base: UInt32, _ steps: [UInt32], _ text: UInt32) -> TintPalette {
            TintPalette(base: Color(hex: base), steps: steps.map { Color(hex: $0) }, text: Color(hex: text))
        }
        switch (self, tint) {
        // Deep: one deep hue per module.
        case (.deep, .violet): return make(0x26215C, [0x2F2970, 0x3C3489, 0x534AB7, 0x7F77DD, 0xAFA9EC, 0xCECBF6], 0xEEEDFE)
        case (.deep, .blue): return make(0x042C53, [0x08386A, 0x0C447C, 0x185FA5, 0x378ADD, 0x85B7EB, 0xB5D4F4], 0xE6F1FB)
        case (.deep, .teal): return make(0x04342C, [0x064236, 0x085041, 0x0F6E56, 0x1D9E75, 0x5DCAA5, 0x9FE1CB], 0xE1F5EE)
        case (.deep, .graphite): return make(0x2C2C2A, [0x3A3A37, 0x444441, 0x5F5E5A, 0x888780, 0xB4B2A9, 0xD3D1C7], 0xF1EFE8)
        case (.deep, .slate): return make(0x1E2329, [0x2B323A, 0x3A434D, 0x55606C, 0x8A96A3, 0xB4BDC7, 0xDCE3EA], 0xEEF2F6)
        // Mono: graphite everywhere, a hair warmer or cooler per module, so only amber stands out.
        case (.mono, .violet): return make(0x24232A, [0x302F37, 0x3D3C45, 0x55545F, 0x82808C, 0xB0AEB8, 0xD6D4DC], 0xF2F1F5)
        case (.mono, .blue): return make(0x20242A, [0x2B3038, 0x383E47, 0x515862, 0x7E8691, 0xADB4BD, 0xD4D9DF], 0xF0F3F6)
        case (.mono, .teal): return make(0x212624, [0x2C322F, 0x39403C, 0x525A55, 0x7F8882, 0xAEB6B1, 0xD5DBD7], 0xF0F4F2)
        case (.mono, .graphite): return make(0x262524, [0x32302F, 0x3F3D3B, 0x585553, 0x85827F, 0xB3B0AC, 0xD8D6D2], 0xF4F2EF)
        case (.mono, .slate): return make(0x1C1C1E, [0x28282B, 0x353539, 0x4E4E53, 0x7C7C82, 0xACACB1, 0xD5D5D9], 0xF2F2F4)
        // Sketch: the hues of the first sketches (magenta, cyan, coral) as deep grounds.
        case (.sketch, .violet): return make(0x3A0B52, [0x4A0F69, 0x5E1385, 0x8A1FBF, 0xB620E0, 0xD77AF2, 0xEDC2FA], 0xFAEFFE)
        case (.sketch, .blue): return make(0x062F4A, [0x0A3D60, 0x0F4F7C, 0x1673AD, 0x33A6E0, 0x7FCDF5, 0xC4EAFC], 0xEEF9FE)
        case (.sketch, .teal): return make(0x4A1B0C, [0x5C2412, 0x712B13, 0x993C1D, 0xD85A30, 0xF0997B, 0xF8CDBD], 0xFDF1EC)
        case (.sketch, .graphite): return make(0x2A1F4D, [0x352862, 0x433279, 0x5C46A8, 0x8A6FE0, 0xB8A6F2, 0xDDD3FA], 0xF4F0FE)
        case (.sketch, .slate): return make(0x3A3A3A, [0x464646, 0x535353, 0x6E6E6E, 0x969696, 0xBEBEBE, 0xE0E0E0], 0xF7F7F7)
        // Nord: polar night grounds, frost and aurora marks.
        case (.nord, .violet): return make(0x332E40, [0x3D374D, 0x48405B, 0x5E5476, 0x8D7BA3, 0xB48EAD, 0xD8C5D5], 0xECEFF4)
        case (.nord, .blue): return make(0x2E3440, [0x3B4252, 0x434C5E, 0x4C566A, 0x5E81AC, 0x81A1C1, 0xB7CBE0], 0xECEFF4)
        case (.nord, .teal): return make(0x2B3634, [0x33403E, 0x3C4B48, 0x4F6460, 0x6F9893, 0x8FBCBB, 0xC3DEDD], 0xECEFF4)
        case (.nord, .graphite): return make(0x3B4252, [0x434C5E, 0x4C566A, 0x616E88, 0x8792A8, 0xD8DEE9, 0xE5E9F0], 0xECEFF4)
        case (.nord, .slate): return make(0x2E3440, [0x3B4252, 0x434C5E, 0x4C566A, 0x7B88A1, 0xA9B4C6, 0xD8DEE9], 0xECEFF4)
        // Paper: light grounds, the same hues as Deep for marks, dark text.
        case (.paper, .violet): return make(0xEEEDFE, [0xE2DFFC, 0xCECBF6, 0xAFA9EC, 0x7F77DD, 0x534AB7, 0x3C3489], 0x26215C)
        case (.paper, .blue): return make(0xE6F1FB, [0xD5E7F8, 0xB5D4F4, 0x85B7EB, 0x378ADD, 0x185FA5, 0x0C447C], 0x042C53)
        case (.paper, .teal): return make(0xE1F5EE, [0xCBEEE1, 0x9FE1CB, 0x5DCAA5, 0x1D9E75, 0x0F6E56, 0x085041], 0x04342C)
        case (.paper, .graphite): return make(0xF1EFE8, [0xE4E2DA, 0xD3D1C7, 0xB4B2A9, 0x888780, 0x5F5E5A, 0x444441], 0x2C2C2A)
        case (.paper, .slate): return make(0xEEF2F6, [0xE1E7EE, 0xCBD3DC, 0xA9B4C0, 0x7D8996, 0x55606C, 0x3A434D], 0x1E2329)
        // Aurora: a hue per module (violet, blue, teal, rose, slate); day grounds are tinted, not white, so tiles tell apart.
        case (.auroraNight, .violet): return make(0x2E2870, [0x464090, 0x5E57B0, 0x766ED0, 0x8E86F0, 0xAEA8F5, 0xCECBF9], 0xEEEDFE)
        case (.auroraNight, .blue): return make(0x0A3A6B, [0x1A528B, 0x2A6AAA, 0x3A83CA, 0x4A9BEA, 0x7EB8F0, 0xB2D4F5], 0xE6F1FB)
        case (.auroraNight, .teal): return make(0x0A4036, [0x125D4A, 0x1A7A5E, 0x239772, 0x2BB486, 0x68CAA9, 0xA4DFCB], 0xE1F5EE)
        case (.auroraNight, .graphite): return make(0x5A1B33, [0x7C2E4A, 0x9D4061, 0xBE5378, 0xE0668F, 0xE992AF, 0xF2BED0], 0xFBEAF0)
        case (.auroraNight, .slate): return make(0x2D353E, [0x46505B, 0x5E6A78, 0x768595, 0x8FA0B2, 0xAFBBC9, 0xCED7DF], 0xEEF2F6)
        case (.auroraDay, .violet): return make(0xD8D4F8, [0xBDB8EB, 0xA39DDE, 0x8881D1, 0x6E66C4, 0x534AB7, 0x3C368A], 0x26215C)
        case (.auroraDay, .blue): return make(0xBBDCF8, [0x9AC3E7, 0x7AAAD7, 0x5991C6, 0x3978B6, 0x185FA5, 0x0E467C], 0x042C53)
        case (.auroraDay, .teal): return make(0xAEEBD3, [0x8ED2BA, 0x6EB9A1, 0x4FA088, 0x2F876F, 0x0F6E56, 0x0A5141], 0x04342C)
        case (.auroraDay, .graphite): return make(0xF8C4D6, [0xE5A7BC, 0xD28BA3, 0xBF6E89, 0xAC5270, 0x993556, 0x72253F], 0x4B1528)
        case (.auroraDay, .slate): return make(0xD3DAE3, [0xBAC2CB, 0xA1A9B3, 0x87919C, 0x6E7884, 0x55606C, 0x3A424A], 0x1E2329)
        // Terra: earthy hues (plum, petrol, moss, umber, slate).
        case (.terraNight, .violet): return make(0x47213D, [0x653256, 0x84446E, 0xA25686, 0xC0679F, 0xD393BB, 0xE5BED8], 0xF8EAF4)
        case (.terraNight, .blue): return make(0x0F3F4D, [0x1A5868, 0x247184, 0x2F8AA0, 0x3AA3BB, 0x72BECF, 0xABD8E2], 0xE3F3F6)
        case (.terraNight, .teal): return make(0x26402A, [0x3A5C36, 0x4E7743, 0x629250, 0x76AE5C, 0x9DC589, 0xC4DCB5], 0xEBF3E2)
        case (.terraNight, .graphite): return make(0x3A3027, [0x56493D, 0x716253, 0x8C7C69, 0xA8957F, 0xC1B3A1, 0xDAD0C4], 0xF3EEE6)
        case (.terraNight, .slate): return make(0x2D353E, [0x46505B, 0x5E6A78, 0x768595, 0x8FA0B2, 0xAFBBC9, 0xCED7DF], 0xEEF2F6)
        case (.terraDay, .violet): return make(0xEBCFE3, [0xD8B1CD, 0xC493B7, 0xB176A1, 0x9D588B, 0x8A3A75, 0x622A54], 0x3A1A33)
        case (.terraDay, .blue): return make(0xBFE0E8, [0x9FC9D4, 0x7FB3C0, 0x5E9CAB, 0x3E8697, 0x1E6F83, 0x145262], 0x0B3440)
        case (.terraDay, .teal): return make(0xCFE5BF, [0xB2D0A2, 0x95BA85, 0x79A568, 0x5C8F4B, 0x3F7A2E, 0x2F5627], 0x1F3320)
        case (.terraDay, .graphite): return make(0xE3D5C3, [0xCCBDAA, 0xB4A592, 0x9D8C79, 0x857461, 0x6E5C48, 0x4E4134], 0x2E2620)
        case (.terraDay, .slate): return make(0xD5DCE3, [0xBBC3CB, 0xA2AAB3, 0x88929C, 0x6F7984, 0x55606C, 0x3C454E], 0x232A30)
        // Ink: quiet neutral grounds, near-white by day; the color is in the marks.
        case (.inkNight, .violet): return make(0x2A2838, [0x48436A, 0x665E9C, 0x8579CD, 0xA394FF, 0xBDB3FD, 0xD8D2FA], 0xF2F1F8)
        case (.inkNight, .blue): return make(0x232C38, [0x2E4A6A, 0x38689C, 0x4285CD, 0x4DA3FF, 0x83BEFD, 0xBAD9FB], 0xF0F4F9)
        case (.inkNight, .teal): return make(0x212E29, [0x285848, 0x2F8267, 0x36AC86, 0x3DD6A5, 0x78E1BF, 0xB4EBD9], 0xEFF6F3)
        case (.inkNight, .graphite): return make(0x33232A, [0x663546, 0x994762, 0xCC597E, 0xFF6B9A, 0xFD97B8, 0xFBC4D5], 0xF9F0F3)
        case (.inkNight, .slate): return make(0x2A2C31, [0x464A52, 0x626973, 0x7E8894, 0x9AA6B5, 0xB7BFCA, 0xD4D9DF], 0xF1F2F4)
        case (.inkDay, .violet): return make(0xF7F5FD, [0xD8D2F5, 0xB9AFED, 0x998BE6, 0x7A68DE, 0x5B45D6, 0x3C3080], 0x1C1A2B)
        case (.inkDay, .blue): return make(0xF2F7FD, [0xC8DCF4, 0x9EC1EB, 0x73A5E3, 0x498ADA, 0x1F6FD1, 0x1A467C], 0x141C26)
        case (.inkDay, .teal): return make(0xF1F9F6, [0xC4E6DB, 0x96D3C0, 0x69C0A5, 0x3BAD8A, 0x0E9A6F, 0x105E46], 0x12211C)
        case (.inkDay, .graphite): return make(0xFDF3F7, [0xF4CEDC, 0xEBA9C0, 0xE384A5, 0xDA5F89, 0xD13A6E, 0x7C2744], 0x26141B)
        case (.inkDay, .slate): return make(0xF5F6F8, [0xD6D9DE, 0xB6BBC3, 0x979EA9, 0x77808E, 0x586374, 0x373E48], 0x16181C)
        }
    }
}

/// What the window's background follows, apart from the tiles (which keep the palette): the palette, the system's appearance
/// (changing with it, system wide), or light or dark whatever either says.
public enum BackgroundAppearance: String, CaseIterable, Identifiable, Sendable {
    case palette
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .palette: return "Follow Palette"
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// How the app is drawn right now: the palette, and whether tiles and their elements are Liquid Glass. Handed down the view tree in
/// the environment, so switching redraws everything at once.
struct Design: Equatable {
    var scheme: PaletteScheme = .deep
    var backgroundAppearance = BackgroundAppearance.palette
    /// The system's appearance is dark right now (`DesignSettings` keeps it up to date).
    var systemIsDark = false
    var glass = false
    /// Temporary, for finding what lags on hover: tiles lift, and tilt toward the pointer; glass is shaded under the pointer.
    var lift = true
    var tilt = true
    var hoverShade = true
    /// Temporary, for measuring GPU use: chart elements (blocks, dots, arcs) are glass, on glass tiles and flat ones alike, or flat color.
    var glassElements = true
    /// Temporary, for measuring GPU use: the window clipped to its rounded corners; tiles following the pointer.
    var clipWindow = true
    var trackPointer = true
    /// Temporary, for measuring GPU use: the window itself is glass over the desktop, or a solid color.
    var windowGlass = true
    /// The glass window's whole background (blur, glass, fill and edge); off, the widgets float over the desktop with nothing behind them.
    var windowBackground = true
    /// Temporary, for measuring GPU use and comparing looks: pages fade their content out at the scroll edges (the system's effect),
    /// or cut it off cleanly.
    var pageEdgeFade = false
    /// Temporary, for measuring GPU use and comparing looks: tiles of the lighter `.clear` glass instead of `.regular`; a shorter lift
    /// and lean with less bounce.
    var clearTileGlass = false
    var quickLift = false
    /// Temporary: the Color Lab's colors and fills for this palette (`ColorLab.swift`).
    var lab = LabOverrides()
    /// The tiles' and the glass window's corners (`CornerRadii`); here so a change redraws everything.
    var tileRadius = CornerRadii.defaultTile
    var windowRadius = CornerRadii.defaultWindow

    /// The lift's animation, and the lean's.
    var liftAnimation: Animation { quickLift ? Theme.quickHover : Theme.hover }
    var leanAnimation: Animation { quickLift ? Theme.quickLean : .interactiveSpring(duration: 0.25) }

    func palette(_ tint: TileTint) -> TintPalette { scheme.palette(tint).applying(lab, tint: tint) }
    var action: Color { lab.color(.action) ?? scheme.action.fill }
    var actionLight: Color { lab.color(.actionLight) ?? scheme.action.light }
    var actionDeep: Color { lab.color(.actionDeep) ?? scheme.action.deep }
    var isLight: Bool { scheme.isLight }
    /// Whether the window's background is light: the palette's, the system's, or the one chosen.
    var backgroundIsLight: Bool {
        switch backgroundAppearance {
        case .palette: return isLight
        case .system: return !systemIsDark
        case .light: return true
        case .dark: return false
        }
    }
    /// Text on tiles and pages.
    var ink: Color { lab.color(.ink) ?? (isLight ? Color(hex: 0x1C1C1E) : .white) }
    /// The Color Lab's fill for a part of the app; nil draws it as before.
    func fill(_ target: FillTarget) -> FillSpec? { lab.fill(target) }
    /// The color scheme pages and their controls are drawn in.
    var colorScheme: ColorScheme { isLight ? .light : .dark }
    /// macOS's own window background in the light or dark the background follows (`backgroundIsLight`): the solid window (Window
    /// Glass off) is drawn in it, so day and night follow the system's defaults.
    var systemWindowColor: Color {
        var resolved = NSColor.windowBackgroundColor
        NSAppearance(named: backgroundIsLight ? .aqua : .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? resolved
        }
        return Color(nsColor: resolved)
    }
}

extension EnvironmentValues {
    @Entry var design = Design()
}

/// The user's choice, kept in UserDefaults. Temporary, for comparing looks.
@MainActor
public final class DesignSettings: ObservableObject {
    public static let shared = DesignSettings()
    private let defaults: UserDefaults

    @Published public var scheme: PaletteScheme { didSet { defaults.set(scheme.rawValue, forKey: "design.palette") } }
    @Published public var backgroundAppearance: BackgroundAppearance { didSet { defaults.set(backgroundAppearance.rawValue, forKey: "design.backgroundAppearance") } }
    /// The system's appearance is dark; kept up to date while the app runs, for `.system` backgrounds.
    @Published private(set) var systemIsDark = DesignSettings.readSystemIsDark()
    private var appearanceObserver: NSObjectProtocol?
    @Published public var glass: Bool { didSet { defaults.set(glass, forKey: "design.glass") } }
    @Published public var lift: Bool { didSet { defaults.set(lift, forKey: "design.lift") } }
    @Published public var tilt: Bool { didSet { defaults.set(tilt, forKey: "design.tilt") } }
    @Published public var hoverShade: Bool { didSet { defaults.set(hoverShade, forKey: "design.hoverShade") } }
    @Published public var windowShadow: Bool { didSet { defaults.set(windowShadow, forKey: "design.windowShadow") } }
    @Published public var glassElements: Bool { didSet { defaults.set(glassElements, forKey: "design.glassElements") } }
    @Published public var clipWindow: Bool { didSet { defaults.set(clipWindow, forKey: "design.clipWindow") } }
    @Published public var trackPointer: Bool { didSet { defaults.set(trackPointer, forKey: "design.trackPointer") } }
    @Published public var windowGlass: Bool { didSet { defaults.set(windowGlass, forKey: "design.windowGlass") } }
    @Published public var windowBackground: Bool { didSet { defaults.set(windowBackground, forKey: "design.windowBackground") } }
    @Published public var pageEdgeFade: Bool { didSet { defaults.set(pageEdgeFade, forKey: "design.pageEdgeFade") } }
    @Published public var clearTileGlass: Bool { didSet { defaults.set(clearTileGlass, forKey: "design.clearTileGlass") } }
    @Published public var quickLift: Bool { didSet { defaults.set(quickLift, forKey: "design.quickLift") } }
    /// The edge macOS draws around its own windows: a dark hairline outside, a faint light one inside.
    @Published public var windowBorder: Bool { didSet { defaults.set(windowBorder, forKey: "design.windowBorder") } }
    @Published public var tileRadius: CGFloat { didSet { defaults.set(Double(tileRadius), forKey: "design.tileRadius") } }
    @Published public var windowRadius: CGFloat { didSet { defaults.set(Double(windowRadius), forKey: "design.windowRadius") } }
    /// The standard window's title bar (its title and the band behind it); off, the pages reach the top of the window.
    @Published public var standardTitleBar: Bool { didSet { defaults.set(standardTitleBar, forKey: "design.standardTitleBar") } }
    /// The standard window's sidebar shows each item's symbol.
    @Published public var standardSidebarIcons: Bool { didSet { defaults.set(standardSidebarIcons, forKey: "design.standardSidebarIcons") } }
    /// The standard window's background is Liquid Glass over the desktop instead of the window's solid color.
    @Published public var standardGlassBackground: Bool { didSet { defaults.set(standardGlassBackground, forKey: "design.standardGlassBackground") } }
    /// MacSpace in a standard macOS window with a sidebar instead of the glass window (`StandardWindowView`).
    @Published public var standardWindow: Bool { didSet { defaults.set(standardWindow, forKey: "design.standardWindow") } }
    /// Temporary: the Color Lab's overrides, per palette (`PaletteScheme.rawValue`).
    @Published var colorLab: [String: LabOverrides] {
        didSet { if let data = try? JSONEncoder().encode(colorLab) { defaults.set(data, forKey: "design.colorLab") } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scheme = PaletteScheme(rawValue: defaults.string(forKey: "design.palette") ?? "") ?? .deep
        backgroundAppearance = BackgroundAppearance(rawValue: defaults.string(forKey: "design.backgroundAppearance") ?? "") ?? .palette
        glass = defaults.bool(forKey: "design.glass")
        lift = defaults.object(forKey: "design.lift") as? Bool ?? true
        tilt = defaults.object(forKey: "design.tilt") as? Bool ?? true
        hoverShade = defaults.object(forKey: "design.hoverShade") as? Bool ?? true
        windowShadow = defaults.object(forKey: "design.windowShadow") as? Bool ?? true
        glassElements = defaults.object(forKey: "design.glassElements") as? Bool ?? true
        clipWindow = defaults.object(forKey: "design.clipWindow") as? Bool ?? true
        trackPointer = defaults.object(forKey: "design.trackPointer") as? Bool ?? true
        windowGlass = defaults.object(forKey: "design.windowGlass") as? Bool ?? true
        windowBackground = defaults.object(forKey: "design.windowBackground") as? Bool ?? true
        pageEdgeFade = defaults.bool(forKey: "design.pageEdgeFade")
        clearTileGlass = defaults.bool(forKey: "design.clearTileGlass")
        quickLift = defaults.bool(forKey: "design.quickLift")
        windowBorder = defaults.object(forKey: "design.windowBorder") as? Bool ?? true
        standardWindow = defaults.bool(forKey: "design.standardWindow")
        standardTitleBar = defaults.object(forKey: "design.standardTitleBar") as? Bool ?? true
        standardSidebarIcons = defaults.object(forKey: "design.standardSidebarIcons") as? Bool ?? true
        standardGlassBackground = defaults.bool(forKey: "design.standardGlassBackground")
        tileRadius = CGFloat(defaults.object(forKey: "design.tileRadius") as? Double ?? Double(CornerRadii.defaultTile))
        windowRadius = CGFloat(defaults.object(forKey: "design.windowRadius") as? Double ?? Double(CornerRadii.defaultWindow))
        colorLab = defaults.data(forKey: "design.colorLab").flatMap { try? JSONDecoder().decode([String: LabOverrides].self, from: $0) } ?? [:]
        observeSystemAppearance()
    }

    var design: Design { Design(scheme: scheme, backgroundAppearance: backgroundAppearance, systemIsDark: systemIsDark, glass: glass, lift: lift, tilt: tilt, hoverShade: hoverShade, glassElements: glassElements,
                                  clipWindow: clipWindow, trackPointer: trackPointer,
                                  windowGlass: windowGlass, windowBackground: windowBackground, pageEdgeFade: pageEdgeFade,
                                  clearTileGlass: clearTileGlass, quickLift: quickLift, lab: colorLab[scheme.rawValue] ?? LabOverrides(),
                                  tileRadius: tileRadius, windowRadius: windowRadius) }

    /// The system's setting, global for the user: "Dark" while the appearance is dark, absent while it is light.
    private static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// The system switching between light and dark (by hand, or on its schedule) redraws the backgrounds that follow it.
    private func observeSystemAppearance() {
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemIsDark = Self.readSystemIsDark() }
        }
    }

    /// The current palette's overrides, read and written by the Color Lab.
    var lab: LabOverrides {
        get { colorLab[scheme.rawValue] ?? LabOverrides() }
        set { colorLab[scheme.rawValue] = newValue.isEmpty ? nil : newValue }
    }
}

/// The temporary Design menu: Liquid Glass on or off (⌥⌘G), the palettes (⌥⌘1…9), and switches for what answers the pointer.
public struct DesignCommands: Commands {
    @ObservedObject private var settings = DesignSettings.shared
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandMenu("Design") {
            Toggle("Standard Window with Sidebar", isOn: $settings.standardWindow)
            Toggle("Standard Window Title Bar", isOn: $settings.standardTitleBar)
                .disabled(!settings.standardWindow)
            Toggle("Standard Window Sidebar Icons", isOn: $settings.standardSidebarIcons)
                .disabled(!settings.standardWindow)
            Toggle("Standard Window Glass Background", isOn: $settings.standardGlassBackground)
                .disabled(!settings.standardWindow)
            Picker("Widget Corners", selection: $settings.tileRadius) {
                ForEach(CornerRadii.choices, id: \.self) { Text("\(Int($0)) pt" + ($0 == CornerRadii.defaultTile ? " (default)" : "")).tag($0) }
            }
            Picker("Window Corners", selection: $settings.windowRadius) {
                ForEach(CornerRadii.choices, id: \.self) { Text("\(Int($0)) pt" + ($0 == CornerRadii.defaultWindow ? " (default)" : "")).tag($0) }
            }
            Divider()
            Button("Color Lab…") { openWindow(id: ColorLabView.windowID) }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Toggle("Liquid Glass Tiles", isOn: $settings.glass)
                .keyboardShortcut("g", modifiers: [.command, .option])
            Toggle("Glass Chart Elements", isOn: $settings.glassElements)
            Toggle("Clip Window Corners", isOn: $settings.clipWindow)
            Toggle("Track Pointer", isOn: $settings.trackPointer)
            Toggle("Window Glass", isOn: $settings.windowGlass)
            Toggle("Window Background", isOn: $settings.windowBackground)
            Picker("Background Appearance", selection: $settings.backgroundAppearance) {
                ForEach(BackgroundAppearance.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Page Edge Fade", isOn: $settings.pageEdgeFade)
            Toggle("Clear Tile Glass", isOn: $settings.clearTileGlass)
            Toggle("Quick Lift", isOn: $settings.quickLift)
            Divider()
            Toggle("Tile Lift", isOn: $settings.lift)
            Toggle("Tile Tilt", isOn: $settings.tilt)
            Toggle("Hover Shade", isOn: $settings.hoverShade)
            Toggle("Window Shadow", isOn: $settings.windowShadow)
            Toggle("Window Border", isOn: $settings.windowBorder)
            Divider()
            Picker("Palette", selection: $settings.scheme) {
                ForEach(Array(PaletteScheme.allCases.enumerated()), id: \.element) { index, scheme in
                    // ⌥⌘1…9; the rest are picked from the menu.
                    Text(scheme.title)
                        .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option]) : nil)
                        .tag(scheme)
                }
            }
            .pickerStyle(.inline)
        }
    }
}

