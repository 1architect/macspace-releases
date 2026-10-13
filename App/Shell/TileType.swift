import AppKit
import SwiftUI

/// Temporary, for the design tools' Widget Type window (Design menu): the tiles' typeface, weights and sizes, and whether a tile's
/// chart has its outer corners concentric with the tile's. Kept in the defaults; `DesignSettings.tileType` carries it into `Design` so
/// a change redraws the dashboard, and `current` is what the text measuring code reads.
struct TileType: Codable, Equatable, Sendable {
    /// A font family installed on the Mac; nil for the system font, pinned to one optical size (`CaptionFont`). SF Pro Display and
    /// SF Pro Text are the system font at their optical sizes, so a Mac without Apple's fonts installed draws them alike.
    var family: String? = "SF Pro Display"
    var titleWeight = TypeWeight.semibold
    var statusWeight = TypeWeight.regular
    /// The status line's size against the title's.
    var statusScale = 1.0
    /// The caption's size on each kind of tile (`CaptionSize.tile`): a small tile, a small tile 180 points high or more, the large
    /// tile, and the large tile 300 points high or more.
    var smallSize = 16.0
    var mediumSize = 16.0
    var largeSize = 18.0
    var largeTallSize = 22.0
    /// The system font's optical size, whatever its point size.
    var opticalSize = 17.0
    /// The tiles' small text: the line naming the block under the pointer, and a switch tile's line about it.
    var smallTextSize = 11.0
    /// A tile's chart has its outer corners concentric with the tile's (`BlocksView.outerRadius`).
    var concentricCorners = false
    /// How a tile's chart and a page's chart lay out their blocks (`ChartStyle`).
    var tileChartStyle = ChartStyle.treemap
    var pageChartStyle = ChartStyle.treemap
    /// The most blocks a tile's chart draws, the orange one included; the rest are drawn as one ("3 smaller"). 0 draws them all.
    var tileBlocks = 10
    /// The room between a tile's blocks: 3 points, as on a page and in 1.0.3.
    var tileGap = 3.0

    static let key = "design.tileType.v2"

    /// What the text is measured and drawn with now. Set by `DesignSettings` when the Widget Type window changes it.
    nonisolated(unsafe) static var current = load()

    /// What the Widget Type window left in the defaults, in a development build; a release always draws the defaults.
    static func load(_ defaults: UserDefaults = .standard) -> TileType {
        #if MACSPACE_DEV
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(TileType.self, from: $0) } ?? TileType()
        #else
        TileType()
        #endif
    }

    /// Keys missing from a saved value (one saved before they existed) keep their defaults.
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = TileType()
        family = container.contains(.family) ? try container.decodeIfPresent(String.self, forKey: .family) : base.family
        titleWeight = try container.decodeIfPresent(TypeWeight.self, forKey: .titleWeight) ?? base.titleWeight
        statusWeight = try container.decodeIfPresent(TypeWeight.self, forKey: .statusWeight) ?? base.statusWeight
        statusScale = try container.decodeIfPresent(Double.self, forKey: .statusScale) ?? base.statusScale
        smallSize = try container.decodeIfPresent(Double.self, forKey: .smallSize) ?? base.smallSize
        mediumSize = try container.decodeIfPresent(Double.self, forKey: .mediumSize) ?? base.mediumSize
        largeSize = try container.decodeIfPresent(Double.self, forKey: .largeSize) ?? base.largeSize
        largeTallSize = try container.decodeIfPresent(Double.self, forKey: .largeTallSize) ?? base.largeTallSize
        opticalSize = try container.decodeIfPresent(Double.self, forKey: .opticalSize) ?? base.opticalSize
        smallTextSize = try container.decodeIfPresent(Double.self, forKey: .smallTextSize) ?? base.smallTextSize
        concentricCorners = try container.decodeIfPresent(Bool.self, forKey: .concentricCorners) ?? base.concentricCorners
        tileChartStyle = try container.decodeIfPresent(ChartStyle.self, forKey: .tileChartStyle) ?? base.tileChartStyle
        pageChartStyle = try container.decodeIfPresent(ChartStyle.self, forKey: .pageChartStyle) ?? base.pageChartStyle
        tileBlocks = try container.decodeIfPresent(Int.self, forKey: .tileBlocks) ?? base.tileBlocks
        tileGap = try container.decodeIfPresent(Double.self, forKey: .tileGap) ?? base.tileGap
    }

    /// The tiles' small text, in SwiftUI.
    var smallText: Font { .system(size: smallTextSize) }
}

enum TypeWeight: String, Codable, CaseIterable, Identifiable, Sendable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black

    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var weight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }

    /// The same weight on `NSFontManager`'s scale of 0 to 15, for a family other than the system's.
    var managerWeight: Int {
        switch self {
        case .ultraLight: 2
        case .thin: 3
        case .light: 4
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        case .heavy: 10
        case .black: 11
        }
    }
}

/// How a chart lays out its blocks (`Treemap`).
enum ChartStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One row of bars as high as the chart, each as wide as its share: every gap runs top to bottom and lines up.
    case bars
    /// Columns side by side, each column's blocks stacked down it.
    case columns
    /// The squarified treemap: strips turned to the shorter side of the space left, rows and columns mixed.
    case treemap

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars: "Bars"
        case .columns: "Columns"
        case .treemap: "Treemap"
        }
    }
}

/// How one chart draws its blocks: its layout, and the most blocks it draws (nil for all).
struct ChartLook: Equatable, Sendable {
    var style: ChartStyle
    var limit: Int?

    static var tile: ChartLook {
        let type = TileType.current
        return ChartLook(style: type.tileChartStyle, limit: type.tileBlocks > 0 ? type.tileBlocks : nil)
    }

    static var page: ChartLook { ChartLook(style: TileType.current.pageChartStyle, limit: nil) }
}
