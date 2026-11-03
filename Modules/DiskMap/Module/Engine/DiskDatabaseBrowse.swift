import Darwin
import Foundation
import SQLite3
import MacSpacePlatform
import MacSpaceDiskMapPrivileged

extension DiskDatabase {
    func putDetail(_ file: DiskFile, link: String) throws { try put(file, link: link) }
    var countedDetails: String {
        if !compact { return "(link='' OR path=(SELECT MIN(path) FROM file_details l WHERE l.link=f.link AND l.link<>''))" }
        return "(link='' OR path=(SELECT CASE WHEN d.path='/' THEN '/'||e.name ELSE d.path||'/'||e.name END FROM entries e JOIN dirs d ON d.id=e.parent WHERE e.link=f.link AND e.link<>'' AND e.inventory=1 ORDER BY e.parent,e.name LIMIT 1))"
    }

    func categorySummaries(folder: String? = nil) throws -> [DiskCategorySummary] {
        var grouped: [DiskCategory: DiskCategorySummary] = [:]
        let folder = folder ?? root
        let prefix = folder == "/" ? "/" : folder + "/"
        try query("SELECT category,SUM(bytes),COUNT(*) FROM file_details f WHERE (parent=? OR (parent>=? AND parent<?)) AND \(countedDetails) GROUP BY category", [.text(folder), .text(prefix), .text(String(prefix.dropLast()) + "0")]) {
            if let category = DiskCategory(rawValue: Self.text($0, 0)) { grouped[category] = .init(category: category, bytes: Self.number($0, 1), count: Self.number($0, 2)) }
        }
        return DiskCategory.inventoryCategories.map { grouped[$0] ?? .init(category: $0, bytes: 0, count: 0) }
    }
    func ownershipEvidence(_ path: String) throws -> DiskOwnershipClaim? {
        var branch = path, claims: [DiskOwnershipClaim] = []
        while Self.contains(branch, below: root) {
            try query("SELECT c.data FROM ownership o JOIN claims c ON c.id=o.claim WHERE o.path=?", [.text(branch)]) {
                claims.append(try JSONDecoder().decode(DiskOwnershipClaim.self, from: Self.data($0, 0)))
            }
            if branch == root { break }; branch = Self.parent(branch)
        }
        return claims.isEmpty ? nil : DiskOwnership.combined(claims, paths: [path])
    }
    /// Carry verified duplicate provenance on every file entry point, including ordinary category pages.
    func reviewedFile(_ input: DiskFile) throws -> DiskFile {
        var file = input
        if let identity = FileReviewIdentity(file.path), identity.uid == getuid(), identity.size == Int64(clamping: file.logicalBytes) { file.identity = identity }
        guard try query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='duplicates'") > 0 else { return file }
        var digest: Data?, recorded: FileReviewIdentity?
        try query("SELECT digest,identity FROM duplicates WHERE path=?", [.text(file.path)]) {
            digest = Self.data($0, 0); recorded = try? JSONDecoder().decode(FileReviewIdentity.self, from: Self.data($0, 1))
        }
        guard let digest, recorded == file.identity, recorded != nil else { return file }
        var keeper = ""
        try query("SELECT MIN(path) FROM duplicates WHERE digest=?", [.data(digest)]) { keeper = Self.text($0, 0) }
        if keeper == file.path { file.retainedDuplicateKeeper = true }
        else { file.duplicateVerification = try duplicateVerification(file.path, selected: []) }
        return file
    }
    func decodeDetail(_ row: OpaquePointer) throws -> DiskFile {
        let file = DiskFile(path: Self.text(row, 0), bytes: Self.number(row, 1), logicalBytes: Self.number(row, 2), ownerUID: Self.uid(row, 3), modifiedAt: sqlite3_column_type(row, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(row, 4)))
        return try reviewedFile(file)
    }
    /// One bounded temporary scope is reused across pages. No small-file rows enter the persistent inventory.
    private func cacheSmaller(_ request: DiskBrowseRequest) throws {
        var scope = request; scope.afterPath = nil; scope.afterSize = nil; scope.selectionParent = nil
        let revision = try state()?.revision ?? 0
        if smallerScope == scope.pageID, smallerRevision == revision, request.afterPath != nil || Date().timeIntervalSince(smallerAt) < 30 {
            if request.afterPath == nil && smallerWindowStart == nil { return }
            if let after = request.afterPath, !(smallerHasMore && after == smallerWindowEnd), try query("SELECT 1 FROM smaller WHERE path=?", [.text(after)]) > 0 { return }
        }
        try execute("CREATE TEMP TABLE IF NOT EXISTS smaller (path TEXT PRIMARY KEY,parent TEXT NOT NULL,bytes INTEGER,logical INTEGER,uid INTEGER,link TEXT,category TEXT,modified INTEGER,kind TEXT) WITHOUT ROWID; CREATE INDEX IF NOT EXISTS temp.smaller_link ON smaller(link,path) WHERE link<>''; DELETE FROM smaller")
        smallerIncomplete = false; smallerHasMore = false; smallerScope = nil
        var cursor = "", rows = 0
        let prefix = request.folder == "/" ? "/" : request.folder + "/"
        repeat {
            var folders: [String] = []
            try query("SELECT path FROM dirs WHERE (path=? OR (path>=? AND path<?)) AND path>? ORDER BY path LIMIT 128", [.text(request.folder), .text(prefix), .text(String(prefix.dropLast()) + "0"), .text(cursor)]) { folders.append(Self.text($0, 0)) }
            guard let last = folders.last else { break }
            for folder in folders {
                try Task.checkCancellation()
                guard inventoryIncludes(folder + "/candidate") else { continue }
                if request.kind == .direct, folder != request.folder { continue }
                let complete = DirectoryWalk.entries(at: folder, includingModificationDate: true) { name, entry in
                    let path = folder == "/" ? "/" + name : folder + "/" + name
                    guard entry.isRegularFile, !entry.isDataless, entry.ownerUID == getuid(), entry.allocatedBytes > 0, inventoryIncludes(path) else { return }
                    let category = DiskCategory.inventoryCategory(path)
                    if let type = request.largeType, type != category.rawValue { return }
                    if let selected = request.category, selected != .largeFiles, selected != category { return }
                    if let after = request.afterPath, let size = request.afterSize {
                        let oldCategory = DiskCategory.inventoryCategory(after).rawValue, oldParent = Self.parent(after)
                        let follows = category.rawValue > oldCategory || (category.rawValue == oldCategory && (folder > oldParent || (folder == oldParent && (entry.logicalBytes < size || (entry.logicalBytes == size && path > after)))))
                        if !follows { return }
                    }
                    // Only aliases need an extra metadata call. The cache cannot count an inode twice.
                    var link = ""
                    if entry.linkCount > 1, let identity = FileReviewIdentity(path) { link = "\(identity.device):\(identity.inode)" }
                    do {
                        try query("INSERT OR REPLACE INTO smaller VALUES(?,?,?,?,?,?,?,?,?)", [.text(path), .text(folder), .number(entry.allocatedBytes), .number(entry.logicalBytes), .optional(entry.ownerUID), .text(link), .text(category.rawValue), .date(entry.modifiedAt), .text("")])
                        rows += 1
                        if rows >= smallerLimit + 256 {
                            try execute("DELETE FROM smaller WHERE path IN (SELECT path FROM smaller ORDER BY category,parent,logical DESC,path LIMIT -1 OFFSET " + String(smallerLimit) + ")")
                            smallerHasMore = true; rows = smallerLimit
                        }
                    } catch { smallerIncomplete = true }
                }
                if !complete { smallerIncomplete = true }
            }
            cursor = last
        } while true
        if rows > smallerLimit {
            try execute("DELETE FROM smaller WHERE path IN (SELECT path FROM smaller ORDER BY category,parent,logical DESC,path LIMIT -1 OFFSET " + String(smallerLimit) + ")")
            smallerHasMore = true
        }
        smallerWindowStart = request.afterPath; smallerWindowEnd = nil
        try query("SELECT path FROM smaller ORDER BY category DESC,parent DESC,logical,path DESC LIMIT 1") { smallerWindowEnd = Self.text($0, 0) }
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
        if request.kind == .direct { conditions += ["parent=?"]; values += [.text(request.folder)] }
        if !request.includeSmaller && request.kind != .direct { conditions += ["logical>=100000000"] }
        if let category = request.category, category != .largeFiles { conditions += ["category=?"]; values += [.text(category.rawValue)] }
        if let type = request.largeType {
            guard DiskCategory.inventoryCategories.contains(where: { $0.rawValue == type }) else { return nil }
            conditions += ["category=?"]; values += [.text(type)]
        }
        if request.kind == .duplicates { return nil }
        return (conditions.joined(separator: " AND "), values)
    }
    func browse(_ request: DiskBrowseRequest) throws -> DiskBrowsePage? {
        guard Self.contains(request.folder, below: root), try directory(request.folder) != nil, let filter = browseFilter(request) else { return nil }
        let small = request.includeSmaller || request.kind == .direct
        if small { try cacheSmaller(request) }
        try execute("BEGIN DEFERRED")
        defer { try? execute("ROLLBACK") }
        let source = small ? "smaller" : "file_details"
        let counted = small ? "(link='' OR path=(SELECT MIN(path) FROM smaller l WHERE l.link=f.link AND l.link<>''))" : countedDetails
        var sql = filter.0 + " AND " + counted, values = filter.1
        if let size = request.afterSize, let path = request.afterPath {
            let category = DiskCategory.inventoryCategory(path).rawValue, parent = Self.parent(path)
            sql += " AND (category>? OR (category=? AND (parent>? OR (parent=? AND (logical<? OR (logical=? AND path>?))))))"
            values += [.text(category), .text(category), .text(parent), .text(parent), .number(size), .number(size), .text(path)]
        }
        var files: [DiskFile] = [], count: UInt64 = 0, bytes: UInt64 = 0
        try query("SELECT path,bytes,logical,uid,modified FROM \(source) f WHERE " + sql + " ORDER BY category,parent,logical DESC,path LIMIT 201", values) { files.append(try decodeDetail($0)) }
        try query("SELECT COUNT(*),COALESCE(SUM(bytes),0) FROM \(source) f WHERE " + filter.0 + " AND " + counted, filter.1) { count = Self.number($0, 0); bytes = Self.number($0, 1) }
        let more = files.count > 200 || (small && smallerHasMore && !files.isEmpty)
        if files.count > 200 { files.removeLast() }
        var next: DiskBrowseRequest?
        if more, let last = files.last { next = request; next?.afterSize = last.logicalBytes; next?.afterPath = last.path }
        var ownership: [String: DiskOwnershipClaim] = [:]
        for file in files { ownership[file.path] = try ownershipEvidence(file.path) }
        return .init(request: request, files: files, next: next, ownership: ownership, availableTypes: Set(DiskCategory.inventoryCategories.map(\.rawValue)), eligibleCount: count, eligibleBytes: bytes, unavailableReason: small && smallerIncomplete ? "Some folders could not be read. Their files are not included." : nil)
    }
    func selectedFiles(_ ids: Set<String>, folder: String, reviewed: [String: String]? = nil, origins: [String: String] = [:]) throws -> [DiskFile]? {
        guard !ids.isEmpty, Self.contains(folder, below: root) else { return nil }
        var result: [DiskFile] = []
        for id in ids {
            guard id.hasPrefix("file:"), let data = Data(base64Encoded: String(id.dropFirst(5))), let path = String(data: data, encoding: .utf8), Self.contains(path, below: folder), inventoryIncludes(path), let identity = FileReviewIdentity(path), identity.uid == getuid(), try ownershipEvidence(path) == nil else { return nil }
            var info = stat(); guard lstat(path, &info) == 0 else { return nil }
            var file = try reviewedFile(.init(path: path, bytes: UInt64(max(0, info.st_blocks)) * 512, logicalBytes: UInt64(max(0, identity.size)), ownerUID: identity.uid, modifiedAt: Date(timeIntervalSince1970: Double(identity.modifiedSeconds)), identity: identity))
            if let reviewed {
                guard let encoded = reviewed[id], let expected = try? JSONDecoder().decode(FileReviewIdentity.self, from: Data(encoded.utf8)), expected == identity else { return nil }
                file.identity = expected
                if let encoded = origins[id] {
                    guard let proof = try? JSONDecoder().decode(DiskDuplicateVerification.self, from: Data(encoded.utf8)), proof.path == path, proof.identity == expected else { return nil }
                    file.duplicateVerification = proof
                } else if file.duplicateVerification != nil { return nil }
            }
            guard !file.retainedDuplicateKeeper else { return nil }
            result.append(file)
        }
        return result
    }
}
