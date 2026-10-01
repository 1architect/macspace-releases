import Foundation
import MacSpaceSiriPrivileged

/// Which services subscribe to each Siri speech-recognition model, read from the UAF subscription database.
/// A model stays installed while any subscription names it, so this — not the Siri or dictation settings — says
/// whether it can be released. The database is world-readable; MACSPACE opens it read-only (`immutable=1`).
public struct SpeechModelSubscriptions: Codable, Equatable, Sendable {
    public struct Subscriber: Codable, Equatable, Hashable, Sendable {
        /// Subscribing client, e.g. `com.apple.siri.embeddedspeech`.
        public let client: String
        /// The subscription belongs to another account (or a system context) on this Mac.
        public let otherAccount: Bool

        public init(client: String, otherAccount: Bool) {
            self.client = client
            self.otherAccount = otherAccount
        }

        public var label: String {
            let name: String
            switch client {
            case "com.apple.siri.embeddedspeech": name = "Siri speech service"
            case "com.apple.SpeechRecognitionCore.brokerd": name = "Speech recognition broker"
            case "com.apple.TelephonyUtilities": name = "Phone call features"
            default: name = client
            }
            return otherAccount ? "\(name) (another account)" : name
        }
    }

    public static let databasePath = UAFSubscriptionDatabase.path

    /// `en_US` and `en-US` name the same language.
    static func normalizeLanguage(_ code: String) -> String { code.replacingOccurrences(of: "_", with: "-") }
    static let assistantPrefix = "assistant."

    /// `pt-BR` → subscribers of `assistant.pt_BR`.
    public var assistantModels: [String: [Subscriber]]
    /// The language Siri keeps a model for besides its own (observed to be the system language).
    public var shadowSiriLocale: String?

    public init(assistantModels: [String: [Subscriber]], shadowSiriLocale: String?) {
        self.assistantModels = assistantModels
        self.shadowSiriLocale = shadowSiriLocale
    }

    public func subscribers(for language: String) -> [Subscriber] {
        assistantModels[Self.normalizeLanguage(language)] ?? []
    }

    /// Rows are `Subscriptions` (`k0` client, `k1` subscription name, `k4` user GUID) and `SystemConfiguration` (`k0`, `k1`).
    public static func parse(subscriptions: [[String: String]], configuration: [[String: String]], currentUser: String?) -> SpeechModelSubscriptions {
        var models: [String: Set<Subscriber>] = [:]
        for row in subscriptions {
            guard let client = row["k0"], let name = row["k1"], name.hasPrefix(assistantPrefix) else { continue }
            let language = Self.normalizeLanguage(String(name.dropFirst(assistantPrefix.count)))
            let other = currentUser.map { row["k4"]?.caseInsensitiveCompare($0) != .orderedSame } ?? false
            models[language, default: []].insert(Subscriber(client: client, otherAccount: other))
        }
        let shadow = configuration.first { $0["k0"] == "ShadowSiriLocale" }?["k1"].map(Self.normalizeLanguage)
        return SpeechModelSubscriptions(
            assistantModels: models.mapValues { $0.sorted { ($0.otherAccount ? 1 : 0, $0.client) < ($1.otherAccount ? 1 : 0, $1.client) } },
            shadowSiriLocale: shadow)
    }

    /// nil when the database is missing or unreadable.
    public static func live(databasePath: String = databasePath) -> SpeechModelSubscriptions? {
        guard let subscriptions = UAFSubscriptionDatabase.query(databasePath, "SELECT k0, k1, k4 FROM Subscriptions WHERE k1 LIKE 'assistant.%';"),
              let configuration = UAFSubscriptionDatabase.query(databasePath, "SELECT k0, k1 FROM SystemConfiguration;")
        else { return nil }
        return parse(subscriptions: subscriptions, configuration: configuration, currentUser: UAFSubscriptionDatabase.userGUID(uid: getuid()))
    }
}
