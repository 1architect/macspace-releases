import Foundation

/// One account's Apple Intelligence subscriptions in the UAF subscription database.
///
/// The Apple Intelligence off-switch (a Siri language that differs from the system language) is per account, but the
/// models are stored once for the whole Mac. Any other account where Apple Intelligence is eligible subscribes to its
/// use cases, and that is enough for macOS to download and keep the models (measured on 26B5091g:
/// `results/system-data-deep-2026-09-30/`).
public struct AppleIntelligenceAccount: Codable, Equatable, Sendable {
    public let guid: String
    /// Short account name; nil when no local account has this GUID any more (a deleted account's subscriptions remain).
    public let name: String?
    public let isCurrentUser: Bool
    /// Apple Intelligence use-case subscriptions, e.g. `com.apple.Settings.AppleIntelligence_isIFPEnabled_true_language_pt`.
    public let useCases: [String]

    public init(guid: String, name: String?, isCurrentUser: Bool, useCases: [String]) {
        self.guid = guid
        self.name = name
        self.isCurrentUser = isCurrentUser
        self.useCases = useCases
    }

    public var enabled: Bool { !useCases.isEmpty }

    public var label: String { name ?? "a deleted account (\(guid.prefix(8)))" }
}

public struct AppleIntelligenceAccountsReport: Codable, Equatable, Sendable {
    public let accounts: [AppleIntelligenceAccount]

    public init(accounts: [AppleIntelligenceAccount]) {
        self.accounts = accounts
    }

    /// Accounts other than the current one where Apple Intelligence is on; they keep the shared models installed.
    public var enabledElsewhere: [AppleIntelligenceAccount] {
        accounts.filter { $0.enabled && !$0.isCurrentUser }
    }

    /// A model-catalog subscription that only exists while Apple Intelligence is on for that account. Accounts with it off
    /// keep a few `_default` subscriptions (safety, handwriting, Siri disablement), which do not match.
    static func isAppleIntelligenceUseCase(_ name: String) -> Bool {
        name.contains("isIFPEnabled_true") || name.hasPrefix("com.apple.Settings.AppleIntelligence")
    }

    /// `subscriptions` are `Subscriptions` rows with `k0 = 'model-catalog'` (`k1` use case, `k4` user GUID);
    /// `names` maps GUIDs to account names.
    public static func parse(subscriptions: [[String: String]], names: [String: String], currentUser: String?) -> AppleIntelligenceAccountsReport {
        var byUser: [String: [String]] = [:]
        for row in subscriptions {
            guard let guid = row["k4"]?.uppercased(), let useCase = row["k1"] else { continue }
            byUser[guid, default: []].append(useCase)
        }
        let names = Dictionary(names.map { ($0.key.uppercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let accounts = byUser.map { guid, useCases in
            AppleIntelligenceAccount(guid: guid, name: names[guid], isCurrentUser: guid == currentUser?.uppercased(),
                                     useCases: useCases.filter(isAppleIntelligenceUseCase).sorted())
        }
        return AppleIntelligenceAccountsReport(accounts: accounts.sorted {
            ($0.isCurrentUser ? 0 : 1, $0.name ?? "~", $0.guid) < ($1.isCurrentUser ? 0 : 1, $1.name ?? "~", $1.guid)
        })
    }

    /// `dscl . -list /Users GeneratedUID` output → GUID: name.
    static func parseAccountNames(_ text: String) -> [String: String] {
        var names: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2 else { continue }
            names[String(fields[1]).uppercased()] = String(fields[0])
        }
        return names
    }

    /// nil when the database cannot be read. `uid` is the user the off-switch was applied for.
    public static func live(uid: uid_t = getuid(), databasePath: String = UAFSubscriptionDatabase.path) -> AppleIntelligenceAccountsReport? {
        guard let rows = UAFSubscriptionDatabase.query(databasePath, "SELECT k1, k4 FROM Subscriptions WHERE k0 = 'model-catalog';") else { return nil }
        return parse(subscriptions: rows, names: accountNames(), currentUser: UAFSubscriptionDatabase.userGUID(uid: uid))
    }

    public static func accountNames() -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "-list", "/Users", "GeneratedUID"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseAccountNames(String(decoding: data, as: UTF8.self))
    }
}
