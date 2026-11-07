import AppKit
import Foundation
import MacSpaceSdk

/// Everything the user chooses in Settings: which modules are on, each module's options and background tasks.
/// Values live in `UserDefaults`; manifest defaults apply until the user changes something.
public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Store explicit true and false decisions. Temporarily missing rows retain their preferences.
    public func cleanupChoices(module id: String) -> [String: Bool] {
        defaults.dictionary(forKey: Self.key(id, "cleanupChoices")) as? [String: Bool] ?? [:]
    }
    public func saveCleanupChoices(module id: String, scope: String, visible: Set<String>, selected: Set<String>) {
        var choices = cleanupChoices(module: id)
        for target in visible { choices[CleanupTarget.preferenceKey(scope: scope, id: target)] = selected.contains(target) }
        defaults.set(choices, forKey: Self.key(id, "cleanupChoices"))
    }

    // MARK: Modules

    public func isEnabled(module id: String) -> Bool {
        defaults.object(forKey: Self.key(id, "enabled")) as? Bool ?? true
    }

    public func setEnabled(_ enabled: Bool, module id: String) {
        defaults.set(enabled, forKey: Self.key(id, "enabled"))
    }

    // MARK: Last tile

    /// The tile a module showed last time, so the dashboard has something true to show while the module reads the Mac again. Its
    /// words are in the language it was shown in: after the language changes it is not shown (one saved before languages were kept
    /// counts as English).
    public func lastTile(module id: String, language: String = SettingsStore.language) -> Tile? {
        guard (defaults.string(forKey: Self.key(id, "lastTileLanguage")) ?? "en") == language else { return nil }
        guard let data = defaults.data(forKey: Self.key(id, "lastTile")), data.count <= 1_048_576 else { return nil }
        return try? JSONDecoder().decode(CachedTile.self, from: data).tile
    }

    public func setLastTile(_ tile: Tile, module id: String, language: String = SettingsStore.language) {
        guard let data = try? JSONEncoder().encode(CachedTile(tile)), data.count <= 1_048_576 else { return }
        defaults.set(data, forKey: Self.key(id, "lastTile"))
        defaults.set(language, forKey: Self.key(id, "lastTileLanguage"))
    }

    /// How long the module last took to be read, the first time (`reload` false) or after Refresh: the page's button fills over
    /// that time while it loads (`ModuleHandle.loading`).
    public func loadDuration(module id: String, reload: Bool) -> TimeInterval? {
        let seconds = defaults.double(forKey: Self.key(id, reload ? "reloadDuration" : "loadDuration"))
        return seconds > 0 ? seconds : nil
    }

    public func setLoadDuration(_ seconds: TimeInterval, module id: String, reload: Bool) {
        defaults.set(seconds, forKey: Self.key(id, reload ? "reloadDuration" : "loadDuration"))
    }

    /// The language the app is shown in.
    public static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    // MARK: Options and background tasks

    public func optionStore(for manifest: ModuleManifest) -> any OptionStore {
        StoredOptions(manifest: manifest, defaults: defaults)
    }

    public func setOption(_ value: OptionValue, _ optionID: String, module id: String) {
        switch value {
        case let .bool(flag): defaults.set(flag, forKey: Self.key(id, "option", optionID))
        case let .string(text): defaults.set(text, forKey: Self.key(id, "option", optionID))
        }
    }

    public func setBackgroundTask(_ enabled: Bool, _ taskID: String, module id: String) {
        defaults.set(enabled, forKey: Self.key(id, "task", taskID))
    }

    /// A choice is offered while it needs no other app or one of its apps is installed (`OptionChoice.apps`).
    public static func isOffered(_ choice: OptionChoice) -> Bool {
        guard let apps = choice.apps, !apps.isEmpty else { return true }
        return apps.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    static func key(_ parts: String...) -> String { (["module"] + parts).joined(separator: ".") }

    struct StoredOptions: OptionStore {
        let manifest: ModuleManifest
        let defaults: UserDefaultsBox

        init(manifest: ModuleManifest, defaults: UserDefaults) {
            self.manifest = manifest
            self.defaults = UserDefaultsBox(defaults)
        }

        func bool(_ id: String) -> Bool {
            if let stored = defaults.value.object(forKey: SettingsStore.key(manifest.id, "option", id)) as? Bool { return stored }
            if case let .toggle(defaultValue)? = manifest.options.first(where: { $0.id == id })?.kind { return defaultValue }
            return false
        }

        func string(_ id: String) -> String {
            let stored = defaults.value.string(forKey: SettingsStore.key(manifest.id, "option", id))
            guard case let .choice(choices, defaultValue)? = manifest.options.first(where: { $0.id == id })?.kind else { return stored ?? "" }
            // A choice whose app was removed since reads as the default (`OptionChoice.apps`).
            if let stored, let choice = choices.first(where: { $0.id == stored }), SettingsStore.isOffered(choice) { return stored }
            return defaultValue
        }

        func isBackgroundTaskEnabled(_ id: String) -> Bool {
            if let task = manifest.backgroundTasks.first(where: { $0.id == id }), task.hidden == true { return task.defaultEnabled }
            if let stored = defaults.value.object(forKey: SettingsStore.key(manifest.id, "task", id)) as? Bool { return stored }
            return manifest.backgroundTasks.first(where: { $0.id == id })?.defaultEnabled ?? false
        }
    }

    /// `UserDefaults` is thread-safe; this only tells the compiler so.
    struct UserDefaultsBox: @unchecked Sendable {
        let value: UserDefaults
        init(_ value: UserDefaults) { self.value = value }
    }
}

