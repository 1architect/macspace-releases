import Foundation
import MacSpacePlatform
import MacSpaceDiskMapPrivileged

/// Receipt manifests are historical, non-exclusive evidence. Cache only those manifests and their source stamps.
/// The adapter checks live receipt stamps before reuse; user-started forced app reviews bypass this seed.
enum DiskReceiptCache {
    private struct Stored: Codable { let version: Int; let receipts: AppReceiptCatalog }
    private static func context(_ url: URL) -> String { "receipt:v2:" + String(getuid()) + ":" + url.lastPathComponent }
    static func read(_ url: URL) -> AppReceiptCatalog? {
        guard let boundary = try? PrivateFile(url), let encrypted = try? boundary.read(maximum: 8 * 1024 * 1024 + 64),
              let key = try? MetadataKeys.key(.inventory, create: false),
              let data = try? EncryptedMetadata.open(encrypted, key: key, context: context(url)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 2 else { return nil }
        return stored.receipts
    }
    static func save(_ receipts: AppReceiptCatalog, to url: URL) {
        do {
            let key = try MetadataKeys.key(.inventory, create: true)
            let data = try JSONEncoder().encode(Stored(version: 2, receipts: receipts))
            guard data.count <= 8 * 1024 * 1024 else { return }
            try PrivateFile(url, createDirectories: true).write(EncryptedMetadata.seal(data, key: key, context: context(url)))
        } catch { /* Cache unavailability never blocks an authoritative read. */ }
    }
}
