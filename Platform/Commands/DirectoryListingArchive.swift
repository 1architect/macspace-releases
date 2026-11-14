import CryptoKit
import Darwin
import Foundation
import MacSpaceCipher

/// A single read-only snapshot's encrypted directory facts. Every hit still requires opening the current directory with the
/// caller's no-follow policy; only its attribute batches are reused. No action or privileged reader opts into this archive.
public final class DirectoryListingArchive: @unchecked Sendable {
    static let maximumPayload = 1_048_576
    private let lock = NSRecursiveLock()
    private let access: DirectoryArchiveAccess
    private let ownership: PrivateFile.ExclusiveLock
    private let excluded: String
    private var db: OpaquePointer?
    private var boundary: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var history: DirectoryChangeHistory?
    private var finished = false
    private var usable = true
    private var writes = 0
    private let transient = unsafeBitCast(-1, to: msc_sqlite3_destructor_type.self)
    private var hits = 0, misses = 0

    struct Identity: Equatable {
        let device: UInt64, inode: UInt64, uid: UInt64, gid: UInt64, mode: UInt64, flags: UInt64
        let modified: Int64, modifiedNanos: Int64, changed: Int64, changedNanos: Int64
        init(_ value: stat) {
            device = UInt64(UInt32(bitPattern: value.st_dev)); inode = value.st_ino
            uid = UInt64(value.st_uid); gid = UInt64(value.st_gid); mode = UInt64(value.st_mode); flags = UInt64(value.st_flags)
            modified = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
            changed = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
        }
        var data: Data {
            var data = Data()
            for number in [device, inode, uid, gid, mode, flags, UInt64(bitPattern: modified), UInt64(bitPattern: modifiedNanos), UInt64(bitPattern: changed), UInt64(bitPattern: changedNanos)] {
                var value = number.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
            return data
        }
    }

    /// Callers own the complete snapshot lifetime and must finish after all consumers stop. A failed cache never changes the
    /// fallback reader's result. `validateHistory: false` is exclusively for deterministic fixture tests with explicit changes.
    init(url: URL, validateHistory: Bool = true, changes: DirectoryChangeHistory.Changes = .init()) throws {
        try MetadataKeys.requireAvailable()
        excluded = DirectoryChangeHistory.canonical(url.deletingLastPathComponent().path)
        let key = try MetadataKeys.key(.inventory, create: true)
        let material = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: Data("MacSpace.directory-facts.v1".utf8),
            info: Data((String(getuid()) + ":" + url.path).utf8), outputByteCount: 32)
        access = try DirectoryArchiveAccess(url)
        ownership = try PrivateFile(url.deletingLastPathComponent().appendingPathComponent("facts.lock"), createDirectories: true).exclusiveLock()
        guard let boundary = msc_boundary_create(access.path) else { throw MetadataUnavailable() }
        self.boundary = boundary
        var success = false
        defer { if !success { closeDatabase() } }
        guard msc_sqlite3_open_v2(access.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW,
                                  msc_boundary_name(boundary)) == SQLITE_OK else { throw MetadataUnavailable() }
        guard material.withUnsafeBytes({ msc_cipher_key(db, $0.baseAddress, Int32($0.count)) }) == SQLITE_OK else { throw MetadataUnavailable() }
        try access.validate()
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-65536; PRAGMA mmap_size=0; PRAGMA journal_size_limit=1048576")
        try execute("CREATE TABLE IF NOT EXISTS header(id INTEGER PRIMARY KEY CHECK(id=1), version TEXT NOT NULL, cursor INTEGER NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS listings(path TEXT NOT NULL, request TEXT NOT NULL, identity BLOB NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(path,request)) WITHOUT ROWID")
        let version = "1:" + ProcessInfo.processInfo.operatingSystemVersionString
        var savedVersion = "", cursor: UInt64 = 0
        try query("SELECT version,cursor FROM header WHERE id=1") { row in
            if let value = msc_sqlite3_column_text(row, 0) { savedVersion = String(cString: value) }
            cursor = UInt64(max(0, msc_sqlite3_column_int64(row, 1)))
        }
        try execute("BEGIN IMMEDIATE")
        if savedVersion != version || cursor == 0 { try execute("DELETE FROM listings"); cursor = 0 }
        if validateHistory {
            let watcher = DirectoryChangeHistory(since: cursor, excluding: url.deletingLastPathComponent().path)
            history = watcher
            try invalidate(watcher.flush().changes)
        } else { try invalidate(changes) }
        try query("INSERT OR REPLACE INTO header VALUES(1,?,0)", text: [version])
        try execute("COMMIT; BEGIN IMMEDIATE")
        success = true
    }

    /// Snapshot callers opt in explicitly until the native equivalence/performance gate is complete. Benchmark callers must
    /// supply their isolated cache directory, so no live user's archive can warm a first-load sample.
    public static func experimental() -> DirectoryListingArchive? {
        guard let path = ProcessInfo.processInfo.environment["MACSPACE_DIRECTORY_ARCHIVE"],
              FileReviewPolicy.isNormalizedAbsolutePath(path), LivePermissionChecker.probeFullDiskAccess() == .granted else { return nil }
        return try? DirectoryListingArchive(url: URL(fileURLWithPath: path).appendingPathComponent("facts.sqlite"))
    }

