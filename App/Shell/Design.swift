import AppKit
import MacSpaceSdk
import SwiftUI

/// The color schemes the tiles and pages can be drawn in. Temporary: they are here to compare looks, switched from the Design menu
/// or from Settings. Every scheme keeps the same roles: one ground per tile color, steps for marks, and one action color.
public enum PaletteScheme: String, CaseIterable, Identifiable, Sendable {
    // Every palette is a night and day pair. Day and night of a pair share their hues; the night ramp runs dark to light, the day ramp
    // light to dark, so a mark keeps its place in both. Day palettes are drawn for the system's white window (Window Glass off): the
    // grounds are toned enough to stand off it, and every text and mark is checked for contrast on what it sits on.
    case deep
    case paper
    case mono
    case monoDay
    case sketch
    case sketchDay
    case nord
    case nordDay
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
        case .paper: return "Deep, day (Paper)"
        case .monoDay: return "Mono, day"
        case .sketchDay: return "Sketch, day"
        case .nordDay: return "Nord, day"
        case .auroraNight: return "Aurora, night"
        case .auroraDay: return "Aurora, day"
        case .terraNight: return "Terra, night"
        case .terraDay: return "Terra, day"
        case .inkNight: return "Ink, night"
        case .inkDay: return "Ink, day"
        }
    }

    /// The themes Settings offers: each pair once, by its night palette.
    public static let themes: [PaletteScheme] = [.deep, .mono, .sketch, .nord, .auroraNight, .terraNight, .inkNight]

    /// The pair's name, for the theme picker.
    public var themeTitle: String {
        switch night {
        case .deep: return "Deep"
        case .mono: return "Mono"
        case .sketch: return "Sketch"
        case .nord: return "Nord"
        case .auroraNight: return "Aurora"
        case .terraNight: return "Terra"
        default: return "Ink"
        }
    }

    /// The night and day palettes of this one's pair.
    public var night: PaletteScheme {
        switch self {
        case .paper: return .deep
        case .monoDay: return .mono
        case .sketchDay: return .sketch
        case .nordDay: return .nord
        case .auroraDay: return .auroraNight
        case .terraDay: return .terraNight
        case .inkDay: return .inkNight
        default: return self
        }
    }

    public var day: PaletteScheme {
        switch night {
        case .deep: return .paper
        case .mono: return .monoDay
        case .sketch: return .sketchDay
        case .nord: return .nordDay
        case .auroraNight: return .auroraDay
        case .terraNight: return .terraDay
        default: return .inkDay
        }
    }

    /// Light grounds take dark text.
    var isLight: Bool {
        switch self {
        case .paper, .monoDay, .sketchDay, .nordDay, .auroraDay, .terraDay, .inkDay: return true
        default: return false
        }
    }

    var action: (fill: Color, light: Color, deep: Color) {
        switch self {
        case .sketch: return (Color(hex: 0xF5B800), Color(hex: 0xFFD54D), Color(hex: 0x3D2C00))
        case .nord: return (Color(hex: 0xEBCB8B), Color(hex: 0xF3DDB0), Color(hex: 0x3B3220))
        // By day the lighter form is darker (hover) and the fill a deeper amber, so it holds on the
        // toned grounds.
        case .paper, .monoDay: return (Color(hex: 0xE08300), Color(hex: 0xC46F00), Color(hex: 0x3D2200))
        case .sketchDay: return (Color(hex: 0xE0A800), Color(hex: 0xC28F00), Color(hex: 0x3A2A00))
        case .nordDay: return (Color(hex: 0xD9A93F), Color(hex: 0xBC8C28), Color(hex: 0x38290A))
        case .auroraDay: return (Color(hex: 0xE58A12), Color(hex: 0xC97200), Color(hex: 0x3F2300))
        case .auroraNight: return (Color(hex: 0xEF9F27), Color(hex: 0xFAC775), Color(hex: 0x412402))
        case .terraNight: return (Color(hex: 0xF2B134), Color(hex: 0xF8CF7A), Color(hex: 0x3D2800))
        case .terraDay: return (Color(hex: 0xD98A00), Color(hex: 0xBA7200), Color(hex: 0x3A2200))
        case .inkNight: return (Color(hex: 0xC6F135), Color(hex: 0xDDF98A), Color(hex: 0x26300A))
        // Light and deep lime read on a light tile, where the night's pale lime would vanish.
        case .inkDay: return (Color(hex: 0x8DBB00), Color(hex: 0x739A00), Color(hex: 0x1E2900))
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
        case (.deep, .rose): return make(0x451023, [0x57142C, 0x711C3C, 0x9F3259, 0xD4537E, 0xEC99AF, 0xF6C0CD], 0xFCEDF1)
        // Deep by day (Paper): toned grounds of the same hues, dark text; the teal tile is a leaf green by day, not mint.
        case (.paper, .violet): return make(0xD3D4F7, [0xBDBDED, 0xA7A6E7, 0x8D89DE, 0x7D76D6, 0x5144A5, 0x3D337D], 0x120D30)
        case (.paper, .blue): return make(0xC1DAF7, [0xA3C6ED, 0x82B2E7, 0x5999DE, 0x3A88D6, 0x03589D, 0x024278], 0x00142C)
        case (.paper, .teal): return make(0xC4E1C1, [0xA7CFA3, 0x87BF83, 0x60AA5B, 0x429B3E, 0x026A04, 0x015002], 0x001A00)
        case (.paper, .graphite): return make(0xD8D7D5, [0xC3C2BF, 0xAFAEA9, 0x969590, 0x86857E, 0x585750, 0x42413C], 0x141411)
        case (.paper, .slate): return make(0xD4D8DC, [0xBDC3C9, 0xA7AFB7, 0x8D96A1, 0x7B8692, 0x4D5864, 0x3A424B], 0x101418)
        case (.paper, .rose): return make(0xF7CAD4, [0xEDAFBE, 0xE592A8, 0xD86E8E, 0xCE547C, 0x9A194E, 0x75143B], 0x2C0111)
        // Mono: graphite everywhere, a hair warmer or cooler per module, so only amber stands out.
        case (.mono, .violet): return make(0x24232A, [0x302F37, 0x3D3C45, 0x55545F, 0x82808C, 0xB0AEB8, 0xD6D4DC], 0xF2F1F5)
        case (.mono, .blue): return make(0x20242A, [0x2B3038, 0x383E47, 0x515862, 0x7E8691, 0xADB4BD, 0xD4D9DF], 0xF0F3F6)
        case (.mono, .teal): return make(0x212624, [0x2C322F, 0x39403C, 0x525A55, 0x7F8882, 0xAEB6B1, 0xD5DBD7], 0xF0F4F2)
        case (.mono, .graphite): return make(0x262524, [0x32302F, 0x3F3D3B, 0x585553, 0x85827F, 0xB3B0AC, 0xD8D6D2], 0xF4F2EF)
        case (.mono, .slate): return make(0x1C1C1E, [0x28282B, 0x353539, 0x4E4E53, 0x7C7C82, 0xACACB1, 0xD5D5D9], 0xF2F2F4)
        case (.mono, .rose): return make(0x2A2527, [0x332F31, 0x433F40, 0x615B5E, 0x878083, 0xB5B1B3, 0xD2CFD0], 0xF2F1F2)
        // Mono by day: light greys, a hair warmer or cooler per module.
        case (.monoDay, .violet): return make(0xD7D6DD, [0xC2C2C7, 0xAEADB5, 0x95949E, 0x85838E, 0x575560, 0x414048], 0x141317)
        case (.monoDay, .blue): return make(0xD3D8DE, [0xBFC3C8, 0xA9AEB6, 0x8F969F, 0x7E8590, 0x505761, 0x3C4249], 0x111418)
        case (.monoDay, .teal): return make(0xD4D9D6, [0xBFC4C1, 0xAAB0AC, 0x909792, 0x7F8781, 0x515954, 0x3C433F], 0x121513)
        case (.monoDay, .graphite): return make(0xD9D7D5, [0xC4C2C1, 0xAFADAB, 0x979592, 0x878481, 0x595653, 0x43413E], 0x151413)
        case (.monoDay, .slate): return make(0xD7D7DA, [0xC2C2C5, 0xADADB1, 0x95959A, 0x84848A, 0x56565C, 0x414145], 0x141416)
        case (.monoDay, .rose): return make(0xDAD6D8, [0xC5C1C3, 0xB1ACAE, 0x999396, 0x898285, 0x5B5557, 0x443F42], 0x151314)
        // Sketch: the hues of the first sketches (magenta, cyan, coral) as deep grounds.
        case (.sketch, .violet): return make(0x3A0B52, [0x4A0F69, 0x5E1385, 0x8A1FBF, 0xB620E0, 0xD77AF2, 0xEDC2FA], 0xFAEFFE)
        case (.sketch, .blue): return make(0x062F4A, [0x0A3D60, 0x0F4F7C, 0x1673AD, 0x33A6E0, 0x7FCDF5, 0xC4EAFC], 0xEEF9FE)
        case (.sketch, .teal): return make(0x4A1B0C, [0x5C2412, 0x712B13, 0x993C1D, 0xD85A30, 0xF0997B, 0xF8CDBD], 0xFDF1EC)
        case (.sketch, .graphite): return make(0x2A1F4D, [0x352862, 0x433279, 0x5C46A8, 0x8A6FE0, 0xB8A6F2, 0xDDD3FA], 0xF4F0FE)
        case (.sketch, .slate): return make(0x3A3A3A, [0x464646, 0x535353, 0x6E6E6E, 0x969696, 0xBEBEBE, 0xE0E0E0], 0xF7F7F7)
        case (.sketch, .rose): return make(0x00300C, [0x014013, 0x01581E, 0x048632, 0x3DBE5A, 0x90D699, 0xBAE4BD], 0xEAF5EB)
        // Sketch by day: the same magenta, cyan and coral on pale grounds.
        case (.sketchDay, .violet): return make(0xEFC7FD, [0xE2AAF6, 0xD78AF3, 0xC95FEC, 0xBE3AE6, 0x8401A5, 0x65017E], 0x23002E)
        case (.sketchDay, .blue): return make(0xBEDDF0, [0x9EC9E4, 0x7AB6DB, 0x4A9FCE, 0x1D8FC5, 0x035E85, 0x004766], 0x001623)
        case (.sketchDay, .teal): return make(0xF8CCBE, [0xEEB29F, 0xE7967D, 0xDB7453, 0xD25B34, 0x972D00, 0x732101], 0x290600)
        case (.sketchDay, .graphite): return make(0xD7D2F8, [0xC3BAEF, 0xAFA2EA, 0x9784E1, 0x886FDA, 0x5C3CA9, 0x452D80], 0x160A31)
        case (.sketchDay, .slate): return make(0xD7D7D7, [0xC2C2C2, 0xAEAEAE, 0x959595, 0x848484, 0x575757, 0x414141], 0x141414)
        case (.sketchDay, .rose): return make(0xBFE2C2, [0xA0D1A5, 0x7CC185, 0x4CAD5E, 0x1D9F41, 0x016925, 0x01501A], 0x001A05)
        // Nord: polar night grounds, frost and aurora marks.
        case (.nord, .violet): return make(0x332E40, [0x3D374D, 0x48405B, 0x5E5476, 0x8D7BA3, 0xB48EAD, 0xD8C5D5], 0xECEFF4)
        case (.nord, .blue): return make(0x2E3440, [0x3B4252, 0x434C5E, 0x4C566A, 0x5E81AC, 0x81A1C1, 0xB7CBE0], 0xECEFF4)
        case (.nord, .teal): return make(0x2B3634, [0x33403E, 0x3C4B48, 0x4F6460, 0x6F9893, 0x8FBCBB, 0xC3DEDD], 0xECEFF4)
        case (.nord, .graphite): return make(0x3B4252, [0x434C5E, 0x4C566A, 0x616E88, 0x8792A8, 0xD8DEE9, 0xE5E9F0], 0xECEFF4)
        case (.nord, .slate): return make(0x2E3440, [0x3B4252, 0x434C5E, 0x4C566A, 0x7B88A1, 0xA9B4C6, 0xD8DEE9], 0xECEFF4)
        case (.nord, .rose): return make(0x3F181D, [0x4F1F24, 0x662A31, 0x8F4149, 0xBF616A, 0xDD9FA2, 0xEDC5C6], 0xFAEFEF)
        // Nord by day: snow storm grounds, deepened to hold on white; frost and aurora marks.
        case (.nordDay, .violet): return make(0xDCD3E7, [0xC7BED2, 0xB3A8C2, 0x9C8EAF, 0x8D7CA2, 0x5F4E73, 0x473A57], 0x17101E)
        case (.nordDay, .blue): return make(0xC8D9EF, [0xB4C4D9, 0x9AB0CC, 0x7A98BC, 0x6687B0, 0x375881, 0x294261], 0x081423)
        case (.nordDay, .teal): return make(0xC9DCD9, [0xB5C7C4, 0x9BB4B1, 0x7C9D99, 0x678D89, 0x385F5B, 0x2A4744], 0x081715)
        case (.nordDay, .graphite): return make(0xD2D8E2, [0xBDC3CD, 0xA7AEBC, 0x8C95A8, 0x7B8599, 0x4D576B, 0x3A4150], 0x10141B)
        case (.nordDay, .slate): return make(0xD1D8E4, [0xBCC3CF, 0xA6AEBF, 0x8B96AA, 0x79859D, 0x4B576E, 0x384153], 0x10141C)
        case (.nordDay, .rose): return make(0xF9CACC, [0xE4B5B7, 0xD99B9E, 0xCB7B81, 0xBF666E, 0x8D3440, 0x6B2730], 0x27070C)
        // Aurora: a hue per module (violet, blue, teal, rose, slate).
        case (.auroraNight, .violet): return make(0x2E2870, [0x464090, 0x5E57B0, 0x766ED0, 0x8E86F0, 0xAEA8F5, 0xCECBF9], 0xEEEDFE)
        case (.auroraNight, .blue): return make(0x0A3A6B, [0x1A528B, 0x2A6AAA, 0x3A83CA, 0x4A9BEA, 0x7EB8F0, 0xB2D4F5], 0xE6F1FB)
        case (.auroraNight, .teal): return make(0x0A4036, [0x125D4A, 0x1A7A5E, 0x239772, 0x2BB486, 0x68CAA9, 0xA4DFCB], 0xE1F5EE)
        case (.auroraNight, .graphite): return make(0x5A1B33, [0x7C2E4A, 0x9D4061, 0xBE5378, 0xE0668F, 0xE992AF, 0xF2BED0], 0xFBEAF0)
        case (.auroraNight, .slate): return make(0x2D353E, [0x46505B, 0x5E6A78, 0x768595, 0x8FA0B2, 0xAFBBC9, 0xCED7DF], 0xEEF2F6)
        case (.auroraNight, .rose): return make(0x381442, [0x491A55, 0x622770, 0x8E43A1, 0xC46BDB, 0xDCA5EA, 0xE9C6F2], 0xF7EEFA)
        case (.auroraDay, .violet): return make(0xD3D4F7, [0xBDBDEE, 0xA7A6E8, 0x8E89DF, 0x7D75D8, 0x5143A7, 0x3D337E], 0x120C31)
        case (.auroraDay, .blue): return make(0xC2DAF5, [0xA4C6EB, 0x83B2E4, 0x5A9ADA, 0x3C88D2, 0x00589B, 0x024276], 0x00142B)
        case (.auroraDay, .teal): return make(0xC4E1C1, [0xA7CFA3, 0x87BF83, 0x60AA5B, 0x429B3E, 0x026A04, 0x015002], 0x001A00)
        case (.auroraDay, .graphite): return make(0xF5CAD5, [0xEAB0C0, 0xE294AA, 0xD57190, 0xCA587F, 0x972151, 0x72193D], 0x2B0212)
        case (.auroraDay, .slate): return make(0xD2D8DE, [0xBCC3CC, 0xA5AFBB, 0x8997A6, 0x778797, 0x495869, 0x37424F], 0x0F141A)
        case (.auroraDay, .rose): return make(0xE9CCF0, [0xDAB2E4, 0xCD97DB, 0xBC75CF, 0xB05CC5, 0x7F2595, 0x601D70], 0x22032A)
        // Terra: earthy hues (plum, petrol, moss, umber, slate).
        case (.terraNight, .violet): return make(0x47213D, [0x653256, 0x84446E, 0xA25686, 0xC0679F, 0xD393BB, 0xE5BED8], 0xF8EAF4)
        case (.terraNight, .blue): return make(0x0F3F4D, [0x1A5868, 0x247184, 0x2F8AA0, 0x3AA3BB, 0x72BECF, 0xABD8E2], 0xE3F3F6)
        case (.terraNight, .teal): return make(0x26402A, [0x3A5C36, 0x4E7743, 0x629250, 0x76AE5C, 0x9DC589, 0xC4DCB5], 0xEBF3E2)
        case (.terraNight, .graphite): return make(0x3A3027, [0x56493D, 0x716253, 0x8C7C69, 0xA8957F, 0xC1B3A1, 0xDAD0C4], 0xF3EEE6)
        case (.terraNight, .slate): return make(0x2D353E, [0x46505B, 0x5E6A78, 0x768595, 0x8FA0B2, 0xAFBBC9, 0xCED7DF], 0xEEF2F6)
        case (.terraNight, .rose): return make(0x3D1B12, [0x4C2217, 0x622E1F, 0x8A4633, 0xB8664F, 0xD9A292, 0xEAC7BD], 0xF9EFED)
        case (.terraDay, .violet): return make(0xEDCDDF, [0xDFB4CD, 0xD399BC, 0xC37AA7, 0xB86498, 0x86326A, 0x65264F], 0x25061B)
        case (.terraDay, .blue): return make(0xC1DDE5, [0xA2CAD5, 0x80B8C7, 0x54A2B5, 0x2F93A9, 0x036173, 0x024957], 0x00171D)
        case (.terraDay, .teal): return make(0xCCDEC4, [0xB2CCA7, 0x97BA88, 0x77A463, 0x619549, 0x31660F, 0x254D0C], 0x061900)
        case (.terraDay, .graphite): return make(0xDDD6CF, [0xCAC1B7, 0xB8AC9E, 0xA29281, 0x93816D, 0x64533F, 0x4C3E2F], 0x19130B)
        case (.terraDay, .slate): return make(0xD2D8DE, [0xBCC3CC, 0xA5AFBB, 0x8997A6, 0x778797, 0x495869, 0x37424F], 0x0F141A)
        case (.terraDay, .rose): return make(0xEED0C7, [0xE1B8AC, 0xD59F90, 0xC6816D, 0xBB6C56, 0x893C26, 0x682D1C], 0x260A04)
        // Ink: quiet neutral grounds, a light grey by day; the color is in the marks.
        case (.inkNight, .violet): return make(0x2A2838, [0x48436A, 0x665E9C, 0x8579CD, 0xA394FF, 0xBDB3FD, 0xD8D2FA], 0xF2F1F8)
        case (.inkNight, .blue): return make(0x232C38, [0x2E4A6A, 0x38689C, 0x4285CD, 0x4DA3FF, 0x83BEFD, 0xBAD9FB], 0xF0F4F9)
        case (.inkNight, .teal): return make(0x212E29, [0x285848, 0x2F8267, 0x36AC86, 0x3DD6A5, 0x78E1BF, 0xB4EBD9], 0xEFF6F3)
        case (.inkNight, .graphite): return make(0x33232A, [0x663546, 0x994762, 0xCC597E, 0xFF6B9A, 0xFD97B8, 0xFBC4D5], 0xF9F0F3)
        case (.inkNight, .slate): return make(0x2A2C31, [0x464A52, 0x626973, 0x7E8894, 0x9AA6B5, 0xB7BFCA, 0xD4D9DF], 0xF1F2F4)
        case (.inkNight, .rose): return make(0x31231B, [0x562500, 0x783601, 0xB85706, 0xFF8A3D, 0xFFB68C, 0xFDCEB4], 0xFCEFE8)
        case (.inkDay, .violet): return make(0xD6D6E5, [0xC0BCED, 0xABA4E7, 0x9287DD, 0x8273D6, 0x5642A5, 0x41317C], 0x140C30)
        case (.inkDay, .blue): return make(0xCDD9E6, [0xA2C6F0, 0x80B2EB, 0x5599E3, 0x3587DC, 0x01579F, 0x00417A], 0x00142C)
        case (.inkDay, .teal): return make(0xCCDCD5, [0x9AD1BA, 0x73C0A2, 0x38AC85, 0x049C74, 0x02674B, 0x024D38], 0x001910)
        case (.inkDay, .graphite): return make(0xE7D1D6, [0xF1ACBD, 0xEA8EA7, 0xDF688C, 0xD54C7A, 0xA0024D, 0x7A0439], 0x2D0010)
        case (.inkDay, .slate): return make(0xD6D8DA, [0xBDC3CA, 0xA7AFB8, 0x8D96A2, 0x7B8693, 0x4D5865, 0x3A424C], 0x101419)
        case (.inkDay, .rose): return make(0xE5D4CA, [0xEBB597, 0xE39B71, 0xD7793F, 0xCD6209, 0x893E01, 0x682E01], 0x240C00)
        }
    }
}

