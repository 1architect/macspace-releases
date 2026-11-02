import Foundation
import Darwin
import SQLite3
import MacSpaceDiskMapPrivileged

/// The complete index stays on disk. Both SQLite's page cache and every query result are bounded independently of disk size.
final class DiskDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    let root: String
    private var prepared: [String: OpaquePointer] = [:]
    private var batching = false
    private var writes = 0
    var unpublished = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    struct Failure: Error { var message: String }
    init(url: URL, root: String) throws {
        self.root = root
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
        try execute("CREATE TABLE IF NOT EXISTS dirs (path TEXT PRIMARY KEY, parent TEXT NOT NULL, direct INTEGER NOT NULL, total INTEGER NOT NULL, readable INTEGER NOT NULL, uid INTEGER, bundle TEXT) WITHOUT ROWID")
        try execute("CREATE INDEX IF NOT EXISTS dirs_parent ON dirs(parent)")
        try execute("CREATE INDEX IF NOT EXISTS dirs_depth ON dirs(length(path) DESC,path)")
        try execute("CREATE INDEX IF NOT EXISTS dirs_apps ON dirs(path,total) WHERE substr(path,-4)='.app'")
        try execute("CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, parent TEXT NOT NULL, bytes INTEGER NOT NULL, logical INTEGER NOT NULL, uid INTEGER, link TEXT NOT NULL DEFAULT '') WITHOUT ROWID")
        try execute("CREATE INDEX IF NOT EXISTS files_parent ON files(parent)")
        try execute("CREATE INDEX IF NOT EXISTS files_links ON files(link,path) WHERE link<>''")
        try execute("CREATE TABLE IF NOT EXISTS claims (id INTEGER PRIMARY KEY, data BLOB NOT NULL UNIQUE)")
        try execute("CREATE TABLE IF NOT EXISTS ownership (path TEXT NOT NULL, claim INTEGER NOT NULL, PRIMARY KEY(path,claim)) WITHOUT ROWID")
        try execute("CREATE TEMP TABLE IF NOT EXISTS dirty (path TEXT PRIMARY KEY) WITHOUT ROWID")
    }
    deinit { for value in prepared.values { sqlite3_finalize(value) }; sqlite3_close(db) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func error() -> Failure { Failure(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Closed index") }
    enum Value { case text(String), number(UInt64), optional(UInt32?), data(Data) }
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
    static func contains(_ path: String, below folder: String) -> Bool { path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/") }
    func state() throws -> DiskIndex? {
        var result: DiskIndex?
        try query("SELECT data FROM state WHERE id=1") { result = try JSONDecoder().decode(DiskIndex.self, from: Self.data($0, 0)) }
        return result
    }
    func saveState(_ index: DiskIndex) throws {
        var metadata = DiskIndex(root: root)
        metadata.eventID = index.eventID; metadata.revision = index.revision; metadata.catalogRevision = index.catalogRevision; metadata.volumeUsed = index.volumeUsed
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
        guard batching && writes >= 1024 else { return }
        try execute("COMMIT")
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        writes = 0
        try execute("BEGIN IMMEDIATE")
    }
    func clearIncomplete() throws {
        try execute("DELETE FROM dirs; DELETE FROM files; DELETE FROM claims; DELETE FROM ownership; DELETE FROM dirty")
    }
    func put(_ node: DiskDirectory) throws {
        try query("INSERT OR REPLACE INTO dirs VALUES(?,?,?,?,?,?,?)", [.text(node.path), .text(node.path == root ? "" : Self.parent(node.path)), .number(node.directBytes), .number(node.bytes), .number(node.readable ? 1 : 0), .optional(node.ownerUID), .text(node.bundleIdentifier ?? "")])
    }
    func put(_ file: DiskFile, link: String = "") throws {
        try query("INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?)", [.text(file.path), .text(Self.parent(file.path)), .number(file.bytes), .number(file.logicalBytes), .optional(file.ownerUID), .text(link)])
    }
    func directory(_ path: String, contents: Bool = false) throws -> DiskDirectory? {
        var node: DiskDirectory?
        try query("SELECT path,direct,total,readable,uid,bundle FROM dirs WHERE path=?", [.text(path)]) {
            node = DiskDirectory(path: Self.text($0, 0), directBytes: Self.number($0, 1), bytes: Self.number($0, 2), readable: Self.number($0, 3) != 0, bundleIdentifier: Self.text($0, 5).isEmpty ? nil : Self.text($0, 5), ownerUID: Self.uid($0, 4))
        }
        if contents, node != nil {
            try query("SELECT path FROM dirs WHERE parent=? ORDER BY path", [.text(path)]) { node?.folders.append(Self.text($0, 0)) }
            node?.files = try files(parent: path)
        }
        return node
    }
    func children(_ path: String) throws -> [String] {
        var paths: [String] = []
        try query("SELECT path FROM dirs WHERE parent=? ORDER BY path", [.text(path)]) { paths.append(Self.text($0, 0)) }
        return paths
    }
    private func decodeFile(_ stmt: OpaquePointer) -> DiskFile {
        var file = DiskFile(path: Self.text(stmt, 0), bytes: Self.number(stmt, 1), logicalBytes: Self.number(stmt, 2), ownerUID: Self.uid(stmt, 3))
        if file.ownerUID == nil { var info = stat(); if lstat(file.path, &info) == 0 { file.ownerUID = info.st_uid } }
        return file
    }
    func files(parent: String? = nil) throws -> [DiskFile] {
        var result: [DiskFile] = []
        let sql = "SELECT path,bytes,logical,uid FROM files f WHERE logical>=100000000 AND bytes>0 AND (link='' OR path=(SELECT MIN(path) FROM files l WHERE l.link=f.link AND l.link<>''))" + (parent == nil ? "" : " AND parent=?") + " ORDER BY logical DESC,path DESC"
        try query(sql, parent.map { [.text($0)] } ?? []) { result.append(decodeFile($0)) }
        return result
    }
    func markTotals(_ path: String) throws {
        var current = path
        while Self.contains(current, below: root) {
            try query("INSERT OR IGNORE INTO dirty VALUES(?)", [.text(current)])
            if current == root { break }; current = Self.parent(current)
        }
    }
    func linkParents(at path: String) throws -> [String] {
        var result: [String] = []
        try query("SELECT DISTINCT parent FROM files WHERE link<>'' AND link IN (SELECT link FROM files WHERE parent=? AND link<>'')", [.text(path)]) { result.append(Self.text($0, 0)) }
        return result
    }
    func remove(_ path: String) throws {
        let prefix = path == "/" ? "/" : path + "/", end = prefix + "\u{10ffff}"
        var links: [String] = []
        try query("SELECT DISTINCT parent FROM files WHERE link<>'' AND link IN (SELECT link FROM files WHERE path=? OR (path>=? AND path<?))", [.text(path), .text(prefix), .text(end)]) { links.append(Self.text($0, 0)) }
        for parent in links { try markTotals(parent) }
        try query("DELETE FROM files WHERE path=? OR (path>=? AND path<?)", [.text(path), .text(prefix), .text(end)])
        try query("DELETE FROM dirs WHERE path=? OR (path>=? AND path<?)", [.text(path), .text(prefix), .text(end)])
        try markTotals(Self.parent(path))
    }
    func total(_ path: String) throws {
        try query("UPDATE dirs SET total=direct+COALESCE((SELECT SUM(total) FROM dirs c WHERE c.parent=dirs.path),0)+COALESCE((SELECT SUM(bytes) FROM files f WHERE f.parent=dirs.path AND f.link<>'' AND f.path=(SELECT MIN(path) FROM files l WHERE l.link=f.link AND l.link<>'')),0) WHERE path=?", [.text(path)])
    }
    func reconcileTotals(all: Bool) throws {
        if all {
            var length = Int.max, last = ""
            while true {
                var batch: [String] = []
                try query("SELECT path FROM dirs WHERE length(path)<? OR (length(path)=? AND path>?) ORDER BY length(path) DESC,path LIMIT 512", [.number(UInt64(length)), .number(UInt64(length)), .text(last)]) { batch.append(Self.text($0, 0)) }
                if batch.isEmpty { break }
                for path in batch { try total(path) }
                last = batch.last!; length = last.unicodeScalars.count
                try flushBatch()
            }
        } else {
            try query("SELECT path FROM dirty ORDER BY length(path) DESC") { try total(Self.text($0, 0)) }
        }
        try execute("DELETE FROM dirty")
    }
    /// Import old framed records one at a time, never materializing the legacy dictionary.
    func importLegacy(_ url: URL) throws {
        try transaction {
            let state = try DiskCache.stream(from: url, root: root, directory: { node in
                try put(node); for file in node.files { try put(file) }; try flushBatch()
            }, links: { id, files in for file in files { try put(file, link: id); try flushBatch() } }, claim: { _, _ in })
            guard try directory(root) != nil else { throw Failure(message: "Incomplete imported index") }
            try saveState(state)
        }
    }
    func seal() throws { try execute("PRAGMA wal_checkpoint(TRUNCATE)") }
    func checkpoint() throws { try execute("PRAGMA wal_checkpoint(PASSIVE)"); try execute("PRAGMA shrink_memory") }
}
