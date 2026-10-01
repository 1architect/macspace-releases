import Foundation
import MacSpaceSdk

/// Everything the user chooses in Settings: which modules are on, each module's options and background tasks.
/// Values live in `UserDefaults`; manifest defaults apply until the user changes something.
public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Modules

    public func isEnabled(module id: String) -> Bool {
        defaults.object(forKey: Self.key(id, "enabled")) as? Bool ?? true
    }

    public func setEnabled(_ enabled: Bool, module id: String) {
        defaults.set(enabled, forKey: Self.key(id, "enabled"))
    }

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
            if let stored = defaults.value.string(forKey: SettingsStore.key(manifest.id, "option", id)) { return stored }
            if case let .choice(_, defaultValue)? = manifest.options.first(where: { $0.id == id })?.kind { return defaultValue }
            return ""
        }

        func isBackgroundTaskEnabled(_ id: String) -> Bool {
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
