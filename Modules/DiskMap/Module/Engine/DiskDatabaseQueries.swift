import Foundation
import MacSpaceDiskMapPrivileged

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
                for path in claim.paths where Self.contains(path, below: root) {
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
        index.directories[folder] = node
        for path in node.folders { index.directories[path] = try directory(path) }
        let large = try files()
        for file in large {
            let parent = Self.parent(file.path)
            if index.directories[parent] == nil { index.directories[parent] = try directory(parent) }
            if index.directories[parent]?.files.contains(where: { $0.path == file.path }) == false { index.directories[parent]?.files.append(file) }
        }
        if inventory {
            var appPaths: [String] = [], totals: [String: UInt64] = [:]
            try query("SELECT path,total FROM dirs WHERE substr(path,-4)='.app'") {
                let path = Self.text($0, 0)
                if !path.dropLast(4).contains(".app/") { appPaths.append(path); totals[path] = Self.number($0, 1) }
            }
            try query("SELECT d.path,d.total FROM dirs d WHERE d.path IN (SELECT path FROM ownership)") { totals[Self.text($0, 0)] = Self.number($0, 1) }
            index.appPaths = appPaths; index.measuredOwnershipBytes = totals
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for name in ["Caches", "Containers", "Group Containers", "Application Support", "Saved Application State", "HTTPStorages", "WebKit"] {
                let path = home + "/Library/" + name
                if let node = try directory(path, contents: true) {
                    index.directories[path] = node
                    for path in node.folders { index.directories[path] = try directory(path) }
                }
            }
        }
        // Only evidence relevant to the returned page is read. The complete ownership graph remains in the database.
        var referenced: [UInt32: DiskOwnershipClaim] = [:]
        func ownership(_ path: String) throws -> UInt32? {
            var path = path, found: [UInt32: DiskOwnershipClaim] = [:]
            while Self.contains(path, below: root) {
                try query("SELECT c.id,c.data FROM ownership o JOIN claims c ON c.id=o.claim WHERE o.path=?", [.text(path)]) {
                    let id = UInt32(clamping: Self.number($0, 0))
                    found[id] = try JSONDecoder().decode(DiskOwnershipClaim.self, from: Self.data($0, 1))
                }
                if path == root { break }; path = Self.parent(path)
            }
            guard !found.isEmpty else { return nil }
            for (id, claim) in found { referenced[id] = claim }
            if found.count == 1 { return found.keys.first }
            let claims = Array(found.values), owners = Set(claims.flatMap(\.ownerPaths))
            let confidence: OwnershipConfidence = owners.count > 1 || claims.contains(where: { $0.confidence == .shared }) ? .shared : claims.contains(where: { $0.confidence == .unknown }) ? .unknown : claims.contains(where: { $0.confidence == .inferred }) ? .inferred : .verifiedExclusive
            // Combined references exist only in this page; persisted source claims retain their provenance.
            var id = UInt32.max
            while referenced[id] != nil { id -= 1 }
            referenced[id] = DiskOwnershipClaim(paths: Array(Set(claims.flatMap(\.paths))), ownerPaths: Array(owners), confidence: confidence, source: "combined", reason: "Overlapping evidence; least certain classification preserved.")
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
