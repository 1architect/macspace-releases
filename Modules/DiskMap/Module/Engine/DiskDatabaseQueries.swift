import Foundation
import Darwin
import MacSpaceDiskMapPrivileged
import MacSpacePlatform

extension DiskDatabase {
    func recordOwnership(_ catalog: DiskApplications) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try transaction {
            try execute("DELETE FROM ownership")
            for claim in Set(catalog.apps.flatMap(\.ownership)) {
                let data = try encoder.encode(claim)
                try query("INSERT OR IGNORE INTO claims(data) VALUES(?)", [.data(data)])
                var id: UInt64 = 0
                try query("SELECT id FROM claims WHERE data=?", [.data(data)]) { id = Self.number($0, 0) }
                for live in claim.paths {
                    let path = root == DataVolume.path ? DataVolume.path + live : live
                    guard Self.contains(path, below: root) else { continue }
                    try query("INSERT OR IGNORE INTO ownership VALUES(?,?)", [.text(path), .number(id)])
                }
            }
            try execute("DELETE FROM claims WHERE id NOT IN (SELECT claim FROM ownership)")
        }
        try checkpoint()
    }
    /// Every result is a small page projection. Inventory inputs are paths/totals, not full application subtrees.
    func snapshot(folder: String? = nil, inventory: Bool = true) throws -> DiskSnapshot {
        try execute("BEGIN DEFERRED")
        defer { try? execute("ROLLBACK") }
        let folder = folder ?? root
        var index = try state() ?? DiskIndex(root: root)
        guard let node = try directory(folder, contents: true) else { return DiskSnapshot(index) }
        if index.summaryVersion == DiskIndex.summarySchemaVersion {
            index.categories = try categorySummaries(folder: folder)
        }
        index.directories[folder] = node
        for path in node.folders { index.directories[path] = try directory(path) }
        // `contents` includes this directory's direct files. Descendant inventories use bounded lazy queries.
        if inventory {
            var identities = Set<String>()
            try query("SELECT DISTINCT bundle FROM dirs WHERE bundle<>''") { identities.insert(Self.text($0, 0)) }
            index.knownBundleIdentifiers = identities
            var appPaths: [String] = [], totals: [String: UInt64] = [:]
            try query("SELECT path,total FROM dirs WHERE substr(path,-4)='.app'") {
                let path = Self.text($0, 0)
                if !path.dropLast(4).contains(".app/") { appPaths.append(path); totals[path] = Self.number($0, 1) }
            }
            try query("SELECT d.path,d.total FROM dirs d WHERE d.path IN (SELECT path FROM ownership)") { totals[Self.text($0, 0)] = Self.number($0, 1) }
            index.appPaths = appPaths; index.measuredOwnershipBytes = totals
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for name in ["Caches", "Containers", "Group Containers", "Application Support", "Saved Application State", "HTTPStorages", "WebKit"] {
                let live = home + "/Library/" + name
                let path = root == DataVolume.path ? DataVolume.path + live : live
                if let node = try directory(path, contents: true) {
                    index.directories[path] = node
                    for path in node.folders { index.directories[path] = try directory(path) }
                }
            }
        }
        if try query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='duplicates'") > 0 {
            let totals = try duplicateTotals(folder: folder)
            index.duplicateBytes = totals.bytes; index.duplicateCount = totals.count
        }
        if folder == root {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            index.personalFolders = try FileReviewPolicy.personalFolders.compactMap { try directory(DiskApplications.measuredPath(home + "/" + $0, index: index)) }.filter { $0.bytes > 0 }
        }
        // Evidence IDs belong to this projection; the source graph stays on disk.
        var referenced: [UInt32: DiskOwnershipClaim] = [:], identifiers: [DiskOwnershipClaim: UInt32] = [:]
        func ownership(_ path: String) throws -> UInt32? {
            guard let claim = try ownershipEvidence(path) else { return nil }
            if let id = identifiers[claim] { return id }
            let id = UInt32(identifiers.count + 1)
            identifiers[claim] = id; referenced[id] = claim
            return id
        }
        for path in index.directories.keys {
            index.directories[path]?.ownershipID = try ownership(path)
            if let files = index.directories[path]?.files, !files.isEmpty {
                index.directories[path]?.files = try files.map { file in var file = file; file.ownershipID = try ownership(file.path); return file }
            }
        }
        index.ownershipClaims = referenced
        return DiskSnapshot(index)
    }
}
