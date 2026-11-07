import Foundation
import CryptoKit

/// Durable payload with Keychain-held provenance/checkpoint, including interrupted writes.
/// A valid older ciphertext cannot independently authorize native replay.
public final class ProtectedJournal {
    private struct Checkpoint: Codable { var current: Data?; var pending: Data? }
    private let file: PrivateFile
    private let name: String
    private let key: Data
    public init(url: URL, purpose: String, allowKeyCreation: Bool) throws {
        file = try PrivateFile(url, createDirectories: true)
        name = "recovery.v2." + purpose
        key = try MetadataKeys.key(.recovery, create: allowKeyCreation)
    }
    private var context: String { name + ":" + String(getuid()) }
    public func read() throws -> Data? {
        guard try MetadataKeys.key(.recovery, create: false) == key else { throw MetadataUnavailable() }
        let checkpoint = try MetadataKeys.checkpoint(name).map { try JSONDecoder().decode(Checkpoint.self, from: $0) }
        guard let encrypted = try file.read(maximum: 16 * 1024 * 1024) else {
            guard checkpoint?.current == nil, checkpoint?.pending == nil else { throw MetadataUnavailable() }
            return nil
        }
        let digest = Data(SHA256.hash(data: encrypted))
        guard let checkpoint, checkpoint.current == digest || checkpoint.pending == digest else { throw MetadataUnavailable() }
        let data = try EncryptedMetadata.open(encrypted, key: key, context: context)
        if checkpoint.pending != nil {
            try MetadataKeys.checkpoint(name, value: JSONEncoder().encode(Checkpoint(current: digest, pending: nil)))
        }
        return data
    }
    public func write(_ data: Data) throws {
        guard data.count <= 16 * 1024 * 1024 - 64 else { throw MetadataUnavailable() }
        _ = try read()
        let encrypted = try EncryptedMetadata.seal(data, key: key, context: context)
        let digest = Data(SHA256.hash(data: encrypted))
        let previous = try MetadataKeys.checkpoint(name).map { try JSONDecoder().decode(Checkpoint.self, from: $0) }
        try MetadataKeys.checkpoint(name, value: JSONEncoder().encode(Checkpoint(current: previous?.current, pending: digest)))
        try file.write(encrypted)
        try MetadataKeys.checkpoint(name, value: JSONEncoder().encode(Checkpoint(current: digest, pending: nil)))
    }
}
