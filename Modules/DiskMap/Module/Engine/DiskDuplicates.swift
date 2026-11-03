import Darwin
import Foundation
import SQLite3
import MacSpacePlatform

extension DiskDatabase {
    static func digest(_ path: String) throws -> Data { try DiskDuplicateReader().hash(path) }

    func duplicateTable() throws {
        try execute("CREATE TABLE IF NOT EXISTS duplicates (path TEXT PRIMARY KEY,digest BLOB NOT NULL,identity BLOB NOT NULL,device INTEGER,inode INTEGER,UNIQUE(device,inode)) WITHOUT ROWID")
        try execute("CREATE INDEX IF NOT EXISTS duplicate_digest ON duplicates(digest,path)")
        try execute("CREATE TABLE IF NOT EXISTS duplicate_fingerprints (path TEXT PRIMARY KEY,identity BLOB NOT NULL,logical INTEGER NOT NULL,sample BLOB NOT NULL,digest BLOB,bytes INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID")
        var hasBytes = false
        try query("PRAGMA table_info(duplicate_fingerprints)") { if Self.text($0, 1) == "bytes" { hasBytes = true } }
        if !hasBytes { try execute("ALTER TABLE duplicate_fingerprints ADD COLUMN bytes INTEGER NOT NULL DEFAULT 0") }
    }

    func beginDuplicatePass(folder: String, minimumSize: UInt64) throws {
        try duplicateTable()
        try execute("CREATE TEMP TABLE IF NOT EXISTS duplicate_scope (folder TEXT,minimum INTEGER)")
        try execute("DELETE FROM duplicate_scope")
        try query("INSERT INTO duplicate_scope VALUES(?,?)", [.text(folder), .number(minimumSize)])
        try execute("CREATE TEMP TABLE IF NOT EXISTS duplicate_candidates (path TEXT PRIMARY KEY,bytes INTEGER,logical INTEGER,uid INTEGER,identity BLOB,device INTEGER,inode INTEGER,sample BLOB,digest BLOB,failed INTEGER DEFAULT 0,UNIQUE(device,inode)) WITHOUT ROWID")
        try execute("CREATE INDEX IF NOT EXISTS temp.duplicate_candidate_size ON duplicate_candidates(logical,sample,path)")
        // Staging is disposable. Verified results and unchanged fingerprints survive each pass.
        try execute("DELETE FROM duplicate_candidates")
    }

    func duplicateMetadata(after: String) throws -> [DiskFile] {
        var folder = "", minimum: UInt64 = 1
        try query("SELECT folder,minimum FROM duplicate_scope") { folder = Self.text($0, 0); minimum = Self.number($0, 1) }
        let prefix = folder == "/" ? "/" : folder + "/"
        var files: [DiskFile] = []
        try query("SELECT path,bytes,logical,uid FROM file_details f WHERE logical>=? AND bytes>0 AND path>=? AND path<? AND path>? AND EXISTS (SELECT 1 FROM file_details g WHERE g.logical=f.logical AND g.path<>f.path AND g.path>=? AND g.path<?) ORDER BY path LIMIT 128",
                  [.number(minimum), .text(prefix), .text(String(prefix.dropLast()) + "0"), .text(after), .text(prefix), .text(String(prefix.dropLast()) + "0")]) {
            files.append(DiskFile(path: Self.text($0, 0), bytes: Self.number($0, 1), logicalBytes: Self.number($0, 2), ownerUID: Self.uid($0, 3)))
        }
        return files
    }

