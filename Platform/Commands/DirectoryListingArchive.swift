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
    private var ownership: PrivateFile.ExclusiveLock?
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
    // Negative lookups must not queue behind SQLite commits/checkpoints. No code holds this lock while acquiring `lock`.
    private let hintLock = NSLock()
    /// Negative membership hints only: collisions may cause an unnecessary SQL lookup, never authorize a cache hit.
    /// The fixed 512 KiB bitset is rebuilt from ciphertext on open and updated under the database lock.
    private var paths = PathHints()
    private struct PathHints {
        private var words = [UInt64](repeating: 0, count: 65_536)
        private func indexes(_ path: String) -> (UInt64, UInt64) {
            let first = UInt64(bitPattern: Int64(path.hashValue))
            return (first, (first >> 32) | 1)
        }
        mutating func insert(_ path: String) {
            var (hash, step) = indexes(path)
            for _ in 0..<4 {
                let bit = Int(hash & 4_194_303)
                words[bit >> 6] |= UInt64(1) << (bit & 63)
                hash &+= step
            }
        }
        func mayContain(_ path: String) -> Bool {
            var (hash, step) = indexes(path)
            for _ in 0..<4 {
                let bit = Int(hash & 4_194_303)
                if words[bit >> 6] & (UInt64(1) << (bit & 63)) == 0 { return false }
                hash &+= step
            }
            return true
        }
    }
    private var generation: UInt64 = 0
    private static let registryLock = NSLock()
    private struct Readers { var archive: DirectoryListingArchive; var count: Int }
    nonisolated(unsafe) private static var readers: [String: Readers] = [:]

    public final class Lease: @unchecked Sendable {
        public let archive: DirectoryListingArchive
        private let path: String
        private let lock = NSLock()
        private var released = false
        fileprivate init(_ archive: DirectoryListingArchive, path: String) { self.archive = archive; self.path = path }
        public func finish() {
            let release = lock.withLock { () -> Bool in
                if released { return false }; released = true; return true
            }
            if release { DirectoryListingArchive.release(path) }
        }
        deinit { finish() }
    }

    public static func experimentalLease() -> Lease? {
        guard let path = ProcessInfo.processInfo.environment["MACSPACE_DIRECTORY_ARCHIVE"],
              FileReviewPolicy.isNormalizedAbsolutePath(path), LivePermissionChecker.probeFullDiskAccess() == .granted else { return nil }
        return try? borrow(URL(fileURLWithPath: DirectoryChangeHistory.canonical(path)).appendingPathComponent("facts.sqlite"))
    }
    static func borrow(_ url: URL, validateHistory: Bool = true) throws -> Lease {
        let path = url.path
        let (archive, existing) = try registryLock.withLock { () throws -> (DirectoryListingArchive, Bool) in
            if var group = readers[path] {
                group.count += 1; readers[path] = group
                return (group.archive, true)
            }
            let archive = try DirectoryListingArchive(url: url, validateHistory: validateHistory)
            readers[path] = Readers(archive: archive, count: 1)
            return (archive, false)
        }
        // A later consumer has its own request boundary. In-flight native output from the preceding boundary is discarded.
        if existing { archive.advanceReadBoundary() }
        return Lease(archive, path: path)
    }
    private static func release(_ path: String) {
        let archive = registryLock.withLock { () -> DirectoryListingArchive? in
            guard var group = readers[path] else { return nil }
            group.count -= 1
            if group.count == 0 { readers.removeValue(forKey: path); return group.archive }
            readers[path] = group; return nil
        }
        archive?.finish()
    }

    func advanceReadBoundary(changes: DirectoryChangeHistory.Changes? = nil) {
        advanceReadBoundary(changes: { changes ?? self.history?.flush().changes ?? .init() })
    }

    func advanceReadBoundary(changes readChanges: () -> DirectoryChangeHistory.Changes) {
        lock.withLock {
            guard usable && !finished else { return }
            do { try invalidate(readChanges()) }
            catch { usable = false }
            // Fast negative lookups can proceed during the fence. Their native output belongs to the old boundary and
            // must be rejected if it arrives after invalidation; publish the next generation only once the fence finishes.
            hintLock.withLock { generation += 1 }
        }
    }

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
        try query("SELECT DISTINCT path FROM listings") { row in
            if let value = msc_sqlite3_column_text(row, 0) { hintLock.withLock { paths.insert(String(cString: value)) } }
        }
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
        if changes.lost { try execute("DELETE FROM listings"); hintLock.withLock { paths = PathHints() }; return }
        for path in changes.shallow { try query("DELETE FROM listings WHERE path=?", text: [path]) }
        for path in changes.recursive {
            if path == "/" { try execute("DELETE FROM listings"); hintLock.withLock { paths = PathHints() }; return }
            try query("DELETE FROM listings WHERE path=? OR (path>=? AND path<?)", text: [path, path + "/", path + "0"])
        }
    }
    func accepts(_ identity: Identity) -> Bool {
        let readableSystemDirectory = identity.uid == 0 && identity.mode & 0o005 == 0o005
        return (identity.uid == UInt64(getuid()) || readableSystemDirectory)
            && identity.device == UInt64(UInt32(bitPattern: access.device))
    }
    func read(_ path: String, request: String, identity: Identity) -> Data? {
        lookup(path, request: request, identity: identity).data
    }
    func lookup(_ path: String, request: String, identity: Identity) -> (data: Data?, generation: UInt64) {
        guard FileReviewPolicy.isNormalizedAbsolutePath(path), accepts(identity) else { return (nil, 0) }
        let canonical = DirectoryChangeHistory.canonical(path)
        let absentGeneration: UInt64? = hintLock.withLock {
            guard !paths.mayContain(canonical) else { return nil }
            misses += 1
            return generation
        }
        if let absentGeneration { return (nil, absentGeneration) }
        return lock.withLock {
            guard usable && !finished else { return (nil, generation) }
            do {
                var data: Data?
                try query("SELECT payload FROM listings WHERE path=? AND request=? AND identity=?", text: [canonical, request], blobs: [identity.data]) { row in
                    let count = Int(msc_sqlite3_column_bytes(row, 0))
                    if count > 0 && count <= Self.maximumPayload, let bytes = msc_sqlite3_column_blob(row, 0) { data = Data(bytes: bytes, count: count) }
                }
                if data != nil { hits += 1 } else { hintLock.withLock { misses += 1 } }
                return (data, generation)
            } catch { usable = false; return (nil, generation) }
        }
    }
    func record(_ data: Data, path: String, request: String, identity: Identity, generation expected: UInt64? = nil) {
        guard data.count <= Self.maximumPayload, FileReviewPolicy.isNormalizedAbsolutePath(path), accepts(identity) else { return }
        lock.withLock {
            guard usable && !finished, expected == nil || expected == generation else { return }
            do {
                let canonical = DirectoryChangeHistory.canonical(path)
                try query("INSERT OR REPLACE INTO listings VALUES(?,?,?,?)", text: [canonical, request], blobs: [identity.data, data])
                hintLock.withLock { paths.insert(canonical) }
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
                let missed = hintLock.withLock { misses }
                FileHandle.standardError.write(Data("DIRECTORY_ARCHIVE hits=\(hits) misses=\(missed) pageHits=\(pageHits) pageMisses=\(pageMisses) usable=\(usable)\n".utf8))
            }
            closeDatabase(); ownership = nil
        }
    }
    func accepts(_ path: String) -> Bool {
        let value = DirectoryChangeHistory.canonical(path)
        return value != excluded && !value.hasPrefix(excluded + "/")
    }
    var statistics: (hits: Int, misses: Int) { lock.withLock { hintLock.withLock { (hits, misses) } } }
}