/// Whether the theme is drawn by night or by day: as the system's appearance, or always one of them.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case night
    case day

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "Follow System"
        case .night: return "Night"
        case .day: return "Day"
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
    /// With the fade: the content scrolls on under the title and the main action, blurred by a band of Liquid Glass that fades out
    /// toward the page, instead of fading away.
    var pageEdgeBlur = false
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

    func palette(_ tint: TileTint) -> TintPalette { scheme.palette(tint).applying(lab, tint: tint, light: isLight) }
    var action: Color { lab.color(.action) ?? scheme.action.fill }
    /// Worked out from the studio's action color when it has one, unless set apart.
    var actionLight: Color { lab.color(.actionLight) ?? lab.colors[ColorRole.action.key].map { PaletteRamp.action($0, light: isLight).light } ?? scheme.action.light }
    var actionDeep: Color { lab.color(.actionDeep) ?? lab.colors[ColorRole.action.key].map { PaletteRamp.action($0, light: isLight).deep } ?? scheme.action.deep }
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
    /// The Shader Studio's shading for a part of the app; tile grounds default to their faint light from the top left, the rest to none.
    func shading(_ target: FillTarget) -> ShadingSpec? {
        if let shading = lab.shading(target) { return shading }
        switch target {
        case .tiles, .tile: return .classic(light: isLight)
        default: return nil
        }
    }
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
    /// The theme (a night and day pair) and whether it is drawn by night, by day or as the system is: together they choose `scheme`.
    @Published public var appearanceMode: AppearanceMode {
        didSet { defaults.set(appearanceMode.rawValue, forKey: "design.appearanceMode"); followAppearance() }
    }
    public var theme: PaletteScheme {
        get { scheme.night }
        set { scheme = resolved(newValue) }
    }
    @Published public var backgroundAppearance: BackgroundAppearance { didSet { defaults.set(backgroundAppearance.rawValue, forKey: "design.backgroundAppearance") } }
    /// The system's appearance is dark; kept up to date while the app runs, for `.system` backgrounds.
    @Published private(set) var systemIsDark = DesignSettings.readSystemIsDark() { didSet { followAppearance() } }
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
    @Published public var pageEdgeBlur: Bool { didSet { defaults.set(pageEdgeBlur, forKey: "design.pageEdgeBlur") } }
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
    /// The Shader Studio is picking what to edit by a click in the window, and what it edits. Not kept.
    @Published var studioPicking = false
    @Published var studioTarget: FillTarget = .tiles
    @Published var colorLab: [String: LabOverrides] {
        didSet { if let data = try? JSONEncoder().encode(colorLab) { defaults.set(data, forKey: "design.colorLab") } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let scheme = PaletteScheme(rawValue: defaults.string(forKey: "design.palette") ?? "") ?? .deep
        self.scheme = scheme
        // Until one is chosen, the palette picked before there was a choice keeps its night or day.
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "design.appearanceMode") ?? "") ?? (scheme.isLight ? .day : .night)
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
        pageEdgeBlur = defaults.bool(forKey: "design.pageEdgeBlur")
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
        followAppearance()
    }

    /// The theme's night or day palette, as the appearance mode asks.
    private func resolved(_ theme: PaletteScheme) -> PaletteScheme {
        switch appearanceMode {
        case .system: return systemIsDark ? theme.night : theme.day
        case .night: return theme.night
        case .day: return theme.day
        }
    }

    private func followAppearance() {
        let wanted = resolved(scheme)
        if scheme != wanted { scheme = wanted }
    }

    var design: Design { Design(scheme: scheme, backgroundAppearance: backgroundAppearance, systemIsDark: systemIsDark, glass: glass, lift: lift, tilt: tilt, hoverShade: hoverShade, glassElements: glassElements,
                                  clipWindow: clipWindow, trackPointer: trackPointer,
                                  windowGlass: windowGlass, windowBackground: windowBackground, pageEdgeFade: pageEdgeFade,
                                  pageEdgeBlur: pageEdgeBlur, clearTileGlass: clearTileGlass, quickLift: quickLift, lab: colorLab[scheme.rawValue] ?? LabOverrides(),
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

/// The Design menu and the Shader Studio are for working on the look, not for users: they are there only when MacSpace is opened
/// with `--design-tools` (`open -a MacSpace --args --design-tools`), or with `MACSPACE_DESIGN=1` in its environment.
public enum DesignTools {
    public static let isEnabled = ProcessInfo.processInfo.arguments.contains("--design-tools")
        || ProcessInfo.processInfo.environment["MACSPACE_DESIGN"] == "1"
}

/// The temporary Design menu: Liquid Glass on or off (⌥⌘G), the palettes (⌥⌘1…9), and switches for what answers the pointer.
public struct DesignCommands: Commands {
    @ObservedObject private var settings = DesignSettings.shared
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        if DesignTools.isEnabled { menu }
    }

    private var menu: some Commands {
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
            Button("Shader Studio…") { openWindow(id: ColorLabView.windowID) }
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
            Toggle("Page Edge Glass Blur", isOn: $settings.pageEdgeBlur)
                .disabled(!settings.pageEdgeFade)
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

