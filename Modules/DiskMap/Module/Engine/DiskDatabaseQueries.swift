import Foundation
import Darwin
import MacSpaceDiskMapPrivileged
import MacSpacePlatform

extension DiskDatabase {
    func recordOwnership(_ catalog: DiskApplications) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try transaction {
            let replacing = try query("SELECT 1 FROM ownership LIMIT 1") > 0
            if replacing {
                try execute("CREATE TEMP TABLE IF NOT EXISTS desired_ownership(path TEXT NOT NULL, claim INTEGER NOT NULL, PRIMARY KEY(path,claim)) WITHOUT ROWID; DELETE FROM desired_ownership")
            }
            let target = replacing ? "desired_ownership" : "ownership"
            let batchSize = 128
            var claimValues: [Value] = []
            var pathValues: [Value] = []
            func flushClaims() throws {
                guard !claimValues.isEmpty else { return }
                let slots = Array(repeating: "(?)", count: claimValues.count).joined(separator: ",")
                try query("INSERT OR IGNORE INTO claims(data) VALUES " + slots, claimValues)
                claimValues.removeAll(keepingCapacity: true)
            }
            func flushPaths() throws {
                guard !pathValues.isEmpty else { return }
                try flushClaims()
                let slots = Array(repeating: "(?,?)", count: pathValues.count / 2).joined(separator: ",")
                try query("WITH desired(path,data) AS (VALUES " + slots + ") INSERT OR IGNORE INTO " + target + " SELECT d.path,c.id FROM desired d JOIN claims c ON c.data=d.data", pathValues)
                pathValues.removeAll(keepingCapacity: true)
            }
            for claim in Set(catalog.apps.flatMap(\.ownership)) {
                let data = try encoder.encode(claim)
                claimValues.append(.data(data))
                if claimValues.count == batchSize { try flushClaims() }
                for live in claim.paths {
                    let path = root == DataVolume.path ? DataVolume.path + live : live
                    guard Self.contains(path, below: root) else { continue }
                    pathValues.append(.text(path))
                    pathValues.append(.data(data))
                    if pathValues.count == batchSize * 2 { try flushPaths() }
                }
            }
            try flushClaims()
            try flushPaths()
            // Apply only changed relations and publish them atomically with the referenced claim records.
            if replacing {
                try execute("""
                    DELETE FROM ownership WHERE NOT EXISTS (
                        SELECT 1 FROM desired_ownership d WHERE d.path=ownership.path AND d.claim=ownership.claim
                    );
                    INSERT OR IGNORE INTO ownership SELECT path,claim FROM desired_ownership;
                    DELETE FROM desired_ownership
                    """)
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
        if index.summaryVersion == DiskIndex.summarySchemaVersion || index.storageRevision == 4 {
            index.categories = try categorySummaries(folder: folder)
        }
        index.directories[folder] = node
        try childDirectories(folder) { index.directories[$0.path] = $0 }
        // `contents` includes this directory's direct files. Descendant inventories use bounded lazy queries.
        index.inventoryAuthoritative = inventory
        if inventory {
            var identities = Set<String>()
            var appIdentities: [String: Set<String>] = [:]
            try query("SELECT path,bundle FROM dirs WHERE bundle<>''") {
                let path = Self.text($0, 0), identifier = Self.text($0, 1)
                identities.insert(identifier)
                if let range = path.range(of: ".app/", options: .literal) {
                    appIdentities[DiskApplications.livePath(String(path[..<path.index(before: range.upperBound)])), default: []].insert(identifier)
                }
            }
            index.knownBundleIdentifiers = identities
            index.appBundleIdentifiers = appIdentities
            var appPaths: [String] = [], totals: [String: UInt64] = [:]
            try query("SELECT path,total FROM dirs WHERE substr(path,-4)='.app'") {
                let path = Self.text($0, 0)
                if !path.dropLast(4).contains(".app/") { appPaths.append(path); totals[path] = Self.number($0, 1) }
            }
            try query("SELECT d.path,d.total FROM dirs d WHERE d.path IN (SELECT path FROM ownership)") { totals[Self.text($0, 0)] = Self.number($0, 1) }
            index.appPaths = appPaths; index.measuredOwnershipBytes = totals
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for name in AppDataReviewPolicy.directoryBases {
                let live = home + "/Library/" + name
                let path = root == DataVolume.path ? DataVolume.path + live : live
                if let node = try directory(path, contents: true) {
                    index.directories[path] = node
                    try childDirectories(path) { index.directories[$0.path] = $0 }
                }
            }
        }
        if try query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='duplicates'") > 0 {
            let totals = try duplicateTotals(folder: folder)
            index.duplicateBytes = totals.bytes; index.duplicateCount = totals.count
        }
        if folder == root {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            index.personalFolders = try FileReviewPolicy.personalFolders.compactMap { try countedDirectory(DiskApplications.measuredPath(home + "/" + $0, index: index)) }.filter { $0.bytes > 0 }
        }
        // Empty ownership relations need no ancestor queries for every map child.
        if try query("SELECT 1 FROM ownership LIMIT 1") == 0 {
            index.ownershipClaims = [:]
            return DiskSnapshot(index)
        }
        // Evidence IDs belong to this projection; the source graph stays on disk.
        let paths = Array(index.directories.keys) + index.directories.values.flatMap { $0.files.map(\.path) }
        let evidence = try projectedOwnership(paths)
        var referenced: [UInt32: DiskOwnershipClaim] = [:], identifiers: [DiskOwnershipClaim: UInt32] = [:]
        func ownership(_ path: String) -> UInt32? {
            guard let claim = evidence[Data(path.utf8)] else { return nil }
            if let id = identifiers[claim] { return id }
            let id = UInt32(identifiers.count + 1)
            identifiers[claim] = id; referenced[id] = claim
            return id
        }
        for path in index.directories.keys {
            index.directories[path]?.ownershipID = ownership(path)
            if let files = index.directories[path]?.files, !files.isEmpty {
                index.directories[path]?.files = files.map { file in var file = file; file.ownershipID = ownership(file.path); return file }
            }
        }
        index.ownershipClaims = referenced
        return DiskSnapshot(index)
    }
}
