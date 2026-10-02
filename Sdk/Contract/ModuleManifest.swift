import Foundation

/// Version of the module contract. A module built for another version is shown as incompatible and not loaded.
public enum SdkVersion {
    public static let current = 2
}

/// `Manifest.json` inside a module bundle. The app reads it before running any module code, so the module list, the
/// permission requests and the settings page work for modules that are off or incompatible.
public struct ModuleManifest: Codable, Equatable, Sendable, Identifiable {
    /// Reverse-DNS identifier, e.g. `com.macspace.system-data`.
    public var id: String
    public var name: String
    public var summary: String
    public var version: String
    public var sdkVersion: Int
    /// SF Symbol shown in the sidebar and on the home tile.
    public var symbol: String
    /// Lowest macOS version the module supports, e.g. `27.0`.
    public var minimumMacOS: String?
    /// Position in the sidebar (lower first).
    public var order: Int
    public var permissions: [Permission]
    public var options: [OptionDefinition]
    public var backgroundTasks: [BackgroundTaskDefinition]
    /// How many columns the module's tile takes on the dashboard. Declared here, not in the tile, so the dashboard has its final layout
    /// before any module has answered. Small when absent.
    public var tileSize: Tile.Size?
    /// The deep color of the module's tile and page. The app picks one when absent.
    public var tileTint: TileTint?

    public init(id: String, name: String, summary: String, version: String, sdkVersion: Int = SdkVersion.current,
                symbol: String, minimumMacOS: String? = nil, order: Int = 100, permissions: [Permission] = [],
                options: [OptionDefinition] = [], backgroundTasks: [BackgroundTaskDefinition] = [], tileSize: Tile.Size? = nil,
                tileTint: TileTint? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.version = version
        self.sdkVersion = sdkVersion
        self.symbol = symbol
        self.minimumMacOS = minimumMacOS
        self.order = order
        self.permissions = permissions
        self.options = options
        self.backgroundTasks = backgroundTasks
        self.tileSize = tileSize
        self.tileTint = tileTint
    }
}
