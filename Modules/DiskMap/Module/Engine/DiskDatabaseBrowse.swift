import Darwin
import Foundation
import MacSpaceCipher
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceDiskMapPrivileged

extension DiskDatabase {
    func putDetail(_ file: DiskFile, link: String) throws { try put(file, link: link) }
    /// Root category projections must start with the partial personal-file index. The equivalent generic view lets SQLite
    /// start with the root's directory range instead, doing a file lookup for every operating-system/app directory.
    var inventoryScanSource: String {
        guard compact else { return "file_details" }
        return "(SELECT CASE WHEN d.path='/' THEN '/'||e.name ELSE d.path||'/'||e.name END AS path,d.path AS parent,e.bytes,e.logical,e.uid,e.link,e.category,e.modified,e.kind FROM entries e INDEXED BY entries_large CROSS JOIN dirs d ON d.id=e.parent WHERE e.inventory=1)"
    }
    var countedDetails: String {
        if !compact { return "(link='' OR path=(SELECT MIN(path) FROM file_details l WHERE l.link=f.link AND l.link<>''))" }
        return "(link='' OR path=(SELECT CASE WHEN d.path='/' THEN '/'||e.name ELSE d.path||'/'||e.name END FROM entries e JOIN dirs d ON d.id=e.parent WHERE e.link=f.link AND e.link<>'' AND e.inventory=1 ORDER BY e.parent,e.name LIMIT 1))"
    }

    func categorySummaries(folder: String? = nil) throws -> [DiskCategorySummary] {
        var grouped: [DiskCategory: DiskCategorySummary] = [:]
        let folder = folder ?? root
        let prefix = folder == "/" ? "/" : folder + "/"
        let source = folder == root ? inventoryScanSource : "file_details"
        try query("SELECT category,SUM(bytes),COUNT(*) FROM \(source) f WHERE (parent=? OR (parent>=? AND parent<?)) AND (logical>=100000000 OR category='installers') AND \(countedDetails) GROUP BY category", [.text(folder), .text(prefix), .text(String(prefix.dropLast()) + "0")]) {
            if let category = DiskCategory(rawValue: Self.text($0, 0)) { grouped[category] = .init(category: category, bytes: Self.number($0, 1), count: Self.number($0, 2)) }
        }
        return DiskCategory.inventoryCategories.map { grouped[$0] ?? .init(category: $0, bytes: 0, count: 0) }
    }
    func ownershipEvidence(_ path: String) throws -> DiskOwnershipClaim? {
        var branch = path, ancestors: [String] = [], claims: [DiskOwnershipClaim] = []
        while Self.contains(branch, below: root) {
            ancestors.append(branch)
            if branch == root { break }; branch = Self.parent(branch)
        }
        guard !ancestors.isEmpty else { return nil }
        // One indexed query covers every ancestor, rather than opening a separate lookup at each depth for every visible file.
        // Do not deduplicate matching relations: the existing combination rule also sees a claim held at two ancestors twice.
        let placeholders = Array(repeating: "?", count: ancestors.count).joined(separator: ",")
        try query("SELECT c.data FROM ownership o JOIN claims c ON c.id=o.claim WHERE o.path IN (" + placeholders + ")", ancestors.map(Value.text)) {
            claims.append(try JSONDecoder().decode(DiskOwnershipClaim.self, from: Self.data($0, 0)))
        }
        return claims.isEmpty ? nil : DiskOwnership.combined(claims, paths: [path])
    }
    func canRemoveDirectory(_ path: String) throws -> Bool {
        guard Self.contains(path, below: root), try directory(path) != nil, try ownershipEvidence(path) == nil else { return false }
        return try query("SELECT 1 FROM ownership WHERE path>=? AND path<? LIMIT 1", [.text(path + "/"), .text(path + "0")]) == 0
    }
    /// Only duplicate review requests content provenance. Ordinary review retains original identity without a survivor rule.
    func reviewedFile(_ input: DiskFile, duplicateEvidence: Bool = true) throws -> DiskFile {
        var file = input
        if let identity = FileReviewIdentity(file.path), identity.uid == getuid(), identity.size == Int64(clamping: file.logicalBytes) { file.identity = identity }
        guard duplicateEvidence, try query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='duplicates'") > 0 else { return file }
        var digest: Data?, recorded: FileReviewIdentity?
        try query("SELECT digest,identity FROM duplicates WHERE path=?", [.text(file.path)]) {
            digest = Self.data($0, 0); recorded = try? JSONDecoder().decode(FileReviewIdentity.self, from: Self.data($0, 1))
        }
        guard digest != nil, recorded == file.identity, recorded != nil else { return file }
        file.duplicateVerification = try duplicateVerification(file.path, selected: [file.path])
        return file
    }
    func decodeDetail(_ row: OpaquePointer) throws -> DiskFile {
        let file = DiskFile(path: Self.text(row, 0), bytes: Self.number(row, 1), logicalBytes: Self.number(row, 2), ownerUID: Self.uid(row, 3), modifiedAt: msc_sqlite3_column_type(row, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: msc_sqlite3_column_double(row, 4)))
        return try reviewedFile(file, duplicateEvidence: false)
    }
    func preparePersonalInventory(progress: LoadProgressSink? = nil, cancelled: @Sendable () -> Bool = { false }) throws {
        guard var metadata = try state(), metadata.personalInventoryVersion != DiskIndex.personalInventorySchemaVersion else { return }
        var request = DiskBrowseRequest(folder: root, kind: .category, category: .largeFiles); request.includeSmaller = true
        var cursor = "", visited = 0
        try transaction {
            while true {
                if cancelled() { throw CancellationError() }
                try Task.checkCancellation()
                let folders = try reviewFolders(request, after: cursor, limit: 128)
                guard let last = folders.last else { break }
                for folder in folders {
                    guard autoreleasepool(invoking: { inventoryIncludes(folder + "/candidate") }) else { continue }
                    var failure: Error?
                    let complete = autoreleasepool { DirectoryWalk.entries(at: folder, includingModificationDate: true) { name, entry in
                        guard failure == nil else { return }
                        do {
                            if cancelled() { throw CancellationError() }
                            try Task.checkCancellation()
                            guard entry.isRegularFile, !entry.isDataless, entry.allocatedBytes > 0, entry.ownerUID == getuid() else { return }
                            let path = folder == "/" ? "/" + name : folder + "/" + name
                            guard inventoryIncludes(path) else { return }
                            let file = DiskFile(path: path, bytes: entry.allocatedBytes, logicalBytes: entry.logicalBytes, ownerUID: entry.ownerUID, modifiedAt: entry.modifiedAt)
                            var link = ""
                            if entry.linkCount > 1, let identity = FileReviewIdentity(path) { link = "\(identity.device):\(identity.inode)" }
                            try put(file, link: link)
                        } catch { failure = error }
                    } }
                    if let failure { throw failure }
                    if !complete { try query("UPDATE dirs SET readable=0 WHERE path=?", [.text(folder)]) }
                    visited += 1
                }
                cursor = last
                progress?(Double(visited) / Double(visited + 1000))
            }
            metadata.personalInventoryVersion = DiskIndex.personalInventorySchemaVersion
            metadata.revision += 1
            try saveState(metadata)
        }
        progress?(1)
    }

