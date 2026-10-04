import Foundation
import CryptoKit

/// Builds the configuration profiles of the Debloat policies.
///
/// Policies switched off together go in one profile, approved once: macOS keeps a single downloaded profile waiting for approval,
/// and each one opened replaced the one before, so Switch all off left all but the last unapproved. A policy switched off alone has a
/// profile of its own (`com.macspace.policies.<control id>`); several share `com.macspace.policies.set-<hash of their ids>`.
/// Switching one back on removes its profile through the helper, which needs no approval; the others that shared it get a new
/// profile to approve. Every policy waiting for approval is staged again with the next one, so none is left behind.
/// Payload UUIDs are derived from their identifiers, so the same content always produces the same profile.
public enum ConfigurationProfileBuilder {
    /// The single profile of earlier versions, which held every policy. Removed when a policy is switched back on; the policies it
    /// still enforced then get profiles of their own (`DebloatModule`).
    public static let legacyIdentifier = "com.macspace.policies"
    /// What the helper may remove: MacSpace's profiles, and nothing else.
    public static func isMacSpaceProfile(_ identifier: String) -> Bool {
        identifier == legacyIdentifier || identifier.hasPrefix(legacyIdentifier + ".")
    }

    public static func identifier(for controlID: String) -> String { "\(legacyIdentifier).\(controlID)" }
    /// The profile of policies switched off together: the control's own one for a single policy.
    public static func identifier(forSet controlIDs: [String]) -> String {
        let ids = Array(Set(controlIDs)).sorted()
        if ids.count == 1 { return identifier(for: ids[0]) }
        let digest = SHA256.hash(data: Data(ids.joined(separator: ",").utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(legacyIdentifier).set-\(digest.prefix(12))"
    }
    public static func fileName(forIdentifier identifier: String) -> String {
        "MacSpace-\(identifier.hasPrefix(legacyIdentifier + ".") ? String(identifier.dropFirst(legacyIdentifier.count + 1)) : identifier).mobileconfig"
    }
    /// Profiles of controls that now change a plain setting instead (Personalized ads, Advertising identifier, Siri logging), and the
    /// single profile of earlier versions. Left installed, they would keep enforcing what the new controls switch.
    public static let retiredIdentifiers = [legacyIdentifier] + ["ads.personalized-ads-policy", "ads.advertising-identifier-policy",
                                                                   "telemetry.siri-server-logging-policy"].map(identifier(for:))
    public static func displayName(for title: String) -> String { "MacSpace: \(title)" }

    /// The step detail when a profile has to be removed and this process cannot (it needs root): the app asks the helper. It names
    /// the profiles; the app replaces it with the outcome.
    public static let removalMarker = "macspace-remove-profiles:"
    public static func removalNeeded(_ identifiers: [String]) -> String { removalMarker + identifiers.joined(separator: ",") }
    public static func identifiers(inRemovalNeeded detail: String?) -> [String]? {
        guard let detail, detail.hasPrefix(removalMarker) else { return nil }
        return detail.dropFirst(removalMarker.count).split(separator: ",").map(String.init)
    }

    public static func build(_ settings: [ManagedPreferenceSetting], controlID: String, title: String) throws -> Data {
        try build(settings, identifier: identifier(for: controlID), title: title)
    }

    public static func build(_ settings: [ManagedPreferenceSetting], identifier: String, title: String) throws -> Data {
        var byType: [String: [String: Any]] = [:]
        for setting in settings { byType[setting.payloadType, default: [:]][setting.key] = setting.desired.propertyListObject }

        let payloads: [[String: Any]] = byType.keys.sorted().map { type in
            let payloadIdentifier = "\(identifier).\(type)"
            var payload: [String: Any] = [
                "PayloadType": type,
                "PayloadIdentifier": payloadIdentifier,
                "PayloadUUID": uuid(payloadIdentifier),
                "PayloadVersion": 1,
            ]
            payload.merge(byType[type]!) { current, _ in current }
            return payload
        }
        let profile: [String: Any] = [
            "PayloadDisplayName": displayName(for: title),
            "PayloadDescription": "\(title), switched off in MacSpace (\(settings.map { "\($0.payloadType) \($0.key)" }.sorted().joined(separator: ", "))). Switch it back on in MacSpace, or remove this profile, to undo it.",
            "PayloadIdentifier": identifier,
            "PayloadOrganization": "MacSpace",
            "PayloadScope": "System",
            "PayloadRemovalDisallowed": false,
            "PayloadType": "Configuration",
            "PayloadUUID": uuid(identifier),
            "PayloadVersion": 1,
            "PayloadContent": payloads,
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// A stable RFC 4122 version-5-style UUID derived from a name.
    static func uuid(_ name: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
}

extension PlistValue {
    var propertyListObject: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .string(let value): return value
        }
    }

    var cfPropertyList: CFPropertyList {
        switch self {
        case .bool(let value): return NSNumber(value: value)  // the CFBoolean singletons
        case .int(let value): return NSNumber(value: value)
        case .string(let value): return value as NSString
        }
    }
}
