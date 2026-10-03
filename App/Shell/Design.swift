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

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .deep: return "Deep"
        case .mono: return "Mono"
        case .sketch: return "Sketch"
        case .nord: return "Nord"
        case .paper: return "Paper (light)"
        }
    }

    /// Light grounds take dark text.
    var isLight: Bool { self == .paper }

    var action: (fill: Color, light: Color, deep: Color) {
        switch self {
        case .sketch: return (Color(hex: 0xF5B800), Color(hex: 0xFFD54D), Color(hex: 0x3D2C00))
        case .nord: return (Color(hex: 0xEBCB8B), Color(hex: 0xF3DDB0), Color(hex: 0x3B3220))
        case .paper: return (Color(hex: 0xE58A12), Color(hex: 0xF0A848), Color(hex: 0x412402))
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
        }
    }
}

/// How the app is drawn right now: the palette, and whether tiles and their elements are Liquid Glass. Handed down the view tree in
/// the environment, so switching redraws everything at once.
struct Design: Equatable {
    var scheme: PaletteScheme = .deep
    var glass = false
    /// Temporary, for finding what lags on hover: tiles lift, and tilt toward the pointer; glass is shaded under the pointer.
    var lift = true
    var tilt = true
    var hoverShade = true
    /// Temporary, for measuring GPU use: chart elements (blocks, dots, arcs) are glass too, or flat color on the glass tiles.
    var glassElements = true

    func palette(_ tint: TileTint) -> TintPalette { scheme.palette(tint) }
    var action: Color { scheme.action.fill }
    var actionLight: Color { scheme.action.light }
    var actionDeep: Color { scheme.action.deep }
    var isLight: Bool { scheme.isLight }
    /// Text on tiles and pages.
    var ink: Color { isLight ? Color(hex: 0x1C1C1E) : .white }
    /// The color scheme pages and their controls are drawn in.
    var colorScheme: ColorScheme { isLight ? .light : .dark }
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
    @Published public var glass: Bool { didSet { defaults.set(glass, forKey: "design.glass") } }
    @Published public var lift: Bool { didSet { defaults.set(lift, forKey: "design.lift") } }
    @Published public var tilt: Bool { didSet { defaults.set(tilt, forKey: "design.tilt") } }
    @Published public var hoverShade: Bool { didSet { defaults.set(hoverShade, forKey: "design.hoverShade") } }
    @Published public var windowShadow: Bool { didSet { defaults.set(windowShadow, forKey: "design.windowShadow") } }
    @Published public var glassElements: Bool { didSet { defaults.set(glassElements, forKey: "design.glassElements") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scheme = PaletteScheme(rawValue: defaults.string(forKey: "design.palette") ?? "") ?? .deep
        glass = defaults.bool(forKey: "design.glass")
        lift = defaults.object(forKey: "design.lift") as? Bool ?? true
        tilt = defaults.object(forKey: "design.tilt") as? Bool ?? true
        hoverShade = defaults.object(forKey: "design.hoverShade") as? Bool ?? true
        windowShadow = defaults.object(forKey: "design.windowShadow") as? Bool ?? true
        glassElements = defaults.object(forKey: "design.glassElements") as? Bool ?? true
    }

    var design: Design { Design(scheme: scheme, glass: glass, lift: lift, tilt: tilt, hoverShade: hoverShade, glassElements: glassElements) }
}

/// The temporary Design menu: Liquid Glass on or off (⌥⌘G), the palettes (⌥⌘1…5), and switches for what answers the pointer.
public struct DesignCommands: Commands {
    @ObservedObject private var settings = DesignSettings.shared

    public init() {}

    public var body: some Commands {
        CommandMenu("Design") {
            Toggle("Liquid Glass Tiles", isOn: $settings.glass)
                .keyboardShortcut("g", modifiers: [.command, .option])
            Toggle("Glass Chart Elements", isOn: $settings.glassElements)
            Divider()
            Toggle("Tile Lift", isOn: $settings.lift)
            Toggle("Tile Tilt", isOn: $settings.tilt)
            Toggle("Hover Shade", isOn: $settings.hoverShade)
            Toggle("Window Shadow", isOn: $settings.windowShadow)
            Divider()
            Picker("Palette", selection: $settings.scheme) {
                ForEach(Array(PaletteScheme.allCases.enumerated()), id: \.element) { index, scheme in
                    Text(scheme.title).keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option]).tag(scheme)
                }
            }
            .pickerStyle(.inline)
        }
    }
}

/// The same choice inside Settings, as a section.
struct DesignSettingsSection: View {
    @ObservedObject var settings = DesignSettings.shared

    var body: some View {
        Section("Design (temporary)") {
            Toggle("Liquid Glass tiles", isOn: $settings.glass)
                .help("Also in the Design menu: ⌥⌘G.")
            Picker("Palette", selection: $settings.scheme) {
                ForEach(PaletteScheme.allCases) { Text($0.title).tag($0) }
            }
            .help("Also in the Design menu: ⌥⌘1 to ⌥⌘5.")
            Toggle("Tile lift", isOn: $settings.lift)
            Toggle("Tile tilt", isOn: $settings.tilt)
            Toggle("Hover shade", isOn: $settings.hoverShade)
            Toggle("Window shadow", isOn: $settings.windowShadow)
            Toggle("Glass chart elements", isOn: $settings.glassElements)
        }
    }
}
