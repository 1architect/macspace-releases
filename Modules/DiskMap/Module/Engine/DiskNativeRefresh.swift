import Foundation
import MacSpaceCipher

/// SQLite staging for a complete native refresh. Only completely enumerated directories replace file rows;
/// unreadable/dataless branches retain their prior measurements and memberships.
extension DiskDatabase {
    func beginNativeRefresh() throws {
        try execute("DROP TABLE IF EXISTS refresh_entries; DROP TABLE IF EXISTS refresh_dirs; DROP TABLE IF EXISTS refresh_retained_links")
        try execute("CREATE TEMP TABLE refresh_entries \(Self.entryLayout)")
        try execute("CREATE INDEX refresh_entries_links ON refresh_entries(link) WHERE link<>''")
        try execute("CREATE TEMP TABLE refresh_dirs(id INTEGER PRIMARY KEY,uid INTEGER,direct INTEGER NOT NULL DEFAULT 0,bundle TEXT NOT NULL DEFAULT '',readable INTEGER NOT NULL DEFAULT 0,items INTEGER,complete INTEGER NOT NULL DEFAULT 0)")
    }
    func nativeDirectorySeen(_ path: String, uid: UInt32?) throws {
        let sql = "INSERT INTO refresh_dirs(id,uid) SELECT id,? FROM dirs WHERE path=? ON CONFLICT(id) DO UPDATE SET uid=COALESCE(excluded.uid,refresh_dirs.uid) RETURNING id"
        let values: [Value] = [.optional(uid), .text(path)]
        // Most directories already exist in the completed index. Record their ID directly in one
        // statement instead of rewriting/checking their parent and ownership on every full refresh.
        if try query(sql, values) == 0 {
            try ensureDirectory(path, ownerUID: uid)
            try query(sql, values)
        }
    }
    func nativeDirectoryFinished(_ path: String, direct: UInt64, bundle: String?, readable: Bool, items: UInt64, complete: Bool) throws {
        try query("UPDATE refresh_dirs SET direct=?,bundle=?,readable=?,items=?,complete=? WHERE id=(SELECT id FROM dirs WHERE path=?)",
            [.number(direct), .text(bundle ?? ""), .number(readable && complete ? 1 : 0), complete ? .number(items) : .optional(nil), .number(complete ? 1 : 0), .text(path)])
    }
    /// A bounded set avoids serializing a lookup for every folder in the parallel walk.
    /// Fall back to indexed lookups if the hard-link directory inventory exceeds the bound.
    func linkedDirectoryPaths(limit: Int) throws -> Set<String>? {
        var paths = Set<String>()
        try query("SELECT DISTINCT d.path FROM entries e JOIN dirs d ON d.id=e.parent WHERE e.link<>'' LIMIT ?", [.number(UInt64(limit + 1))]) {
            paths.insert(Self.text($0, 0))
        }
        return paths.count <= limit ? paths : nil
    }
    func hasKnownLink(_ key: String) throws -> Bool {
        try query("SELECT 1 FROM entries WHERE link=? AND link<>'' LIMIT 1", [.text(key)]) > 0
    }
    /// Stream changed hard-link families only when an unenumerated alias needs the same fresh physical measurement.
    private func refreshUnreadableLinks() throws {
        // Filter out enumerated aliases before joining on link. Otherwise a family with N
        // names can perform N² comparisons just to discover that every alias was enumerated.
        try execute("CREATE TEMP TABLE refresh_retained_links AS SELECT DISTINCT e.link,e.bytes,e.logical,e.uid,e.modified FROM entries e LEFT JOIN refresh_dirs r ON r.id=e.parent WHERE e.link<>'' AND r.complete IS NOT 1")
        defer { try? execute("DROP TABLE refresh_retained_links") }
        guard try query("SELECT 1 FROM refresh_retained_links LIMIT 1") > 0 else { return }
        try execute("CREATE INDEX refresh_retained_links_key ON refresh_retained_links(link)")
        var after = ""
        while true {
            var changed: [(String, DiskFile)] = []
            try query("SELECT s.link,s.bytes,s.logical,s.uid,s.modified FROM refresh_entries s JOIN refresh_dirs r ON r.id=s.parent AND r.complete=1 JOIN refresh_retained_links e ON e.link=s.link WHERE s.link<>'' AND s.link>? AND (e.bytes IS NOT s.bytes OR e.logical IS NOT s.logical OR e.uid IS NOT s.uid OR e.modified IS NOT s.modified) GROUP BY s.link ORDER BY s.link LIMIT 256", [.text(after)]) {
                let file = DiskFile(path: "", bytes: Self.number($0, 1), logicalBytes: Self.number($0, 2), ownerUID: Self.uid($0, 3),
                    modifiedAt: msc_sqlite3_column_type($0, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: msc_sqlite3_column_double($0, 4)))
                changed.append((Self.text($0, 0), file))
            }
            if changed.isEmpty { break }
            for (key, file) in changed {
                try updateLink(file, link: key)
                // Keep a family consistent when a file changed during parallel enumeration.
                try query("UPDATE refresh_entries SET bytes=?,logical=?,uid=?,modified=? WHERE link=? AND link<>''",
                    [.number(file.bytes), .number(file.logicalBytes), .optional(file.ownerUID), .date(file.modifiedAt), .text(key)])
            }
            after = changed.last!.0
            try Task.checkCancellation()
        }
    }
    func finishNativeRefresh(cancelled: () -> Bool, progress: ((Double) -> Void)? = nil) throws -> Bool {
        let started = Date()
        if cancelled() { throw CancellationError() }
        try resolvePendingParents()
        let changedBundle = try query("SELECT 1 FROM refresh_dirs r JOIN dirs d ON d.id=r.id WHERE r.complete=1 AND COALESCE(d.bundle,'') IS NOT r.bundle LIMIT 1") > 0
        // A missing child is conclusive only when its parent was completely listed. Unreadable descendants stay cached.
        var lastMissingID: UInt64 = 0
        while true {
            var missing: [String] = []
            try query("SELECT d.id,d.path FROM dirs d CROSS JOIN refresh_dirs p ON p.id=d.parent AND p.complete=1 LEFT JOIN refresh_dirs seen ON seen.id=d.id WHERE d.id>? AND seen.id IS NULL ORDER BY d.id LIMIT 256", [.number(lastMissingID)]) {
                lastMissingID = Self.number($0, 0)
                missing.append(Self.text($0, 1))
            }
            if missing.isEmpty { break }
            for path in missing { try remove(path, markAffectedTotals: false) }
            if cancelled() { throw CancellationError() }
            try Task.checkCancellation()
        }
        DiskScanMetrics.phase("native-missing-branches", since: started)
        let linksStarted = Date()
        try refreshUnreadableLinks()
        DiskScanMetrics.phase("native-retained-links", since: linksStarted)
        progress?(0.2)
        let mergeStarted = Date()
        // Drive both sides of the merge in primary-key order. The staged rows for a complete
        // directory are independent once retained aliases have received their updated allocation.
        var count: UInt64 = 0
        try query("SELECT count(*) FROM refresh_dirs WHERE complete=1") { count = Self.number($0, 0) }
        var after: UInt64 = 0, done: UInt64 = 0
        while done < count {
            if cancelled() { throw CancellationError() }
            try Task.checkCancellation()
            var upper = after, directories: UInt64 = 0
            try query("SELECT id FROM refresh_dirs WHERE id>? AND complete=1 ORDER BY id LIMIT 4096", [.number(after)]) {
                upper = Self.number($0, 0)
                directories += 1
            }
            guard directories > 0 else { break }
            let range: [Value] = [.number(after), .number(upper)]
            try query("DELETE FROM entries WHERE parent IN (SELECT id FROM refresh_dirs WHERE id>? AND id<=? AND complete=1) AND NOT EXISTS(SELECT 1 FROM refresh_entries s WHERE s.parent=entries.parent AND s.name=entries.name)", range)
            try query("INSERT INTO entries SELECT s.* FROM refresh_entries s WHERE s.parent>? AND s.parent<=? AND (SELECT complete FROM refresh_dirs WHERE id=s.parent)=1 ORDER BY s.parent,s.name ON CONFLICT(parent,name) DO UPDATE SET bytes=excluded.bytes,logical=excluded.logical,uid=excluded.uid,link=excluded.link,category=excluded.category,modified=excluded.modified,kind=excluded.kind,inventory=excluded.inventory WHERE entries.bytes IS NOT excluded.bytes OR entries.logical IS NOT excluded.logical OR entries.uid IS NOT excluded.uid OR entries.link IS NOT excluded.link OR entries.category IS NOT excluded.category OR entries.modified IS NOT excluded.modified OR entries.kind IS NOT excluded.kind OR entries.inventory IS NOT excluded.inventory", range)
            done += directories
            after = upper
            progress?(0.2 + 0.7 * Double(done) / Double(count))
        }
        if cancelled() { throw CancellationError() }
        try Task.checkCancellation()
        DiskScanMetrics.phase("native-entry-merge", since: mergeStarted)
        try execute("UPDATE dirs SET direct=r.direct,bundle=r.bundle,readable=r.readable,uid=COALESCE(r.uid,dirs.uid),items=r.items FROM refresh_dirs r WHERE dirs.id=r.id AND r.complete=1 AND (dirs.direct IS NOT r.direct OR COALESCE(dirs.bundle,'') IS NOT r.bundle OR dirs.readable IS NOT r.readable OR dirs.uid IS NOT COALESCE(r.uid,dirs.uid) OR dirs.items IS NOT r.items)")
        try execute("UPDATE dirs SET readable=0 WHERE id IN (SELECT id FROM refresh_dirs WHERE complete=0) AND readable<>0")
        try execute("DROP TABLE refresh_entries; DROP TABLE refresh_dirs")
        progress?(1)
        return changedBundle
    }
}