    /// Navigation may read only the requested directory. Recursive review stays within personal roots.
    func reviewFolders(_ request: DiskBrowseRequest, after: String, limit: Int) throws -> [String] {
        if request.kind == .direct || request.kind == .managed {
            guard after.isEmpty, (request.kind == .managed ? DiskManagedLibrary.contains(request.folder, home: home) : inventoryIncludes(request.folder + "/candidate")), try directory(request.folder) != nil else { return [] }
            return [request.folder]
        }
        let scopes: [String]
        if inventoryIncludes(request.folder + "/candidate") { scopes = [request.folder] }
        else {
            let prefix = root == DataVolume.path ? DataVolume.path : ""
            scopes = FileReviewPolicy.personalFolders.map { prefix + home + "/" + $0 }.filter { Self.contains($0, below: request.folder) }.sorted()
        }
        var result: [String] = []
        for folder in scopes where result.count < limit {
            let prefix = folder + "/", end = folder + "0"
            // Outer range constraints force one index seek; OR-only paging sorts the entire subtree per page.
            try query("SELECT path FROM dirs WHERE path>=? AND path<? AND path>? AND (path=? OR path>=?) ORDER BY path LIMIT ?",
                [.text(folder), .text(end), .text(after), .text(folder), .text(prefix), .number(UInt64(limit - result.count))]) {
                result.append(Self.text($0, 0))
            }
        }
        return result
    }
    func canReview(_ request: DiskBrowseRequest) -> Bool {
        if request.kind == .managed { return DiskManagedLibrary.contains(request.folder, home: home) }
        if inventoryIncludes(request.folder + "/candidate") { return true }
        guard request.kind != .direct else { return false }
        let prefix = root == DataVolume.path ? DataVolume.path : ""
        return FileReviewPolicy.personalFolders.contains { Self.contains(prefix + home + "/" + $0, below: request.folder) }
    }
    /// One bounded temporary scope is reused across pages. No small-file rows enter the persistent inventory.
    private func cacheSmaller(_ request: DiskBrowseRequest, progress: LoadProgressSink? = nil) throws {
        var scope = request; scope.afterPath = nil; scope.afterSize = nil; scope.selectionParent = nil; scope.fileType = nil; scope.focusPath = nil
        let revision = try state()?.revision ?? 0
        if smallerScope == scope.pageID, smallerRevision == revision, request.afterPath != nil || Date().timeIntervalSince(smallerAt) < 30 {
            if request.afterPath == nil && smallerWindowStart == nil { return }
            if let after = request.afterPath, !(smallerHasMore && after == smallerWindowEnd), try query("SELECT 1 FROM smaller WHERE path=?", [.text(after)]) > 0 { return }
        }
        try execute("CREATE TEMP TABLE IF NOT EXISTS smaller (path TEXT PRIMARY KEY,parent TEXT NOT NULL,bytes INTEGER,logical INTEGER,uid INTEGER,link TEXT,category TEXT,modified INTEGER,kind TEXT) WITHOUT ROWID; CREATE INDEX IF NOT EXISTS temp.smaller_link ON smaller(link,path) WHERE link<>''; DELETE FROM smaller")
        try execute("CREATE TEMP TABLE IF NOT EXISTS smaller_totals(kind TEXT PRIMARY KEY,count INTEGER,bytes INTEGER) WITHOUT ROWID; DELETE FROM smaller_totals")
        smallerIncomplete = false; smallerHasMore = false; smallerScope = nil
        var rows = 0
        var typeBytes: [String: UInt64] = [:]
        try execute("CREATE TEMP TABLE IF NOT EXISTS smaller_links(link TEXT PRIMARY KEY) WITHOUT ROWID")
        // The first metadata pass keeps only group totals and alias IDs. The second retains one bounded window.
        // No per-file small inventory persists, and aggregate counts never describe just that window.
        for pass in 0..<2 {
            var cursor = ""
            try execute("DELETE FROM smaller_links")
            repeat {
                let folders = try reviewFolders(request, after: cursor, limit: 128)
                guard let last = folders.last else { break }
                for folder in folders {
                    try Task.checkCancellation()
                    guard request.kind == .managed || autoreleasepool(invoking: { inventoryIncludes(folder + "/candidate") }) else { continue }
                    if request.kind == .direct, folder != request.folder { continue }
                    let complete = autoreleasepool { DirectoryWalk.entries(at: folder, includingModificationDate: true) { name, entry in
                      autoreleasepool {
                        if Task.isCancelled { return }
                        let path = folder == "/" ? "/" + name : folder + "/" + name
                        guard entry.isRegularFile, !entry.isDataless, entry.ownerUID == getuid(), entry.allocatedBytes > 0, (request.kind == .managed || inventoryIncludes(path)) else { return }
                        let category = DiskCategory.inventoryCategory(path), kind = DiskFileType.key(path)
                        if let type = request.largeType, type != category.rawValue { return }
                        if let selected = request.category, selected != .largeFiles, selected != category { return }
                        var link = ""
                        if entry.linkCount > 1, let identity = FileReviewIdentity(path) { link = "\(identity.device):\(identity.inode)" }
                        do {
                            if !link.isEmpty {
                                if try query("SELECT 1 FROM smaller_links WHERE link=?", [.text(link)]) > 0 { return }
                                try query("INSERT INTO smaller_links VALUES(?)", [.text(link)])
                            }
                            if pass == 0 {
                                try query("INSERT INTO smaller_totals VALUES(?,1,?) ON CONFLICT(kind) DO UPDATE SET count=count+1,bytes=bytes+excluded.bytes", [.text(kind), .number(entry.allocatedBytes)])
                                return
                            }
                            if let after = request.afterPath, let size = request.afterSize {
                                let oldType = DiskFileType.key(after), rank = typeBytes[kind, default: 0], oldRank = typeBytes[oldType, default: 0]
                                if rank > oldRank || rank == oldRank && (kind < oldType || kind == oldType && (entry.logicalBytes > size || entry.logicalBytes == size && path <= after)) { return }
                            }
                            try query("INSERT OR REPLACE INTO smaller VALUES(?,?,?,?,?,?,?,?,?)", [.text(path), .text(folder), .number(entry.allocatedBytes), .number(entry.logicalBytes), .optional(entry.ownerUID), .text(link), .text(category.rawValue), .date(entry.modifiedAt), .text(kind)])
                            rows += 1
                            if rows >= smallerLimit + 256 {
                                try execute("DELETE FROM smaller WHERE path IN (SELECT path FROM smaller f ORDER BY (SELECT bytes FROM smaller_totals t WHERE t.kind=f.kind) DESC,kind,logical DESC,path LIMIT -1 OFFSET " + String(smallerLimit) + ")")
                                smallerHasMore = true; rows = smallerLimit
                            }
                        } catch { smallerIncomplete = true }
                      }
                    } }
                    try Task.checkCancellation()
                    if !complete { smallerIncomplete = true }
                }
                cursor = last
                progress?(pass == 0 ? 0.25 : 0.75)
            } while true
            if pass == 0 { try query("SELECT kind,bytes FROM smaller_totals") { typeBytes[Self.text($0, 0)] = Self.number($0, 1) } }
        }
        if rows > smallerLimit {
            try execute("DELETE FROM smaller WHERE path IN (SELECT path FROM smaller f ORDER BY (SELECT bytes FROM smaller_totals t WHERE t.kind=f.kind) DESC,kind,logical DESC,path LIMIT -1 OFFSET " + String(smallerLimit) + ")")
            smallerHasMore = true
        }
        progress?(1)
        smallerWindowStart = request.afterPath; smallerWindowEnd = nil
        try query("SELECT path FROM smaller f ORDER BY (SELECT bytes FROM smaller_totals t WHERE t.kind=f.kind),kind DESC,logical,path DESC LIMIT 1") { smallerWindowEnd = Self.text($0, 0) }
        smallerScope = scope.pageID; smallerRevision = revision; smallerAt = Date()
    }
    func browseFilter(_ request: DiskBrowseRequest) -> (String, [Value])? {
        let prefix = request.folder == "/" ? "/" : request.folder + "/"
        var conditions = ["(parent=? OR (parent>=? AND parent<?))", "bytes>0"]
        var values: [Value] = [.text(request.folder), .text(prefix), .text(String(prefix.dropLast()) + "0")]
        if let parent = request.selectionParent {
            guard Self.contains(parent, below: request.folder) else { return nil }
            conditions.append("parent=?"); values.append(.text(parent))
        }
        if request.kind == .direct || request.kind == .managed { conditions += ["parent=?"]; values += [.text(request.folder)] }
        if request.smallerOnly { conditions.append("logical<100000000") }
        if !request.includeSmaller && request.kind != .direct && request.kind != .managed && request.category != .installers && request.largeType != "installers" { conditions += ["logical>=100000000"] }
        if let category = request.category, category != .largeFiles { conditions += ["category=?"]; values += [.text(category.rawValue)] }
        if let type = request.largeType {
            guard DiskCategory.inventoryCategories.contains(where: { $0.rawValue == type }) else { return nil }
            conditions += ["category=?"]; values += [.text(type)]
        }
        if let type = request.fileType { conditions.append("kind=?"); values.append(.text(type)) }
        if request.kind == .duplicates { return nil }
        return (conditions.joined(separator: " AND "), values)
    }
    func browse(_ request: DiskBrowseRequest, progress: LoadProgressSink? = nil) throws -> DiskBrowsePage? {
        guard Self.contains(request.folder, below: root), try directory(request.folder) != nil, let filter = browseFilter(request) else { return nil }
        let small = request.usesMetadataInventory
        if small { try cacheSmaller(request, progress: progress) }
        try execute("BEGIN DEFERRED")
        defer { try? execute("ROLLBACK") }
        let source = small ? "smaller" : request.kind == .category && request.folder == root ? inventoryScanSource : "file_details"
        let counted = small ? "(link='' OR path=(SELECT MIN(path) FROM smaller l WHERE l.link=f.link AND l.link<>''))" : countedDetails
        try execute("CREATE TEMP TABLE IF NOT EXISTS browse_types(kind TEXT PRIMARY KEY,bytes INTEGER,items INTEGER) WITHOUT ROWID; DELETE FROM browse_types")
        if small { try execute("INSERT INTO browse_types SELECT kind,bytes,count FROM smaller_totals") }
        else { try query("INSERT INTO browse_types SELECT kind,SUM(bytes),COUNT(*) FROM \(source) f WHERE " + filter.0 + " AND " + counted + " GROUP BY kind", filter.1) }
        let rank = "COALESCE((SELECT bytes FROM browse_types t WHERE t.kind=f.kind),0)"
        var sql = filter.0 + " AND " + counted, values = filter.1
        if let size = request.afterSize, let path = request.afterPath {
            let type = DiskFileType.key(path)
            var bytes: UInt64 = 0
            try query("SELECT bytes FROM browse_types WHERE kind=?", [.text(type)]) { bytes = Self.number($0, 0) }
            sql += " AND (" + rank + "<? OR (" + rank + "=? AND (kind>? OR (kind=? AND (logical<? OR (logical=? AND path>?))))))"
            values += [.number(bytes), .number(bytes), .text(type), .text(type), .number(size), .number(size), .text(path)]
        }
        var files: [DiskFile] = []
        try query("SELECT path,bytes,logical,uid,modified FROM \(source) f WHERE " + sql + " ORDER BY " + rank + " DESC,kind,logical DESC,path LIMIT 201", values) { files.append(try decodeDetail($0)) }
        let more = files.count > 200 || (small && smallerHasMore && !files.isEmpty)
        if files.count > 200 { files.removeLast() }
        var next: DiskBrowseRequest?
        if more, let last = files.last { next = request; next?.afterSize = last.logicalBytes; next?.afterPath = last.path }
        if let path = request.focusPath, !files.contains(where: { $0.path == path }), Self.contains(path, below: request.folder), inventoryIncludes(path), let identity = FileReviewIdentity(path) {
            var info = stat()
            if lstat(path, &info) == 0 { if files.count >= 200 { files.removeLast() }; files.append(try reviewedFile(.init(path: path, bytes: UInt64(max(0, info.st_blocks)) * 512, logicalBytes: UInt64(max(0, identity.size)), ownerUID: identity.uid, identity: identity), duplicateEvidence: false)) }
        }
        var types: [DiskTypeSummary] = []
        try query("SELECT kind,items,bytes FROM browse_types ORDER BY bytes DESC,kind") { types.append(.init(key: Self.text($0, 0), count: Self.number($0, 1), bytes: Self.number($0, 2))) }
        if small, let type = request.fileType { types = types.filter { $0.key == type } }
        let count = types.reduce(UInt64(0)) { $0 + $1.count }, bytes = types.reduce(UInt64(0)) { $0 + $1.bytes }
        var ownership: [String: DiskOwnershipClaim] = [:]
        for file in files { ownership[file.path] = try ownershipEvidence(file.path) }
        return .init(request: request, files: files, next: next, ownership: ownership, availableTypes: Set(DiskCategory.inventoryCategories.map(\.rawValue)), eligibleCount: count, eligibleBytes: bytes, unavailableReason: small && smallerIncomplete ? "Some folders could not be read. Their files are not included." : nil, types: types, totalsComplete: !small || !smallerIncomplete)
    }
    func selectedFiles(_ ids: Set<String>, folder: String, reviewed: [String: String]? = nil, origins: [String: String] = [:]) throws -> [DiskFile]? {
        guard !ids.isEmpty, Self.contains(folder, below: root) else { return nil }
        var result: [DiskFile] = []
        for id in ids {
            guard id.hasPrefix("file:"), let data = Data(base64Encoded: String(id.dropFirst(5))), let path = String(data: data, encoding: .utf8), Self.contains(path, below: folder), inventoryIncludes(path), let identity = FileReviewIdentity(path), identity.uid == getuid(), try ownershipEvidence(path) == nil else { return nil }
            var info = stat(); guard lstat(path, &info) == 0 else { return nil }
            var file = try reviewedFile(.init(path: path, bytes: UInt64(max(0, info.st_blocks)) * 512, logicalBytes: UInt64(max(0, identity.size)), ownerUID: identity.uid, modifiedAt: Date(timeIntervalSince1970: Double(identity.modifiedSeconds)), identity: identity), duplicateEvidence: false)
            if let reviewed {
                guard let encoded = reviewed[id], let expected = try? JSONDecoder().decode(FileReviewIdentity.self, from: Data(encoded.utf8)), expected == identity else { return nil }
                file.identity = expected
                if let encoded = origins[id] {
                    guard let proof = try? JSONDecoder().decode(DiskDuplicateVerification.self, from: Data(encoded.utf8)), proof.path == path, proof.identity == expected else { return nil }
                    file.duplicateVerification = proof
                }
            }
            result.append(file)
        }
        return result
    }
}
