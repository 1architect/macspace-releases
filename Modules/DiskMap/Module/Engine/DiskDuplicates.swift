import Darwin
import Foundation
import MacSpaceCipher
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
        duplicateEligibility.reset()
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
        guard identity.size > 0, UInt64(identity.size) == file.logicalBytes, duplicateEligibility.allows(file.path), try ownershipEvidence(file.path) == nil else { return }
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
                                sample: msc_sqlite3_column_type($0, 5) == SQLITE_NULL ? nil : Self.data($0, 5),
                                digest: msc_sqlite3_column_type($0, 6) == SQLITE_NULL ? nil : Self.data($0, 6)))
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

    /// Live metadata is validated into a disk-backed temporary projection, with bounded Swift batches.
    func prepareVerifiedDuplicates(folder: String) throws {
        try duplicateTable()
        duplicateEligibility.reset()
        try execute("CREATE TEMP TABLE IF NOT EXISTS review_duplicates(path TEXT PRIMARY KEY,digest BLOB,identity BLOB,bytes INTEGER) WITHOUT ROWID; DELETE FROM review_duplicates")
        let prefix = folder == "/" ? "/" : folder + "/"
        var after = ""
        while true {
            var rows: [(String, Data, Data, UInt64)] = []
            try query("SELECT d.path,d.digest,d.identity,f.bytes FROM duplicates d JOIN duplicate_fingerprints f ON f.path=d.path AND f.identity=d.identity WHERE d.path>? AND d.path>=? AND d.path<? ORDER BY d.path LIMIT 128", [.text(after), .text(prefix), .text(String(prefix.dropLast()) + "0")]) {
                rows.append((Self.text($0, 0), Self.data($0, 1), Self.data($0, 2), Self.number($0, 3)))
            }
            guard let last = rows.last else { break }
            for (path, digest, encoded, bytes) in rows {
                try Task.checkCancellation()
                guard let identity = try? JSONDecoder().decode(FileReviewIdentity.self, from: encoded), FileReviewIdentity(path) == identity,
                      inventoryIncludes(path), duplicateEligibility.allows(path), try ownershipEvidence(path) == nil else { continue }
                try query("INSERT INTO review_duplicates VALUES(?,?,?,?)", [.text(path), .data(digest), .data(encoded), .number(bytes)])
            }
            after = last.0
        }
        try execute("CREATE INDEX IF NOT EXISTS temp.review_duplicate_digest ON review_duplicates(digest,path)")
    }
    private var duplicateSets: String {
        "SELECT digest,SUM(bytes)-MIN(bytes) AS removable,COUNT(*) AS copies,SUM(bytes) AS total FROM review_duplicates GROUP BY digest HAVING COUNT(*)>1"
    }
    func duplicateTotals(folder: String) throws -> (bytes: UInt64, count: UInt64) {
        try prepareVerifiedDuplicates(folder: folder)
        var bytes: UInt64 = 0, count: UInt64 = 0
        try query("SELECT COALESCE(SUM(removable),0),COALESCE(SUM(copies),0) FROM (" + duplicateSets + ")") { bytes = Self.number($0, 0); count = Self.number($0, 1) }
        return (bytes, count)
    }
    func duplicatePage(_ request: DiskBrowseRequest) throws -> DiskBrowsePage {
        try prepareVerifiedDuplicates(folder: request.folder)
        if let path = request.afterPath, try query("SELECT 1 FROM review_duplicates d JOIN (" + duplicateSets + ") s ON s.digest=d.digest WHERE d.path=?", [.text(path)]) == 0 {
            var current = request; current.afterPath = nil; current.afterSize = nil
            return try duplicatePage(current)
        }
        var condition = "", values: [Value] = []
        if let path = request.afterPath {
            condition = " WHERE (s.removable<(SELECT removable FROM (" + duplicateSets + ") g JOIN review_duplicates c ON c.digest=g.digest WHERE c.path=?) OR (s.removable=(SELECT removable FROM (" + duplicateSets + ") g JOIN review_duplicates c ON c.digest=g.digest WHERE c.path=?) AND (d.digest>(SELECT digest FROM review_duplicates WHERE path=?) OR (d.digest=(SELECT digest FROM review_duplicates WHERE path=?) AND d.path>?))))"
            values = Array(repeating: .text(path), count: 5)
        }
        var groups: [DiskDuplicateGroup] = [], files: [DiskFile] = [], counts: [String: Int] = [:], sizes: [String: UInt64] = [:]
        try query("SELECT d.path,d.digest,d.identity,d.bytes,s.copies,s.total FROM review_duplicates d JOIN (" + duplicateSets + ") s ON s.digest=d.digest" + condition + " ORDER BY s.removable DESC,d.digest,d.path LIMIT 201", values) {
            let path = Self.text($0, 0)
            counts[path] = Int(Self.number($0, 4)); sizes[path] = Self.number($0, 5)
            let identity = try JSONDecoder().decode(FileReviewIdentity.self, from: Self.data($0, 2))
            guard let proof = try duplicateVerification(path, selected: [path]) else { return }
            files.append(DiskFile(path: path, bytes: Self.number($0, 3), logicalBytes: UInt64(max(0, identity.size)), ownerUID: identity.uid, identity: identity, duplicateVerification: proof))
        }
        let more = files.count > 200
        if more { files.removeLast() }
        for file in files {
            guard let digest = file.duplicateVerification?.digest else { continue }
            let id = digest.map { String(format: "%02x", $0) }.joined()
            if let n = groups.firstIndex(where: { $0.id == id }) { groups[n].copies.append(file) }
            else { groups.append(.init(id: id, keeper: file, copies: [], copyCount: counts[file.path], totalBytes: sizes[file.path])) }
        }
        var next: DiskBrowseRequest?
        if more, let last = files.last { next = request; next?.afterPath = last.path; next?.afterSize = 0 }
        var page = DiskBrowsePage(request: request, files: files, next: next, ownership: [:])
        page.duplicateGroups = groups
        try query("SELECT COALESCE(SUM(copies),0),COALESCE(SUM(removable),0) FROM (" + duplicateSets + ")") { page.eligibleCount = Self.number($0, 0); page.eligibleBytes = Self.number($0, 1) }
        return page
    }

    /// One verified projection per complete scope, not one complete revalidation for every display page.
    func streamDuplicateScope(_ request: DiskBrowseRequest, visit: (DiskFile) throws -> Void) throws {
        try prepareVerifiedDuplicates(folder: request.folder)
        try query("SELECT d.path,d.identity,d.bytes,d.digest,k.path,k.identity FROM review_duplicates d JOIN review_duplicates k ON k.path=(SELECT path FROM review_duplicates v WHERE v.digest=d.digest AND v.path<>d.path ORDER BY path LIMIT 1) ORDER BY d.digest,d.path") {
            try Task.checkCancellation()
            let path = Self.text($0, 0), identity = try JSONDecoder().decode(FileReviewIdentity.self, from: Self.data($0, 1))
            let keeper = Self.text($0, 4), survivor = try JSONDecoder().decode(FileReviewIdentity.self, from: Self.data($0, 5))
            let proof = DiskDuplicateVerification(path: path, identity: identity, keeper: keeper, keeperIdentity: survivor, digest: Self.data($0, 3))
            try visit(.init(path: path, bytes: Self.number($0, 2), logicalBytes: UInt64(max(0, identity.size)), ownerUID: identity.uid, identity: identity, duplicateVerification: proof))
        }
    }

    /// The survivor belongs to the complete displayed scope, including off-page and open copies.
    func duplicateHeaderSurvivor(_ digest: Data, isSelected: (String) throws -> Bool,
                                 isCandidate: (String) throws -> Bool) throws -> String? {
        var retained: String?, fallback: String?
        try query("SELECT path,identity FROM review_duplicates WHERE digest=? ORDER BY path", [.data(digest)]) {
            try Task.checkCancellation()
            guard retained == nil else { return }
            let path = Self.text($0, 0)
            guard try !isSelected(path), let identity = try? JSONDecoder().decode(FileReviewIdentity.self, from: Self.data($0, 1)),
                  FileReviewIdentity(path) == identity, duplicateEligibility.allows(path), try ownershipEvidence(path) == nil else { return }
            if try !isCandidate(path) { retained = path }
            else if fallback == nil { fallback = path }
        }
        return retained ?? fallback
    }

    func duplicateVerification(_ path: String, selected: Set<String>) throws -> DiskDuplicateVerification? {
        try duplicateVerification(path, isSelected: { selected.contains($0) })
    }
    func duplicateVerification(_ path: String, isSelected: (String) throws -> Bool) throws -> DiskDuplicateVerification? {
        try duplicateTable()
        var expected: Data?, identity: FileReviewIdentity?
        try query("SELECT identity,digest FROM duplicates WHERE path=?", [.text(path)]) {
            identity = try? JSONDecoder().decode(FileReviewIdentity.self, from: Self.data($0, 0)); expected = Self.data($0, 1)
        }
        guard let expected, let identity, FileReviewIdentity(path) == identity, duplicateEligibility.allows(path), try ownershipEvidence(path) == nil else { return nil }
        var keeper: (String, FileReviewIdentity)?, after = ""
        while keeper == nil {
            var rows: [(String, Data)] = []
            try query("SELECT path,identity FROM duplicates WHERE digest=? AND path<>? AND path>? ORDER BY path LIMIT 32", [.data(expected), .text(path), .text(after)]) { rows.append((Self.text($0, 0), Self.data($0, 1))) }
            guard let last = rows.last else { break }
            for (other, encoded) in rows {
                guard try !isSelected(other), inventoryIncludes(other), duplicateEligibility.allows(other), try ownershipEvidence(other) == nil,
                      let value = try? JSONDecoder().decode(FileReviewIdentity.self, from: encoded), FileReviewIdentity(other) == value else { continue }
                keeper = (other, value); break
            }
            after = last.0
        }
        guard let keeper else { return nil }
        return .init(path: path, identity: identity, keeper: keeper.0, keeperIdentity: keeper.1, digest: expected)
    }
}
