import Foundation
import CryptoKit

/// Builds the single "MACSPACE policies" configuration profile from managed-preference settings.
///
/// There is one profile with a fixed identifier: installing a new version replaces the old one, so applying or
/// reverting a control regenerates the profile from every control still applied. Payload UUIDs are derived
/// from their identifiers, so the same content always produces the same profile.
public enum ConfigurationProfileBuilder {
    public static let identifier = "com.macspace.policies"
    public static let displayName = "MACSPACE policies"
    public static let fileName = "MACSPACE-policies.mobileconfig"

    public static func build(_ settings: [ManagedPreferenceSetting]) throws -> Data {
        var byType: [String: [String: Any]] = [:]
        for setting in settings { byType[setting.payloadType, default: [:]][setting.key] = setting.desired.propertyListObject }

        let payloads: [[String: Any]] = byType.keys.sorted().map { type in
            let identifier = "\(Self.identifier).\(type)"
            var payload: [String: Any] = [
                "PayloadType": type,
                "PayloadIdentifier": identifier,
                "PayloadUUID": uuid(identifier),
                "PayloadVersion": 1,
            ]
            payload.merge(byType[type]!) { current, _ in current }
            return payload
        }
        let profile: [String: Any] = [
            "PayloadDisplayName": displayName,
            "PayloadDescription": "Privacy policies chosen in MACSPACE: \(settings.map { "\($0.payloadType) \($0.key)" }.sorted().joined(separator: ", ")). Remove this profile to undo them.",
            "PayloadIdentifier": identifier,
            "PayloadOrganization": "MACSPACE",
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
