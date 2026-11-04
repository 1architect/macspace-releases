import Foundation
import MacSpaceDiskMapPrivileged

/// Receipt manifests are historical, non-exclusive evidence. Cache only those manifests and their source stamps.
/// The adapter checks live receipt stamps before reuse; user-started forced app reviews bypass this seed.
enum DiskReceiptCache {
    private struct Stored: Codable { let version: Int; let receipts: AppReceiptCatalog }
    static func read(_ url: URL) -> AppReceiptCatalog? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
              size.intValue <= 8 * 1024 * 1024,
              let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == 1 else { return nil }
        return stored.receipts
    }
    static func save(_ receipts: AppReceiptCatalog, to url: URL) {
        guard let data = try? JSONEncoder().encode(Stored(version: 1, receipts: receipts)), data.count <= 8 * 1024 * 1024 else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* An unavailable cache never blocks an authoritative read. */ }
    }
}
