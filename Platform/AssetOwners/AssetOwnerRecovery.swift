import Darwin
import Foundation

/// Old plaintext rollback files are evidence, never input to native replay. Fresh operations use a separate authenticated file.
/// Existing authenticated .plist records retain their original checkpoint/purpose, including after an interrupted upgrade.
struct AssetOwnerRecovery {
    struct Location {
        var url: URL
        var purpose: String
        var preservesLegacy: Bool
    }
    private struct Legacy: Decodable {
        struct Entry: Decodable { var phase: String }
        var version: Int
        var scope: String
        var uid: UInt32
        var entries: [Entry]
    }
    let directory: URL
    init(directory: URL = AssetModelCleanup.journal(.siri).deletingLastPathComponent()) { self.directory = directory }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 || errno != ENOENT
    }
    func legacyURL(_ scope: AssetModelCleanup.Scope) -> URL { directory.appendingPathComponent(scope.rawValue + ".plist") }
    func sealedURL(_ scope: AssetModelCleanup.Scope) -> URL { directory.appendingPathComponent(scope.rawValue + "-v2.sealed") }
    func hasSavedOwners(_ scope: AssetModelCleanup.Scope) -> Bool {
        Self.exists(legacyURL(scope)) || Self.exists(sealedURL(scope))
    }
    private func hasCheckpoint(_ purpose: String) throws -> Bool {
        try MetadataKeys.checkpoint("recovery.v2." + purpose) != nil
    }
    func location(_ scope: AssetModelCleanup.Scope) throws -> Location {
        let oldPurpose = "owners." + scope.rawValue, newPurpose = "owners.sealed." + scope.rawValue
        let oldCheckpoint = try hasCheckpoint(oldPurpose)
        let data = try PrivateFile(legacyURL(scope), createDirectories: true).readMigratingLegacyPermissions(maximum: 16 * 1024 * 1024)
        var legacy = false
        // Only decode the header and phases. In particular, never decode a legacy native request archive.
        if let data, let header = try? PropertyListDecoder().decode(Legacy.self, from: data), header.version == 1 {
            guard !oldCheckpoint else { throw MetadataUnavailable() }
            try AssetOwners.require(header.scope == scope.rawValue && header.uid == getuid() && header.entries.count <= 512,
                                    "The older model recovery file does not match this account or feature. It was preserved.")
            try AssetOwners.require(header.entries.allSatisfy { ["prepared", "removed", "restored"].contains($0.phase) },
                                    "An older model request was interrupted. Its recovery file was preserved; cleanup cannot safely resume.")
            legacy = true
        }
        let oldState = oldCheckpoint || (data != nil && !legacy)
        let newState = try Self.exists(sealedURL(scope)) || hasCheckpoint(newPurpose)
        try AssetOwners.require(!(oldState && newState), "Conflicting model recovery records were preserved. Cleanup cannot safely resume.")
        return Location(url: oldState ? legacyURL(scope) : sealedURL(scope),
                        purpose: oldState ? oldPurpose : newPurpose, preservesLegacy: legacy)
    }
    /// Plaintext legacy evidence must not prevent first use of protected storage. Any modern file or checkpoint does prevent
    /// replacing a lost key, including another feature's records and the temporary-owner journal.
    func canCreateKey() throws -> Bool {
        let temporary = directory.appendingPathComponent("temporary-v2.sealed")
        if try Self.exists(temporary) || hasCheckpoint("temporary-owners") { return false }
        for scope in [AssetModelCleanup.Scope.siri, .phone, .released] {
            let selected = try location(scope)
            if try Self.exists(selected.url) || hasCheckpoint(selected.purpose) { return false }
        }
        return true
    }
    func open(_ scope: AssetModelCleanup.Scope) throws -> (ProtectedJournal, Location) {
        let selected = try location(scope)
        return (try ProtectedJournal(url: selected.url, purpose: selected.purpose, allowKeyCreation: canCreateKey()), selected)
    }
}