    deinit { if !finished { try? execute("ROLLBACK") }; closeDatabase() }
    private func closeDatabase() {
        history?.stop(); history = nil
        for value in statements.values { msc_sqlite3_finalize(value) }; statements.removeAll()
        msc_sqlite3_close(db); db = nil
        msc_boundary_destroy(boundary); boundary = nil
    }
    private func execute(_ sql: String) throws {
        try MetadataKeys.requireAvailable()
        guard msc_boundary_validate(boundary) != 0, msc_sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MetadataUnavailable() }
    }
    private func query(_ sql: String, text: [String] = [], blobs: [Data] = [], row: (OpaquePointer) -> Void = { _ in }) throws {
        try MetadataKeys.requireAvailable()
        if msc_sqlite3_get_autocommit(db) != 0 {
            guard msc_boundary_validate(boundary) != 0 else { throw MetadataUnavailable() }
        }
        let statement: OpaquePointer
        if let value = statements[sql] { statement = value }
        else {
            var value: OpaquePointer?
            guard msc_sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw MetadataUnavailable() }
            statements[sql] = value; statement = value
        }
        msc_sqlite3_reset(statement); msc_sqlite3_clear_bindings(statement)
        defer { msc_sqlite3_reset(statement); msc_sqlite3_clear_bindings(statement) }
        for (index, value) in text.enumerated() { msc_sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        for (index, value) in blobs.enumerated() {
            _ = value.withUnsafeBytes { msc_sqlite3_bind_blob(statement, Int32(text.count + index + 1), $0.baseAddress, Int32($0.count), transient) }
        }
        while true {
            let result = msc_sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw MetadataUnavailable() }; row(statement)
        }
    }
    private func invalidate(_ changes: DirectoryChangeHistory.Changes) throws {
        if changes.lost { try execute("DELETE FROM listings"); return }
        for path in changes.shallow { try query("DELETE FROM listings WHERE path=?", text: [path]) }
        for path in changes.recursive {
            if path == "/" { try execute("DELETE FROM listings"); return }
            try query("DELETE FROM listings WHERE path=? OR (path>=? AND path<?)", text: [path, path + "/", path + "0"])
        }
    }
    func accepts(_ identity: Identity) -> Bool {
        let readableSystemDirectory = identity.uid == 0 && identity.mode & 0o005 == 0o005
        return (identity.uid == UInt64(getuid()) || readableSystemDirectory)
            && identity.device == UInt64(UInt32(bitPattern: access.device))
    }
    func read(_ path: String, request: String, identity: Identity) -> Data? {
        guard FileReviewPolicy.isNormalizedAbsolutePath(path), accepts(identity) else { return nil }
        return lock.withLock {
            guard usable && !finished else { return nil }
            do {
                var data: Data?
                try query("SELECT payload FROM listings WHERE path=? AND request=? AND identity=?", text: [DirectoryChangeHistory.canonical(path), request], blobs: [identity.data]) { row in
                    let count = Int(msc_sqlite3_column_bytes(row, 0))
                    if count > 0 && count <= Self.maximumPayload, let bytes = msc_sqlite3_column_blob(row, 0) { data = Data(bytes: bytes, count: count) }
                }
                if data != nil { hits += 1 } else { misses += 1 }
                return data
            } catch { usable = false; return nil }
        }
    }
    func record(_ data: Data, path: String, request: String, identity: Identity) {
        guard data.count <= Self.maximumPayload, FileReviewPolicy.isNormalizedAbsolutePath(path), accepts(identity) else { return }
        lock.withLock {
            guard usable && !finished else { return }
            do {
                try query("INSERT OR REPLACE INTO listings VALUES(?,?,?,?)", text: [DirectoryChangeHistory.canonical(path), request], blobs: [identity.data, data])
                writes += 1
                if writes >= 1024 { try execute("COMMIT; PRAGMA wal_checkpoint(PASSIVE); BEGIN IMMEDIATE"); writes = 0 }
            } catch { usable = false }
        }
    }
    public func finish() {
        lock.withLock {
            guard !finished else { return }
            do {
                if usable {
                    let boundary = history?.flush()
                    if let boundary { try invalidate(boundary.changes) }
                    let cursor = boundary?.through ?? 1
                    try execute("UPDATE header SET cursor=\(cursor) WHERE id=1; COMMIT; PRAGMA wal_checkpoint(PASSIVE)")
                } else { try? execute("ROLLBACK") }
            } catch { try? execute("ROLLBACK") }
            finished = true
            if ProcessInfo.processInfo.environment["MACSPACE_LOAD_METRICS"] == "1" {
                var pageHits: Int32 = 0, pageMisses: Int32 = 0, high: Int32 = 0
                _ = msc_sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_HIT, &pageHits, &high, 0)
                _ = msc_sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_MISS, &pageMisses, &high, 0)
                FileHandle.standardError.write(Data("DIRECTORY_ARCHIVE hits=\(hits) misses=\(misses) pageHits=\(pageHits) pageMisses=\(pageMisses) usable=\(usable)\n".utf8))
            }
        }
    }
    func accepts(_ path: String) -> Bool {
        let value = DirectoryChangeHistory.canonical(path)
        return value != excluded && !value.hasPrefix(excluded + "/")
    }
    var statistics: (hits: Int, misses: Int) { lock.withLock { (hits, misses) } }
}
