import Foundation
import Security
import LocalAuthentication
import CryptoKit

public enum MetadataPurpose: String, Sendable { case inventory, recovery }
public protocol MetadataKeyStore: Sendable {
    func read(_ account: String) throws -> Data?
    func create(_ account: String, value: Data) throws
    func replace(_ account: String, value: Data) throws
    func delete(_ account: String) throws
}
public struct MetadataUnavailable: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { String(localized: "Protected metadata is unavailable.") }
}
/// All Security operations use the same explicit no-interaction policy.
public struct SilentMetadataKeyStore: MetadataKeyStore {
    public typealias Call = @Sendable (String, [String: Any], [String: Any]?) -> (OSStatus, Data?)
    private let accessGroup: @Sendable () throws -> String
    private let call: Call
    public init(accessGroup: @escaping @Sendable () throws -> String = Self.signedAccessGroup,
                call: @escaping Call = Self.securityCall) { self.accessGroup = accessGroup; self.call = call }
    public static func signedAccessGroup() throws -> String {
        guard MetadataSession.shared.available else { throw MetadataUnavailable() }
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              ["com.macspace.app", "com.macspace.cli"].contains(identifier),
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let groups = entitlements["keychain-access-groups"] as? [String],
              let group = groups.first(where: { $0.hasSuffix(".com.macspace.metadata") }),
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String, group == team + ".com.macspace.metadata" else { throw MetadataUnavailable() }
        return group
    }
    public static func securityCall(_ operation: String, _ query: [String: Any], _ values: [String: Any]?) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        switch operation {
        case "read": let status = SecItemCopyMatching(query as CFDictionary, &result); return (status, result as? Data)
        case "create": return (SecItemAdd(query as CFDictionary, nil), nil)
        case "replace": return (SecItemUpdate(query as CFDictionary, (values ?? [:]) as CFDictionary), nil)
        case "delete": return (SecItemDelete(query as CFDictionary), nil)
        default: return (errSecParam, nil)
        }
    }
    private func query(_ account: String) throws -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.macspace.metadata.v1",
                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: try accessGroup(),
                kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false,
                kSecUseAuthenticationContext as String: context]
    }
    public func read(_ account: String) throws -> Data? {
        var query = try query(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, value) = call("read", query, nil)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let value else { throw MetadataUnavailable() }; return value
    }
    public func create(_ account: String, value: Data) throws {
        var query = try query(account); query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard call("create", query, nil).0 == errSecSuccess else { throw MetadataUnavailable() }
    }
    public func replace(_ account: String, value: Data) throws {
        guard call("replace", try query(account), [kSecValueData as String: value]).0 == errSecSuccess else { throw MetadataUnavailable() }
    }
    public func delete(_ account: String) throws {
        let status = call("delete", try query(account), nil).0
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MetadataUnavailable() }
    }
}

public enum MetadataKeys {
    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var store: any MetadataKeyStore = SilentMetadataKeyStore()
    /// Dependency injection for isolated fixture hosts; never selected from environment or on-disk configuration.
    public static func useStore(_ value: any MetadataKeyStore) { lock.withLock { store = value } }
    public static func requireAvailable() throws {
        try lock.withLock {
            if store is SilentMetadataKeyStore, !MetadataSession.shared.allowsProtectedWork { throw MetadataUnavailable() }
        }
    }
    public static func key(_ purpose: MetadataPurpose, create: Bool) throws -> Data {
        try lock.withLock {
            let account = "key." + purpose.rawValue + "." + String(getuid())
            if let key = try store.read(account) { guard key.count == 32 else { throw MetadataUnavailable() }; return key }
            guard create else { throw MetadataUnavailable() }
            var key = Data(count: 32)
            guard key.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { throw MetadataUnavailable() }
            do { try store.create(account, value: key) }
            catch { if let existing = try store.read(account), existing.count == 32 { return existing }; throw error }
            return key
        }
    }
    public static func checkpoint(_ name: String) throws -> Data? { try lock.withLock { try store.read("checkpoint." + String(getuid()) + "." + name) } }
    public static func checkpoint(_ name: String, value: Data) throws {
        try lock.withLock {
            let account = "checkpoint." + String(getuid()) + "." + name
            if try store.read(account) == nil { try store.create(account, value: value) } else { try store.replace(account, value: value) }
        }
    }
}

public enum EncryptedMetadata {
    public static func seal(_ data: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32 else { throw MetadataUnavailable() }
        return try AES.GCM.seal(data, using: SymmetricKey(data: key), authenticating: Data(context.utf8)).combined!
    }
    public static func open(_ data: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32 else { throw MetadataUnavailable() }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key), authenticating: Data(context.utf8))
    }
}
