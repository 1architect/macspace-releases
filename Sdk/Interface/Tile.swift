import Foundation

/// A module's tile on the dashboard: a short title and one status line over a small chart. The app draws the chart on the module's
/// own deep color (`ModuleManifest.tileTint`) and keeps one warm color, amber, for what the user can act on. The tile grows into the
/// module's page when the user opens it.
public struct Tile: Codable, Equatable, Sendable {
    /// Declared in the manifest (`tileSize`). The dashboard gives the large tile to the module that can free the most
    /// (`reclaimableBytes`); while none can, to the module that asks for a wide tile.
    public enum Size: String, Codable, Sendable {
        case small
        case wide
    }

    /// Short and lowercase by convention ("system data", "debloat").
    public var title: String
    /// One line: what the module found or what is on ("2 GB can be freed", "3/14 off").
    public var status: String
    /// Something waits for the user (macOS undid a setting, an approval is pending). The app marks the tile.
    public var needsAttention: Bool
    /// The chart behind the caption.
    public var graphic: TileGraphic?
    /// Bytes the module can free right now, if it frees space. The dashboard gives the module with the most the large tile.
    public var reclaimableBytes: UInt64?
    /// What the module frees through macOS's purge, by CacheDelete service. The disk tile's "purgeable" adds these up across modules
    /// (a service two modules free counts once), so it says what the app can purge, not what macOS estimates in general.
    public var purgeableByService: [String: UInt64]
    /// What the tile shows is changing (a download, a removal): the app asks again after this many seconds instead of its usual
    /// minute. nil for the usual pace.
    public var refreshAfter: Double?
    /// What the switch of a `state` chart runs when it is flipped on the dashboard, with `value` "true" or "false", as a switch row on
    /// the page. nil leaves the switch shown but not flippable.
    public var switchAction: Action?

    public init(title: String, status: String, needsAttention: Bool = false, graphic: TileGraphic? = nil, reclaimableBytes: UInt64? = nil,
                purgeableByService: [String: UInt64] = [:], refreshAfter: Double? = nil, switchAction: Action? = nil) {
        self.title = title
        self.status = status
        self.needsAttention = needsAttention
        self.graphic = graphic
        self.reclaimableBytes = reclaimableBytes
        self.purgeableByService = purgeableByService
        self.refreshAfter = refreshAfter
        self.switchAction = switchAction
    }

    private enum CodingKeys: String, CodingKey { case title, status, needsAttention, graphic, reclaimableBytes, purgeableByService, refreshAfter, switchAction }

    /// `purgeableByService` may be missing (a tile saved by an earlier version).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(String.self, forKey: .status)
        needsAttention = try container.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false
        graphic = try container.decodeIfPresent(TileGraphic.self, forKey: .graphic)
        reclaimableBytes = try container.decodeIfPresent(UInt64.self, forKey: .reclaimableBytes)
        purgeableByService = try container.decodeIfPresent([String: UInt64].self, forKey: .purgeableByService) ?? [:]
        refreshAfter = try container.decodeIfPresent(Double.self, forKey: .refreshAfter)
        switchAction = try container.decodeIfPresent(Action.self, forKey: .switchAction)
    }
}

/// The charts a tile can show. Each says one thing exactly; color is the app's, except that the caution tone (and `TileDot.attention`)
/// always means "you can act on this".
public enum TileGraphic: Codable, Equatable, Sendable {
    /// Blocks sized by bytes, largest first (a treemap). A segment with the caution tone is what the user can free.
    case blocks([UsageSegment])
    /// One dot per item, in order.
    case dots([TileDot])
    /// A feature that should stay off: whether it is on, one line of detail, and an optional meter (0...1). `alarming` makes an on
    /// state glow; `meterIsActionable` draws the meter in the action color.
    case state(on: Bool, alarming: Bool, detail: String, meter: Double?, meterIsActionable: Bool)
    /// An arc filled to `value` (0...1), with a big label in the middle. A short tile draws a bar instead, without the labels.
    case gauge(value: Double, label: String, sublabel: String)
}

public enum TileDot: String, Codable, Sendable {
    /// Done (a feature switched off).
    case done
    /// Not done yet (a feature that still runs).
    case open
    /// Needs the user (macOS undid it).
    case attention
}

/// The deep color a module's tile and page are drawn in.
public enum TileTint: String, Codable, Sendable, CaseIterable {
    case violet
    case blue
    case teal
    case graphite
    case slate
}
