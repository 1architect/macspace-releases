import Foundation
import CryptoKit

/// Builds the configuration profile of one Debloat control.
///
/// Each policy control has a profile of its own (`com.macspace.policies.<control id>`). Switching one off installs its profile, which
/// macOS asks the user to approve once; switching it back on removes that profile through the helper, which needs no approval; the
/// other policies are not touched. One profile for all of them had to be replaced, and approved again, on every change.
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
    /// Profiles of controls that now change a plain setting instead (Personalized ads, Advertising identifier, Siri logging), and the
    /// single profile of earlier versions. Left installed, they would keep enforcing what the new controls switch.
    public static let retiredIdentifiers = [legacyIdentifier] + ["ads.personalized-ads-policy", "ads.advertising-identifier-policy",
                                                                   "telemetry.siri-server-logging-policy"].map(identifier(for:))
    public static func displayName(for title: String) -> String { "MacSpace: \(title)" }
    public static func fileName(for controlID: String) -> String { "MacSpace-\(controlID).mobileconfig" }

    /// The step detail when a profile has to be removed and this process cannot (it needs root): the app asks the helper. It names
    /// the profiles; the app replaces it with the outcome.
    public static let removalMarker = "macspace-remove-profiles:"
    public static func removalNeeded(_ identifiers: [String]) -> String { removalMarker + identifiers.joined(separator: ",") }
    public static func identifiers(inRemovalNeeded detail: String?) -> [String]? {
        guard let detail, detail.hasPrefix(removalMarker) else { return nil }
        return detail.dropFirst(removalMarker.count).split(separator: ",").map(String.init)
    }

    public static func build(_ settings: [ManagedPreferenceSetting], controlID: String, title: String) throws -> Data {
        let identifier = identifier(for: controlID)
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
}
