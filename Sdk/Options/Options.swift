import Foundation

public struct OptionChoice: Codable, Equatable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public enum OptionKind: Codable, Equatable, Sendable {
    case toggle(defaultValue: Bool)
    case choice(options: [OptionChoice], defaultValue: String)
}

/// A setting a module exposes on its page in Settings. The app stores the value and hands it back through `OptionStore`.
public struct OptionDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String?
    public var kind: OptionKind

    public init(id: String, title: String, detail: String? = nil, kind: OptionKind) {
        self.id = id
        self.title = title
        self.detail = detail
        self.kind = kind
    }
}

/// Work a module wants to do in the background, such as a watcher. The app lists each one as a toggle in Settings and
/// schedules it only while the module is enabled and the toggle is on.
public struct BackgroundTaskDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String?
    public var defaultEnabled: Bool
    /// How often the task runs while enabled.
    public var intervalSeconds: Int

    public init(id: String, title: String, detail: String? = nil, defaultEnabled: Bool = false, intervalSeconds: Int) {
        self.id = id
        self.title = title
        self.detail = detail
        self.defaultEnabled = defaultEnabled
        self.intervalSeconds = intervalSeconds
    }
}

public enum OptionValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case string(String)

    public var boolValue: Bool? { if case let .bool(value) = self { return value } else { return nil } }
    public var stringValue: String? { if case let .string(value) = self { return value } else { return nil } }
}

/// Read access to a module's saved options, with the manifest defaults applied.
public protocol OptionStore: Sendable {
    func bool(_ id: String) -> Bool
    func string(_ id: String) -> String
    func isBackgroundTaskEnabled(_ id: String) -> Bool
}