    private static func encoded(_ identity: FileReviewIdentity) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(identity)
    }

    func stageDuplicate(_ file: DiskFile, identity: FileReviewIdentity) throws {
        guard identity.size > 0, UInt64(identity.size) == file.logicalBytes, try ownershipEvidence(file.path) == nil else { return }
        let encoded = try Self.encoded(identity)
        // Invalidate this changed path immediately, without resetting unrelated results.
        try query("DELETE FROM duplicates WHERE path=? AND identity<>?", [.text(file.path), .data(encoded)])
        try query("DELETE FROM duplicate_fingerprints WHERE path=? AND identity<>?", [.text(file.path), .data(encoded)])
        try query("INSERT INTO duplicate_candidates(path,bytes,logical,uid,identity,device,inode,sample,digest) VALUES(?,?,?,?,?,?,?,(SELECT sample FROM duplicate_fingerprints WHERE path=? AND identity=?),(SELECT digest FROM duplicate_fingerprints WHERE path=? AND identity=?)) ON CONFLICT(device,inode) DO UPDATE SET path=excluded.path,bytes=excluded.bytes,logical=excluded.logical,uid=excluded.uid,identity=excluded.identity,sample=excluded.sample,digest=excluded.digest WHERE excluded.path<duplicate_candidates.path",
                  [.text(file.path), .number(file.bytes), .number(file.logicalBytes), .optional(identity.uid), .data(encoded), .number(UInt64(UInt32(bitPattern: identity.device))), .number(identity.inode), .text(file.path), .data(encoded), .text(file.path), .data(encoded)])
    }

    func duplicateWork(sample: Bool, after: String) throws -> [DiskDuplicateWork] {
        var result: [DiskDuplicateWork] = []
        let match = sample ? "g.logical=c.logical" : "g.logical=c.logical AND g.sample=c.sample AND c.sample IS NOT NULL"
        try query("SELECT path,bytes,logical,uid,identity,sample,digest FROM duplicate_candidates c WHERE failed=0 AND path>? AND EXISTS (SELECT 1 FROM duplicate_candidates g WHERE " + match + " AND g.path<>c.path AND g.failed=0) ORDER BY path LIMIT 32", [.text(after)]) {
            let file = DiskFile(path: Self.text($0, 0), bytes: Self.number($0, 1), logicalBytes: Self.number($0, 2), ownerUID: Self.uid($0, 3))
            result.append(.init(file: file, identity: try JSONDecoder().decode(FileReviewIdentity.self, from: Self.data($0, 4)),
                                sample: sqlite3_column_type($0, 5) == SQLITE_NULL ? nil : Self.data($0, 5),
                                digest: sqlite3_column_type($0, 6) == SQLITE_NULL ? nil : Self.data($0, 6)))
        }
        return result
    }

    func saveDuplicate(_ work: DiskDuplicateWork, sample: Data, digest: Data?) throws {
        let encoded = try Self.encoded(work.identity)
        let values: [Value] = [.text(work.file.path), .data(encoded), .number(work.file.logicalBytes), .data(sample)]
        if let digest {
            try query("INSERT OR REPLACE INTO duplicate_fingerprints VALUES(?,?,?,?,?,?)", values + [.data(digest), .number(work.file.bytes)])
            try query("UPDATE duplicate_candidates SET sample=?,digest=? WHERE path=? AND identity=?", [.data(sample), .data(digest), .text(work.file.path), .data(encoded)])
            try query("INSERT OR REPLACE INTO duplicates VALUES(?,?,?,?,?)", [.text(work.file.path), .data(digest), .data(encoded), .number(UInt64(UInt32(bitPattern: work.identity.device))), .number(work.identity.inode)])
        } else {
            try query("INSERT OR REPLACE INTO duplicate_fingerprints VALUES(?,?,?,?,NULL,?)", values + [.number(work.file.bytes)])
            try query("UPDATE duplicate_candidates SET sample=? WHERE path=? AND identity=?", [.data(sample), .text(work.file.path), .data(encoded)])
        }
    }

    func failDuplicate(_ path: String) throws {
        try query("UPDATE duplicate_candidates SET failed=1 WHERE path=?", [.text(path)])
        try query("DELETE FROM duplicates WHERE path=?", [.text(path)])
        try query("DELETE FROM duplicate_fingerprints WHERE path=?", [.text(path)])
    }

    func finishDuplicatePass() throws {
        var folder = "", minimum: UInt64 = 1
        try query("SELECT folder,minimum FROM duplicate_scope") { folder = Self.text($0, 0); minimum = Self.number($0, 1) }
        let prefix = folder == "/" ? "/" : folder + "/"
        let scope: [Value] = [.text(prefix), .text(String(prefix.dropLast()) + "0"), .number(minimum)]
        // Prune only vanished/ineligible members of this pass. Other scopes retain their cache.
        try query("DELETE FROM duplicates WHERE path>=? AND path<? AND path IN (SELECT path FROM duplicate_fingerprints WHERE logical>=?) AND path NOT IN (SELECT path FROM duplicate_candidates WHERE failed=0)", scope)
        try query("DELETE FROM duplicate_fingerprints WHERE path>=? AND path<? AND logical>=? AND path NOT IN (SELECT path FROM duplicate_candidates WHERE failed=0)", scope)
    }

    /// Cached verified totals, including small copies found in an expanded scope. Live rows revalidate on review.
    func duplicateTotals(folder: String) throws -> (bytes: UInt64, count: UInt64) {
        try duplicateTable()
        let prefix = folder == "/" ? "/" : folder + "/"
        var bytes: UInt64 = 0, count: UInt64 = 0
        try query("SELECT COALESCE(SUM(f.bytes),0),COUNT(*) FROM duplicates d JOIN duplicate_fingerprints f ON f.path=d.path AND f.identity=d.identity WHERE d.path>=? AND d.path<? AND d.path<>(SELECT MIN(path) FROM duplicates k WHERE k.digest=d.digest)", [.text(prefix), .text(String(prefix.dropLast()) + "0")]) {
            bytes = Self.number($0, 0); count = Self.number($0, 1)
        }
        return (bytes, count)
    }

    func duplicatePage(_ request: DiskBrowseRequest) throws -> DiskBrowsePage {
        try duplicateTable()
        let prefix = request.folder == "/" ? "/" : request.folder + "/"
        var groups: [DiskDuplicateGroup] = [], files: [DiskFile] = []
        var rows: [(String, Data, Data)] = []
        try query("SELECT d.path,d.digest,d.identity FROM duplicates d WHERE d.path>? AND d.path>=? AND d.path<? AND d.path<>(SELECT MIN(path) FROM duplicates k WHERE k.digest=d.digest) ORDER BY d.path LIMIT 201", [.text(request.afterPath ?? ""), .text(prefix), .text(String(prefix.dropLast()) + "0")]) {
            rows.append((Self.text($0, 0), Self.data($0, 1), Self.data($0, 2)))
        }
        let more = rows.count > 200
        if more { rows.removeLast() }
        for (path, digest, encoded) in rows {
            guard let identity = try? JSONDecoder().decode(FileReviewIdentity.self, from: encoded),
                  FileReviewIdentity(path) == identity, inventoryIncludes(path), try ownershipEvidence(path) == nil else { continue }
            var keeperPath: String?, keeperIdentity: FileReviewIdentity?
            try query("SELECT path,identity FROM duplicates WHERE digest=? ORDER BY path LIMIT 1", [.data(digest)]) {
                keeperPath = Self.text($0, 0); keeperIdentity = try? JSONDecoder().decode(FileReviewIdentity.self, from: Self.data($0, 1))
            }
            guard let keeperPath, let keeperIdentity, FileReviewIdentity(keeperPath) == keeperIdentity,
                  inventoryIncludes(keeperPath), try ownershipEvidence(keeperPath) == nil else { continue }
            var copyInfo = stat(), keeperInfo = stat()
            guard lstat(path, &copyInfo) == 0, lstat(keeperPath, &keeperInfo) == 0,
                  FileReviewIdentity(copyInfo) == identity, FileReviewIdentity(keeperInfo) == keeperIdentity else { continue }
            var copy = DiskFile(path: path, bytes: UInt64(max(0, copyInfo.st_blocks)) * 512, logicalBytes: UInt64(max(0, identity.size)), ownerUID: identity.uid)
            copy.identity = identity
            copy.duplicateVerification = .init(path: path, identity: identity, keeper: keeperPath, keeperIdentity: keeperIdentity, digest: digest)
            var keeper = DiskFile(path: keeperPath, bytes: UInt64(max(0, keeperInfo.st_blocks)) * 512, logicalBytes: UInt64(max(0, keeperIdentity.size)), ownerUID: keeperIdentity.uid)
            keeper.identity = keeperIdentity
            keeper.retainedDuplicateKeeper = true
            let id = digest.map { String(format: "%02x", $0) }.joined()
            if let offset = groups.firstIndex(where: { $0.id == id }) { groups[offset].copies.append(copy) }
            else { groups.append(.init(id: id, keeper: keeper, copies: [copy])) }
            if let proof = copy.duplicateVerification, let offset = groups.firstIndex(where: { $0.id == id }) { groups[offset].verifications[path] = proof }
            files.append(copy)
        }
        var next: DiskBrowseRequest?
        if more, let last = rows.last { next = request; next?.afterPath = last.0; next?.afterSize = 0 }
        var page = DiskBrowsePage(request: request, files: files, next: next, ownership: [:])
        page.duplicateGroups = groups
        let totals = try duplicateTotals(folder: request.folder)
        page.eligibleCount = totals.count; page.eligibleBytes = totals.bytes
        return page
    }

    func duplicateVerification(_ path: String, selected: Set<String>) throws -> DiskDuplicateVerification? {
        try duplicateTable()
        var expected: Data?, identity: FileReviewIdentity?
        try query("SELECT identity,digest FROM duplicates WHERE path=?", [.text(path)]) {
            identity = try? JSONDecoder().decode(FileReviewIdentity.self, from: Self.data($0, 0)); expected = Self.data($0, 1)
        }
        guard let expected, let identity, try ownershipEvidence(path) == nil else { return nil }
        var keeper: (String, FileReviewIdentity)?
        // Require the displayed keeper, never silently substitute a different surviving copy.
        try query("SELECT path,identity FROM duplicates WHERE digest=? ORDER BY path LIMIT 1", [.data(expected)]) {
            let other = Self.text($0, 0)
            if other != path, !selected.contains(other), let value = try? JSONDecoder().decode(FileReviewIdentity.self, from: Self.data($0, 1)) { keeper = (other, value) }
        }
        guard let keeper, try ownershipEvidence(keeper.0) == nil else { return nil }
        return .init(path: path, identity: identity, keeper: keeper.0, keeperIdentity: keeper.1, digest: expected)
    }
}
