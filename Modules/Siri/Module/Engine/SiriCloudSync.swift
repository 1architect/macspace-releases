import Foundation
import MacSpacePlatform

/// Whether Siri's settings sync through iCloud: the "Siri" switch under System Settings > Apple Account > iCloud > Saved to iCloud.
///
/// AssistantServices keeps it as `Cloud Sync Enabled` (`kAFCloudSyncEnabledKey`) in `com.apple.assistant.backedup`, the domain that
/// also holds the Siri language, with `Cloud Sync Enabled Modification Date` beside it, and announces a change with
/// `kAFCloudSyncPreferenceDidChangeDarwinNotification` (all exported by the framework). MacSpace writes it the way it writes the
/// Siri language, through `CFPreferences`, then posts that notification.
///
/// MacSpace changes the Siri language to switch Apple Intelligence off, and with sync on the iPhone and iPad followed (measured
/// 2026-10-04). So, unless the user chose to keep Siri in sync, MacSpace turns sync off before every Siri language change. Not
/// measured yet: that the iPhone then keeps its language (`tested`).
public struct SiriCloudSync {
    public static let domain = AppleIntelligenceLanguageGuard.siriPreferencesDomain
    public static let enabledKey = "Cloud Sync Enabled"
    public static let modificationDateKey = "Cloud Sync Enabled Modification Date"
    public static let changeNotification = DarwinNotificationName.exported(
        framework: "/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices",
        symbol: "kAFCloudSyncPreferenceDidChangeDarwinNotification")
    /// Not yet confirmed on an iPhone that a language changed on the Mac stays on the Mac with sync off.
    public static let tested = false

    /// The user's own choice, once they flipped MacSpace's switch: true keeps Siri in sync even while MacSpace changes the language.
    public static let choiceURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSpace/siri-cloud-sync.json")

    private let choiceURL: URL

    public init(choiceURL: URL = SiriCloudSync.choiceURL) {
        self.choiceURL = choiceURL
    }

    /// Whether sync is on now; nil when the key is missing (Siri never set up on this account).
    public func isEnabled() -> Bool? {
        CFPreferencesAppSynchronize(Self.domain as CFString)
        return (CFPreferencesCopyAppValue(Self.enabledKey as CFString, Self.domain as CFString) as? NSNumber)?.boolValue
    }

    public func set(_ enabled: Bool, now: Date = Date()) throws {
        let domain = Self.domain as CFString
        CFPreferencesSetAppValue(Self.enabledKey as CFString, enabled as CFBoolean, domain)
        CFPreferencesSetAppValue(Self.modificationDateKey as CFString, now as CFDate, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw AppleIntelligenceGuardError.preferenceWriteFailed }
        Self.changeNotification.post()
        guard isEnabled() == enabled else { throw AppleIntelligenceGuardError.preferenceWriteFailed }
    }

    /// What the user chose with MacSpace's switch; nil until they flip it.
    public func userChoice() -> Bool? {
        guard let data = try? Data(contentsOf: choiceURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return nil }
        return object["syncsWithICloud"]
    }

    /// The user flipped the switch: sync is set and the choice kept, so MacSpace no longer turns it off by itself.
    public func choose(_ enabled: Bool) throws {
        try set(enabled)
        try FileManager.default.createDirectory(at: choiceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["syncsWithICloud": enabled]).write(to: choiceURL, options: .atomic)
    }

    /// Before MacSpace changes the Siri language: sync goes off unless the user chose to keep it. Returns true when it was turned off.
    @discardableResult
    public func keepLanguageChangeLocal() -> Bool {
        guard userChoice() != true, isEnabled() == true else { return false }
        return (try? set(false)) != nil
    }

    /// The switch's state as the page shows it: on only while sync is on.
    public var showsOn: Bool { isEnabled() == true }
}