/// Only display fields are decoded, including when reading a legacy full Tile object.
private struct CachedTile: Codable {
    var title: String
    var figure: String?
    var status: String
    var needsAttention: Bool?
    var graphic: CachedGraphic?
    var reclaimableBytes: UInt64?
    init(_ tile: Tile) {
        title = tile.title; figure = tile.figure; status = tile.status
        needsAttention = tile.needsAttention; graphic = tile.graphic.map(CachedGraphic.init); reclaimableBytes = tile.reclaimableBytes
    }
    var tile: Tile { Tile(title: title, figure: figure, status: status, needsAttention: needsAttention ?? false,
                          graphic: graphic?.value, reclaimableBytes: reclaimableBytes) }
}

private struct CachedSegment: Codable {
    var id: String; var label: String; var bytes: UInt64; var tone: Tone
    init(_ value: UsageSegment) { id = value.id; label = value.label; bytes = value.bytes; tone = value.tone }
    var value: UsageSegment { UsageSegment(id: id, label: label, bytes: bytes, tone: tone) }
}
private enum CachedGraphic: Codable {
    case blocks([CachedSegment])
    case dots([TileDot])
    case state(on: Bool, alarming: Bool, detail: String, meter: Double?, meterIsActionable: Bool)
    case gauge(value: Double, label: String, sublabel: String)
    init(_ value: TileGraphic) {
        switch value {
        case let .blocks(parts): self = .blocks(parts.map(CachedSegment.init))
        case let .dots(parts): self = .dots(parts)
        case let .state(on, alarming, detail, meter, actionable): self = .state(on: on, alarming: alarming, detail: detail, meter: meter, meterIsActionable: actionable)
        case let .gauge(value, label, sublabel): self = .gauge(value: value, label: label, sublabel: sublabel)
        }
    }
    var value: TileGraphic {
        switch self {
        case let .blocks(parts): return .blocks(parts.map(\.value))
        case let .dots(parts): return .dots(parts)
        case let .state(on, alarming, detail, meter, actionable): return .state(on: on, alarming: alarming, detail: detail, meter: meter, meterIsActionable: actionable)
        case let .gauge(value, label, sublabel): return .gauge(value: value, label: label, sublabel: sublabel)
        }
    }
}
