import Foundation
import Darwin
import SQLite3
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceDiskMapPrivileged

/// Directory measurements and reviewable personal-file metadata persist; Swift retains bounded page projections.
final class DiskDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    var inventoryIncludes: (String) -> Bool
    let duplicateEligibility: DiskDuplicateEligibility
    private(set) var compact = false
    private(set) var directoryParentIDs = true
    var smallerScope: String?
    var smallerIncomplete = false
    var smallerHasMore = false
    var smallerWindowStart: String?
    var smallerWindowEnd: String?
    var smallerRevision: UInt64 = 0
    var smallerAt = Date.distantPast
    var phase: ((String, Double, Int) -> Void)?
    var smallerLimit = 20_000
    let root: String
    let home: String
    private var prepared: [String: OpaquePointer] = [:]
    private var folderCounts: [String: (revision: UInt64, count: UInt64)] = [:]
    private var batching = false
    private var writes = 0
    /// Mutation statements in the current unflushed batch, available to backend performance diagnostics.
    var batchWriteCount: Int { writes }
    var unpublished = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    struct Failure: LocalizedError { var message: String; var errorDescription: String? { message } }
    init(url: URL, root: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        self.root = root; self.home = home
        self.duplicateEligibility = DiskDuplicateEligibility(home: home)
        self.inventoryIncludes = { FileReviewPolicy.includes($0, home: home) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { throw Failure(message: "Cannot open disk index") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA cache_size=-2048")
        try execute("PRAGMA mmap_size=0")
        try execute("PRAGMA temp_store=FILE")
        try execute("PRAGMA journal_size_limit=1048576")
        try execute("CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), data BLOB NOT NULL)")
        compact = try query("SELECT 1 FROM sqlite_master WHERE name='file_details' AND type='table'") == 0
        if compact { try compactSchema() }
        try query("PRAGMA table_info(dirs)") { if Self.text($0, 1) == "parent" { directoryParentIDs = Self.text($0, 2) == "INTEGER" } }
        var hasItemCount = false
        try query("PRAGMA table_info(dirs)") { if Self.text($0, 1) == "items" { hasItemCount = true } }
        if !hasItemCount { try execute("ALTER TABLE dirs ADD COLUMN items INTEGER") }
        try execute("CREATE TEMP TABLE IF NOT EXISTS pending_parents(path TEXT PRIMARY KEY,parent TEXT) WITHOUT ROWID")
        try execute("CREATE TABLE IF NOT EXISTS claims (id INTEGER PRIMARY KEY, data BLOB NOT NULL UNIQUE)")
        try execute("CREATE TABLE IF NOT EXISTS ownership (path TEXT NOT NULL, claim INTEGER NOT NULL, PRIMARY KEY(path,claim)) WITHOUT ROWID")
        try execute("CREATE TEMP TABLE IF NOT EXISTS dirty (path TEXT PRIMARY KEY) WITHOUT ROWID")
        try execute("CREATE TEMP TABLE IF NOT EXISTS seen_entries (name TEXT PRIMARY KEY) WITHOUT ROWID")
        try createIndexes()
        if compact, try state()?.summaryVersion != DiskIndex.summarySchemaVersion {
            var cursor = ""
            while true {
                try Task.checkCancellation()
                var paths: [String] = []
                try query("SELECT path FROM file_details WHERE path>? ORDER BY path LIMIT 256", [.text(cursor)]) { paths.append(Self.text($0, 0)) }
                guard let last = paths.last else { break }
                for path in paths {
                    try query("UPDATE entries SET category=?,kind=? WHERE parent=(SELECT id FROM dirs WHERE path=?) AND name=?", [.text(DiskCategory.inventoryCategory(path).rawValue), .text(DiskFileType.key(path)), .text(Self.parent(path)), .text((path as NSString).lastPathComponent)])
                }
                cursor = last
            }
            if var metadata = try state() { metadata.summaryVersion = DiskIndex.summarySchemaVersion; try saveState(metadata) }
        }
        if ProcessInfo.processInfo.environment["MACSPACE_DISK_METRICS"] == "1" {
            phase = { name, seconds, directories in
                DiskScanMetrics.write("DISK_PHASE phase=\(name) seconds=\(seconds) directories=\(directories)")
            }
        }
    }
    private static let indexes: [(String, String)] = [
        ("dirs_parent", "dirs(parent)"), ("dirs_depth", "dirs(length(path) DESC,id)"),
        ("dirs_apps", "dirs(path,total) WHERE substr(path,-4)='.app'"),
        ("dirs_bundles", "dirs(bundle) WHERE bundle<>''"),
        ("entries_links", "entries(link,parent,name) WHERE link<>''"),
        ("entries_large", "entries(logical DESC,parent,name) WHERE inventory=1")
    ]
    private func compactSchema() throws {
        // A directory's path exists once; every file stores only its integer parent and leaf name.
        try execute("CREATE TABLE IF NOT EXISTS dirs (id INTEGER PRIMARY KEY,path TEXT NOT NULL UNIQUE,parent INTEGER NOT NULL,direct INTEGER NOT NULL,total INTEGER NOT NULL,readable INTEGER NOT NULL,uid INTEGER,bundle TEXT,items INTEGER)")
        try execute("CREATE TABLE IF NOT EXISTS entries (parent INTEGER NOT NULL,name TEXT NOT NULL,bytes INTEGER NOT NULL,logical INTEGER NOT NULL,uid INTEGER,link TEXT NOT NULL,category TEXT NOT NULL,modified INTEGER,kind TEXT NOT NULL,inventory INTEGER NOT NULL,PRIMARY KEY(parent,name)) WITHOUT ROWID")
        let projection = "SELECT CASE WHEN d.path='/' THEN '/'||e.name ELSE d.path||'/'||e.name END AS path,d.path AS parent,e.bytes,e.logical,e.uid,e.link,e.category,e.modified,e.kind FROM entries e JOIN dirs d ON d.id=e.parent"
        try execute("CREATE VIEW IF NOT EXISTS files AS " + projection)
        try execute("CREATE VIEW IF NOT EXISTS file_details AS " + projection + " WHERE e.inventory=1")
        try execute("CREATE TRIGGER IF NOT EXISTS files_delete INSTEAD OF DELETE ON files BEGIN DELETE FROM entries WHERE parent=(SELECT id FROM dirs WHERE path=OLD.parent) AND name=substr(OLD.path,length(OLD.parent)+CASE WHEN OLD.parent='/' THEN 1 ELSE 2 END); END")
    }
    /// Only an unpublished empty generation uses bulk collection. Lookups are built once,
    /// before summaries/publication; normal incremental writes retain all indexes.
    func beginInitialCollection() throws {
        for (name, _) in Self.indexes { try execute("DROP INDEX IF EXISTS " + name) }
    }
    func createIndexes(progress: LoadProgressSink? = nil) throws {
        guard compact else { return }
        for (n, entry) in Self.indexes.enumerated() {
            try execute("CREATE INDEX IF NOT EXISTS " + entry.0 + " ON " + entry.1)
            progress?(Double(n + 1) / Double(Self.indexes.count))
        }
    }
    deinit { for value in prepared.values { sqlite3_finalize(value) }; sqlite3_close(db) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func error() -> Failure { Failure(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Closed index") }
    enum Value { case text(String), number(UInt64), optional(UInt32?), data(Data), date(Date?) }
    @discardableResult
    func query(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) throws -> Void = { _ in }) throws -> Int {
        let stmt: OpaquePointer
        if let cached = prepared[sql] { stmt = cached }
        else {
            var value: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw error() }
            stmt = value; prepared[sql] = value
        }
        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        for (n, value) in values.enumerated() {
            let position = Int32(n + 1)
            switch value {
            case let .text(value): sqlite3_bind_text(stmt, position, value, -1, transient)
            case let .number(value): sqlite3_bind_int64(stmt, position, Int64(clamping: value))
            case let .optional(value): if let value { sqlite3_bind_int64(stmt, position, Int64(value)) } else { sqlite3_bind_null(stmt, position) }
            case let .data(value): _ = value.withUnsafeBytes { sqlite3_bind_blob(stmt, position, $0.baseAddress, Int32($0.count), transient) }
            case let .date(value):
                if let value { sqlite3_bind_double(stmt, position, value.timeIntervalSince1970) }
                else { sqlite3_bind_null(stmt, position) }
            }
        }
        var count = 0
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE {
                if sqlite3_stmt_readonly(stmt) == 0 { writes += 1 }
                return count
            }
            guard result == SQLITE_ROW else { throw error() }
            try row(stmt); count += 1
        }
    }
    static func text(_ stmt: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "" }
    static func number(_ stmt: OpaquePointer, _ column: Int32) -> UInt64 { UInt64(max(0, sqlite3_column_int64(stmt, column))) }
    static func uid(_ stmt: OpaquePointer, _ column: Int32) -> UInt32? { sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : UInt32(clamping: sqlite3_column_int64(stmt, column)) }
    static func data(_ stmt: OpaquePointer, _ column: Int32) -> Data { sqlite3_column_blob(stmt, column).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, column))) } ?? Data() }
    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
    static func contains(_ path: String, below folder: String) -> Bool {
        guard FileReviewPolicy.isNormalizedAbsolutePath(path) else { return false }
        return path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }
    func state() throws -> DiskIndex? {
        var result: DiskIndex?
        try query("SELECT data FROM state WHERE id=1") { result = try JSONDecoder().decode(DiskIndex.self, from: Self.data($0, 0)) }
        return result
    }
    func saveState(_ index: DiskIndex) throws {
        var metadata = DiskIndex(root: root)
        metadata.eventID = index.eventID; metadata.revision = index.revision; metadata.catalogRevision = index.catalogRevision; metadata.volumeUsed = index.volumeUsed
        metadata.browseVersion = index.browseVersion
        metadata.storageRevision = index.storageRevision; metadata.summaryVersion = index.summaryVersion
        metadata.personalInventoryVersion = index.personalInventoryVersion
        try query("INSERT OR REPLACE INTO state VALUES(1,?)", [.data(try JSONEncoder().encode(metadata))])
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        // An initial database is unpublished until its final state record is committed.
        // It may checkpoint bounded batches without exposing a partial index to readers.
        batching = try unpublished || state() == nil; writes = 0
        defer { batching = false }
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func flushBatch() throws {
        guard batching && writes >= 8192 else { return }
        try execute("COMMIT")
        try execute("PRAGMA wal_checkpoint(PASSIVE)")
        writes = 0
        try execute("BEGIN IMMEDIATE")
    }
    func clearIncomplete() throws {
        try execute("DELETE FROM entries; DELETE FROM dirs; DELETE FROM claims; DELETE FROM ownership; DELETE FROM dirty; DELETE FROM pending_parents")
    }
    private func rememberParent(_ path: String) throws {
        guard path != root else { return }
        try query("INSERT OR IGNORE INTO pending_parents SELECT path,? FROM dirs WHERE path=? AND parent=0", [.text(Self.parent(path)), .text(path)])
    }
    func put(_ node: DiskDirectory) throws {
        try query("INSERT INTO dirs(path,parent,direct,total,readable,uid,bundle) VALUES(?,COALESCE((SELECT id FROM dirs WHERE path=?),0),?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET parent=excluded.parent,direct=excluded.direct,total=excluded.total,readable=excluded.readable,uid=excluded.uid,bundle=excluded.bundle WHERE dirs.parent IS NOT excluded.parent OR dirs.direct IS NOT excluded.direct OR dirs.total IS NOT excluded.total OR dirs.readable IS NOT excluded.readable OR dirs.uid IS NOT excluded.uid OR dirs.bundle IS NOT excluded.bundle", [.text(node.path), .text(node.path == root ? "" : Self.parent(node.path)), .number(node.directBytes), .number(node.bytes), .number(node.readable ? 1 : 0), .optional(node.ownerUID), .text(node.bundleIdentifier ?? "")])
        try query("UPDATE dirs SET items=? WHERE path=? AND items IS NOT ?", [node.itemCount.map { .number($0) } ?? .optional(nil), .text(node.path), node.itemCount.map { .number($0) } ?? .optional(nil)])
        try rememberParent(node.path)
    }
    func ensureDirectory(_ path: String, ownerUID: UInt32? = nil) throws {
        try query("INSERT INTO dirs(path,parent,direct,total,readable,uid,bundle) VALUES(?,COALESCE((SELECT id FROM dirs WHERE path=?),0),0,0,1,?,'') ON CONFLICT(path) DO UPDATE SET uid=excluded.uid WHERE dirs.uid IS NULL AND excluded.uid IS NOT NULL", [.text(path), .text(path == root ? "" : Self.parent(path)), .optional(ownerUID)])
        try rememberParent(path)
    }
    private static let entryInsertSQL = "INSERT INTO entries SELECT id,?,?,?,?,?,?,?,?,? FROM dirs WHERE path=? ON CONFLICT(parent,name) DO UPDATE SET bytes=excluded.bytes,logical=excluded.logical,uid=excluded.uid,link=excluded.link,category=excluded.category,modified=excluded.modified,kind=excluded.kind,inventory=excluded.inventory WHERE entries.bytes IS NOT excluded.bytes OR entries.logical IS NOT excluded.logical OR entries.uid IS NOT excluded.uid OR entries.link IS NOT excluded.link OR entries.category IS NOT excluded.category OR entries.modified IS NOT excluded.modified OR entries.kind IS NOT excluded.kind OR entries.inventory IS NOT excluded.inventory"
    private static let refreshInsertSQL = entryInsertSQL.replacingOccurrences(of: "entries", with: "refresh_entries")
    func put(_ file: DiskFile, link: String = "", trackSeen: Bool = false, staging: Bool = false) throws {
        let eligible = file.bytes > 0 && file.ownerUID == getuid() && inventoryIncludes(file.path)
        guard eligible || !link.isEmpty else { return }
        let parent = Self.parent(file.path), name = (file.path as NSString).lastPathComponent
        try ensureDirectory(parent)
        try query(staging ? Self.refreshInsertSQL : Self.entryInsertSQL, [
            .text(name), .number(file.bytes), .number(file.logicalBytes), .optional(file.ownerUID), .text(link),
            .text(eligible ? DiskCategory.inventoryCategory(file.path).rawValue : DiskCategory.other.rawValue), .date(file.modifiedAt), .text(eligible ? DiskFileType.key(file.path) : ""), .number(eligible ? 1 : 0), .text(parent)])
        if trackSeen { try query("INSERT OR IGNORE INTO seen_entries VALUES(?)", [.text(name)]) }
    }
    func directory(_ path: String, contents: Bool = false) throws -> DiskDirectory? {
        var node: DiskDirectory?
        try query("SELECT path,direct,total,readable,uid,bundle,items FROM dirs WHERE path=?", [.text(path)]) {
            node = DiskDirectory(path: Self.text($0, 0), itemCount: sqlite3_column_type($0, 6) == SQLITE_NULL ? nil : Self.number($0, 6), directBytes: Self.number($0, 1), bytes: Self.number($0, 2), readable: Self.number($0, 3) != 0, bundleIdentifier: Self.text($0, 5).isEmpty ? nil : Self.text($0, 5), ownerUID: Self.uid($0, 4))
        }
        if contents, node != nil {
            try query("SELECT path FROM dirs WHERE " + (directoryParentIDs ? "parent=(SELECT id FROM dirs WHERE path=?)" : "parent=?") + " ORDER BY path", [.text(path)]) { node?.folders.append(Self.text($0, 0)) }
            node?.files = try files(parent: path, limit: 200)
        }
        return node
    }
    /// Legacy caches lack direct entry counts. Measure only visible folder roots once per revision.
    func countedDirectory(_ path: String) throws -> DiskDirectory? {
        guard var node = try directory(path) else { return nil }
        guard node.itemCount == nil else { return node }
        let revision = try state()?.revision ?? 0
        if let cached = folderCounts[path], cached.revision == revision { node.itemCount = cached.count; return node }
        var count: UInt64 = 0
        let complete = autoreleasepool { DirectoryWalk.entries(at: path) { _, _ in count += 1 } }
        guard complete else { return node }
        if folderCounts.count >= 256 { folderCounts.removeAll(keepingCapacity: true) }
        folderCounts[path] = (revision, count); node.itemCount = count
        return node
    }
    func children(_ path: String) throws -> [String] {
        var paths: [String] = []
        try query("SELECT path FROM dirs WHERE " + (directoryParentIDs ? "parent=(SELECT id FROM dirs WHERE path=?)" : "parent=?") + " ORDER BY path", [.text(path)]) { paths.append(Self.text($0, 0)) }
        return paths
    }
    private func decodeFile(_ stmt: OpaquePointer) -> DiskFile {
        var file = DiskFile(path: Self.text(stmt, 0), bytes: Self.number(stmt, 1), logicalBytes: Self.number(stmt, 2), ownerUID: Self.uid(stmt, 3))
        if file.ownerUID == nil { var info = stat(); if lstat(file.path, &info) == 0 { file.ownerUID = info.st_uid } }
        return file
    }
    func files(parent: String? = nil, limit: Int = 200) throws -> [DiskFile] {
        var result: [DiskFile] = []
        let sql = "SELECT path,bytes,logical,uid FROM file_details f WHERE logical>=100000000 AND bytes>0 AND " + countedDetails + (parent == nil ? "" : " AND parent=?") + " ORDER BY logical DESC,path DESC LIMIT " + String(max(1, min(limit, 200)))
        try query(sql, parent.map { [.text($0)] } ?? []) { result.append(try reviewedFile(decodeFile($0), duplicateEvidence: false)) }
        return result
    }
    func markTotals(_ path: String) throws {
        guard Self.contains(path, below: root) else { return }
        var current = path
        while true {
            try query("INSERT OR IGNORE INTO dirty VALUES(?)", [.text(current)])
            // A successful mark already includes its ancestor chain in this transaction. Stop at the first
            // shared parent instead of validating/reinserting that same chain for every folder and hard-link alias.
            if sqlite3_changes(db) == 0 || current == root { break }
            current = Self.parent(current)
        }
    }

    /// Reuse cached enumeration counts, without touching filesystem contents. Legacy caches with missing item counts
    /// use directory work alone; the first refresh fills their counts for subsequent entry-based estimates.
    func scanWork(recursive: [String], shallow: [String]) throws -> (directories: Int, entries: Int?, unknownScopes: Bool) {
        var directories = 0, entries = 0, known = true, unknownScopes = false
        func add(_ sql: String, _ values: [Value]) throws {
            try query(sql, values) {
                let count = Int(Self.number($0, 0)), measured = Int(Self.number($0, 2))
                directories += max(count, 1)
                entries += Int(Self.number($0, 1))
                if count == 0 { unknownScopes = true }
                if count == 0 || count != measured { known = false }
            }
        }
        for path in recursive {
            try add("SELECT COUNT(*),COALESCE(SUM(items),0),COUNT(items) FROM dirs WHERE path=? OR (path>=? AND path<?)",
                [.text(path), .text(path == "/" ? "/" : path + "/"), .text(path == "/" ? "0" : path + "0")])
        }
        for path in shallow {
            try add("SELECT COUNT(*),COALESCE(SUM(items),0),COUNT(items) FROM dirs WHERE path=?", [.text(path)])
        }
        return (directories, known ? entries : nil, unknownScopes)
    }
    func hasLinkedEntries(parent: String) throws -> Bool {
        try query("SELECT 1 FROM entries WHERE parent=(SELECT id FROM dirs WHERE path=?) AND link<>'' LIMIT 1", [.text(parent)]) > 0
    }
    func beginDirectoryRefresh() throws { try execute("DELETE FROM seen_entries") }
    func finishDirectoryRefresh(_ path: String) throws {
        try query("DELETE FROM entries WHERE parent=(SELECT id FROM dirs WHERE path=?) AND name NOT IN (SELECT name FROM seen_entries)", [.text(path)])
    }
    func linkParents(at path: String) throws -> [String] {
        var result: [String] = []
        try query("SELECT DISTINCT d.path FROM entries e JOIN dirs d ON d.id=e.parent WHERE e.link<>'' AND e.link IN (SELECT link FROM entries WHERE parent=(SELECT id FROM dirs WHERE path=?) AND link<>'')", [.text(path)]) { result.append(Self.text($0, 0)) }
        return result
    }
    func remove(_ path: String, markAffectedTotals: Bool = true) throws {
        let prefix = path == "/" ? "/" : path + "/", end = String(prefix.dropLast()) + "0"
        var links: [String] = []
        let range: [Value] = [.text(path), .text(prefix), .text(end)]
        if markAffectedTotals {
          try query("SELECT DISTINCT d.path FROM entries e JOIN dirs d ON d.id=e.parent WHERE e.link<>'' AND e.link IN (SELECT e.link FROM entries e JOIN dirs d ON d.id=e.parent WHERE e.link<>'' AND (d.path=? OR (d.path>=? AND d.path<?)))", range) { links.append(Self.text($0, 0)) }
          for parent in links { try markTotals(parent) }
        }
        try query("DELETE FROM entries WHERE parent IN (SELECT id FROM dirs WHERE path=? OR (path>=? AND path<?))", range)
        try query("DELETE FROM dirs WHERE path=? OR (path>=? AND path<?)", range)
        if markAffectedTotals { try markTotals(Self.parent(path)) }
    }
    func updateLink(_ file: DiskFile, link: String) throws {
        try query("SELECT path FROM files WHERE link=? AND link<>''", [.text(link)]) {
            var alias = file; alias.path = Self.text($0, 0)
            try put(alias, link: link)
        }
    }
    func clearFiles(parent: String) throws {
        try query("DELETE FROM entries WHERE parent=(SELECT id FROM dirs WHERE path=?)", [.text(parent)])
    }
    func total(_ path: String) throws {
        let measured = "direct+COALESCE((SELECT SUM(total) FROM dirs c WHERE c.parent=dirs.id),0)+COALESCE((SELECT SUM(bytes) FROM entries e WHERE e.parent=dirs.id AND e.link<>'' AND (e.parent,e.name)=(SELECT l.parent,l.name FROM entries l WHERE l.link=e.link AND l.link<>'' ORDER BY l.parent,l.name LIMIT 1)),0)"
        try query("UPDATE dirs SET total=\(measured) WHERE path=? AND total IS NOT (\(measured))", [.text(path)])
    }
    func resolvePendingParents() throws {
        try execute("UPDATE dirs SET parent=COALESCE((SELECT p.id FROM dirs p JOIN pending_parents q ON q.parent=p.path WHERE q.path=dirs.path),0) WHERE path IN (SELECT path FROM pending_parents); DELETE FROM pending_parents")
    }
    func advanceEventCursor(_ cursor: UInt64) throws {
        guard var metadata = try state(), cursor > metadata.eventID else { return }
        try transaction {
            metadata.eventID = cursor
            try saveState(metadata)
        }
        try checkpoint()
    }
    func reconcileTotals(all: Bool, progress: LoadProgressSink? = nil) throws {
        try resolvePendingParents()
        if all {
            var depth: UInt64 = 2147483647, last: UInt64 = 0, done = 0, count = 0
            try query("SELECT COUNT(*) FROM dirs") { count = Int(Self.number($0, 0)) }
            while true {
                var batch: [(String, UInt64)] = []
                // Separate equal-depth and next-depth seeks: an OR/tuple cursor can restart a full index scan.
                try query("SELECT path,id FROM dirs WHERE length(path)=? AND id>? ORDER BY id LIMIT 512", [.number(depth), .number(last)]) { batch.append((Self.text($0, 0), Self.number($0, 1))) }
                if batch.count < 512 {
                    try query("SELECT path,id FROM dirs WHERE length(path)<? ORDER BY length(path) DESC,id LIMIT ?", [.number(depth), .number(UInt64(512 - batch.count))]) { batch.append((Self.text($0, 0), Self.number($0, 1))) }
                }
                if batch.isEmpty { break }
                for (path, _) in batch { try total(path) }
                last = batch.last!.1; depth = UInt64(batch.last!.0.unicodeScalars.count)
                done += batch.count; progress?(0.25 + 0.75 * Double(done) / Double(max(count, 1)))
                try Task.checkCancellation()
                try flushBatch()
            }
        } else {
            var count = 0, done = 0
            try query("SELECT COUNT(*) FROM dirty") { count = Int(Self.number($0, 0)) }
            let step = max(32, count / 128)
            progress?(0)
            try query("SELECT path FROM dirty ORDER BY length(path) DESC") {
                try total(Self.text($0, 0)); done += 1
                if done % step == 0 { progress?(Double(done) / Double(max(count, 1))) }
            }
            progress?(1)
        }
        try execute("DELETE FROM dirty")
    }
    func compactReviewIndex() throws {
        if !compact {
            try transaction {
                // Keep old measurements and identity evidence. Only the redundant file representation changes.
                try execute("ALTER TABLE dirs RENAME TO legacy_dirs")
                try execute("ALTER TABLE files RENAME TO legacy_files")
                try execute("ALTER TABLE file_details RENAME TO legacy_details")
                try compactSchema()
                try execute("INSERT INTO dirs(path,parent,direct,total,readable,uid,bundle) SELECT path,0,direct,total,readable,uid,bundle FROM legacy_dirs")
                try execute("UPDATE dirs SET parent=COALESCE((SELECT p.id FROM legacy_dirs l JOIN dirs p ON p.path=l.parent WHERE l.path=dirs.path),0)")
                try query("SELECT path,bytes,logical,uid,link,modified FROM legacy_details WHERE logical>=100000000 OR link<>''") {
                    let file = DiskFile(path: Self.text($0, 0), bytes: Self.number($0, 1), logicalBytes: Self.number($0, 2), ownerUID: Self.uid($0, 3), modifiedAt: sqlite3_column_type($0, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double($0, 5)))
                    try put(file, link: Self.text($0, 4))
                }
                // Some legacy hardlinks lacked detail rows; they still contribute to full-map physical totals.
                try query("SELECT path,bytes,logical,uid,link FROM legacy_files WHERE link<>''") {
                    let file = DiskFile(path: Self.text($0, 0), bytes: Self.number($0, 1), logicalBytes: Self.number($0, 2), ownerUID: Self.uid($0, 3))
                    // Detail metadata wins when both legacy tables contained this name.
                    var exists = false
                    try query("SELECT 1 FROM entries WHERE parent=(SELECT id FROM dirs WHERE path=?) AND name=?", [.text(Self.parent(file.path)), .text((file.path as NSString).lastPathComponent)]) { _ in exists = true }
                    if !exists { try put(file, link: Self.text($0, 4)) }
                }
                try execute("DROP TABLE legacy_details; DROP TABLE legacy_files; DROP TABLE legacy_dirs")
                compact = true; directoryParentIDs = true
                try createIndexes()
        if compact, try state()?.summaryVersion != DiskIndex.summarySchemaVersion {
            var cursor = ""
            while true {
                try Task.checkCancellation()
                var paths: [String] = []
                try query("SELECT path FROM file_details WHERE path>? ORDER BY path LIMIT 256", [.text(cursor)]) { paths.append(Self.text($0, 0)) }
                guard let last = paths.last else { break }
                for path in paths {
                    try query("UPDATE entries SET category=?,kind=? WHERE parent=(SELECT id FROM dirs WHERE path=?) AND name=?", [.text(DiskCategory.inventoryCategory(path).rawValue), .text(DiskFileType.key(path)), .text(Self.parent(path)), .text((path as NSString).lastPathComponent)])
                }
                cursor = last
            }
        }
                try execute("DROP TABLE IF EXISTS directory_stats")
            }
        }
        if !directoryParentIDs {
            try transaction {
                try execute("DROP TRIGGER IF EXISTS files_delete; DROP VIEW files; DROP VIEW file_details; ALTER TABLE dirs RENAME TO legacy_dirs")
                try compactSchema()
                try execute("INSERT INTO dirs(id,path,parent,direct,total,readable,uid,bundle) SELECT id,path,0,direct,total,readable,uid,bundle FROM legacy_dirs")
                try execute("UPDATE dirs SET parent=COALESCE((SELECT p.id FROM legacy_dirs l JOIN dirs p ON p.path=l.parent WHERE l.path=dirs.path),0); DROP TABLE legacy_dirs")
                directoryParentIDs = true; try createIndexes()
            }
        }
        try execute("DROP INDEX IF EXISTS dirs_depth; CREATE INDEX dirs_depth ON dirs(length(path) DESC,id)")
        try execute("VACUUM")
        try prepareBrowseMetadata()
    }
    func seal() throws { try execute("PRAGMA wal_checkpoint(TRUNCATE)") }
    func checkpoint() throws { try execute("PRAGMA wal_checkpoint(PASSIVE)"); try execute("PRAGMA shrink_memory") }
}
