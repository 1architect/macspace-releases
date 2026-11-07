import Foundation
import CryptoKit
import XCTest
import MacSpacePlatform

/// Every Disk fixture uses an injected memory key store, never the developer's Keychain.
class DiskSecurityFixtureCase: XCTestCase {
    private static let keys = FixtureMetadataKeys()
    func trustFixtureCache(_ url: URL) throws {
        let normalized = url.path.hasPrefix("/var/") || url.path.hasPrefix("/tmp/") ? "/private" + url.path : url.path
        let name = "inventory.current." + SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        try MetadataKeys.checkpoint(name, value: Data(url.lastPathComponent.utf8))
        if normalized != url.path {
            let alias = "inventory.current." + SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
            try MetadataKeys.checkpoint(alias, value: Data(url.lastPathComponent.utf8))
        }
    }
    override func setUp() { super.setUp(); MetadataKeys.useStore(Self.keys); _ = try? MetadataKeys.key(.inventory, create: true) }
}
private final class FixtureMetadataKeys: MetadataKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { lock.withLock { values[account] } }
    func create(_ account: String, value: Data) throws { try lock.withLock { guard values[account] == nil else { throw MetadataUnavailable() }; values[account] = value } }
    func replace(_ account: String, value: Data) throws { lock.withLock { values[account] = value } }
    func delete(_ account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}
