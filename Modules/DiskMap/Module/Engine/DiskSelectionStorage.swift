import Foundation
import MacSpaceSdk
import Darwin
import MacSpacePlatform

extension DiskDatabase {
    func prepareBrowseMetadata(progress: LoadProgressSink? = nil) throws {
        var metadata = try state() ?? DiskIndex(root: root)
        metadata.browseVersion = DiskIndex.browseSchemaVersion
        metadata.summaryVersion = DiskIndex.summarySchemaVersion
        metadata.storageRevision = 4
        try saveState(metadata); progress?(1)
    }
}

/// Selection versions retain original review evidence on disk. Swift holds only a bounded page at a time.
actor DiskSelectionStorage {
    private let url: URL
    private let root: String
    private let home: String
    private var storage: DiskDatabase?
    private var pinned = Set<String>()
    private var accepted: String?
    init(url: URL, root: String, home: String) { self.url = url; self.root = root; self.home = home }
    private func database() throws -> DiskDatabase {
        if let storage { return storage }
        let db = try DiskDatabase(url: url, root: root, home: home)
        try db.execute("CREATE TABLE IF NOT EXISTS selected_versions(token TEXT PRIMARY KEY,version INTEGER UNIQUE,count INTEGER,bytes INTEGER,created REAL) WITHOUT ROWID")
        try db.execute("CREATE TABLE IF NOT EXISTS selected_rows(path TEXT,first INTEGER,last INTEGER,bytes INTEGER,data BLOB,PRIMARY KEY(path,first)) WITHOUT ROWID")
        try db.execute("CREATE INDEX IF NOT EXISTS selected_end ON selected_rows(last)")
        try db.execute("CREATE INDEX IF NOT EXISTS selected_start ON selected_rows(first)")
        try db.execute("CREATE TABLE IF NOT EXISTS removed_selection(token TEXT,path TEXT,PRIMARY KEY(token,path)) WITHOUT ROWID")
        try db.execute("DELETE FROM selected_versions; DELETE FROM selected_rows; DELETE FROM removed_selection")
        try db.execute("CREATE TABLE IF NOT EXISTS selected_scopes(scope TEXT,path TEXT,PRIMARY KEY(scope,path)) WITHOUT ROWID")
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS scope_stamps(scope TEXT PRIMARY KEY,revision INTEGER,created REAL) WITHOUT ROWID")
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS candidates(path TEXT PRIMARY KEY,bytes INTEGER,data BLOB,link TEXT UNIQUE) WITHOUT ROWID")
        try db.execute("DELETE FROM selected_scopes")
        storage = db; return db
    }
    private func version(_ token: String, db: DiskDatabase) throws -> UInt64 {
        var result: UInt64?
        try db.query("SELECT version FROM selected_versions WHERE token=?", [.text(token)]) { result = DiskDatabase.number($0, 0) }
        guard let result else { throw DiskDatabase.Failure(message: "This selection expired. Review the files again.") }; return result
    }
    private func selected(_ path: String, at version: UInt64, db: DiskDatabase) throws -> Bool {
        try db.query("SELECT 1 FROM selected_rows WHERE path=? AND first<=? AND (last IS NULL OR last>?)", [.text(path), .number(version), .number(version)]) > 0
    }
    private func path(_ id: String) throws -> String {
        guard id.hasPrefix("file:"), let data = Data(base64Encoded: String(id.dropFirst(5))), let path = String(data: data, encoding: .utf8), DiskDatabase.contains(path, below: root) else { throw DiskDatabase.Failure(message: "Invalid selection.") }; return path
    }
    func files(token: String, after: String, limit: Int) throws -> [DiskFile] {
        let db = try database(), revision = try version(token, db: db)
        var result: [DiskFile] = []
        let boundedLimit = UInt64(max(1, min(limit, 200)))
        try db.query("SELECT data FROM selected_rows WHERE path>? AND first<=? AND (last IS NULL OR last>?) ORDER BY path LIMIT ?", [.text(after), .number(revision), .number(revision), .number(boundedLimit)]) {
            result.append(try JSONDecoder().decode(DiskFile.self, from: DiskDatabase.data($0, 0)))
        }
        return result
    }
    func contains(token: String, path: String) throws -> Bool { let db = try database(); return try selected(path, at: version(token, db: db), db: db) }
    func summary(token: String, visible: [String] = [], sections: [String] = []) throws -> SelectionBulk {
        let db = try database(), revision = try version(token, db: db)
        var count: UInt64 = 0, bytes: UInt64 = 0, checked: [String] = [], all: [String] = []
        try db.query("SELECT count,bytes FROM selected_versions WHERE token=?", [.text(token)]) { count = DiskDatabase.number($0, 0); bytes = DiskDatabase.number($0, 1) }
        for id in visible { if try selected(path(id), at: revision, db: db) { checked.append(id) } }
        for scope in sections {
            var missing = false, known = false
            try db.query("SELECT 1 FROM selected_scopes WHERE scope=? LIMIT 1", [.text(scope)]) { _ in known = true }
            try db.query("SELECT 1 FROM selected_scopes s WHERE scope=? AND NOT EXISTS (SELECT 1 FROM selected_rows r WHERE r.path=s.path AND r.first<=? AND (r.last IS NULL OR r.last>?)) LIMIT 1", [.text(scope), .number(revision), .number(revision)]) { _ in missing = true }
            if known && !missing { all.append(scope) }
        }
        return .init(token: token, count: count, bytes: bytes, checked: checked, all: all)
    }
    func pin(token: String) throws { _ = try version(token, db: database()); pinned.insert(token) }
    func unpin(token: String) { pinned.remove(token) }
    private func publish(version: UInt64, db: DiskDatabase) throws -> String {
        let token = UUID().uuidString
        var count: UInt64 = 0, bytes: UInt64 = 0, added: UInt64 = 0, addedBytes: UInt64 = 0, removed: UInt64 = 0, removedBytes: UInt64 = 0
        try db.query("SELECT count,bytes FROM selected_versions ORDER BY version DESC LIMIT 1") { count = DiskDatabase.number($0, 0); bytes = DiskDatabase.number($0, 1) }
        try db.query("SELECT COUNT(*),COALESCE(SUM(bytes),0) FROM selected_rows WHERE first=? AND last IS NULL", [.number(version)]) { added = DiskDatabase.number($0, 0); addedBytes = DiskDatabase.number($0, 1) }
        try db.query("SELECT COUNT(*),COALESCE(SUM(bytes),0) FROM selected_rows WHERE last=? AND first<?", [.number(version), .number(version)]) { removed = DiskDatabase.number($0, 0); removedBytes = DiskDatabase.number($0, 1) }
        guard count + added >= removed, bytes + addedBytes >= removedBytes else { throw DiskDatabase.Failure(message: "Selection totals are inconsistent. Review the files again.") }
        try db.query("INSERT INTO selected_versions VALUES(?,?,?,?,?)", [.text(token), .number(version), .number(count + added - removed), .number(bytes + addedBytes - removedBytes), .date(Date())])
        // Historical confirmations remain immutable; only old, unreferenced versions are disposable.
        var expired: [String] = []
        try db.query("SELECT token FROM selected_versions ORDER BY version DESC LIMIT -1 OFFSET 2") {
            let token = DiskDatabase.text($0, 0)
            if token != accepted && !pinned.contains(token) { expired.append(token) }
        }
        for token in expired { try db.query("DELETE FROM selected_versions WHERE token=?", [.text(token)]) }
        try db.execute("DELETE FROM selected_rows WHERE last IS NOT NULL AND last<=(SELECT MIN(version) FROM selected_versions)")
        return token
    }
    private func nextVersion(_ db: DiskDatabase) throws -> UInt64 {
        var value: UInt64 = 0
        try db.query("SELECT COALESCE(MAX(version),0)+1 FROM selected_versions") { value = DiskDatabase.number($0, 0) }; return value
    }
    /// A rejected late UI reply may have committed. Restore the ACCEPTED immutable base before a new delta.
    private func restore(_ previous: UInt64, next: UInt64, db: DiskDatabase) throws {
        guard previous + 1 != next else { return }
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS selection_restore(path TEXT PRIMARY KEY,bytes INTEGER,data BLOB) WITHOUT ROWID; DELETE FROM selection_restore")
        try db.query("INSERT INTO selection_restore SELECT path,bytes,data FROM selected_rows WHERE first<=? AND (last IS NULL OR last>?)", [.number(previous), .number(previous)])
        try db.query("UPDATE selected_rows SET last=? WHERE last IS NULL AND NOT EXISTS (SELECT 1 FROM selection_restore s WHERE s.path=selected_rows.path AND s.data=selected_rows.data)", [.number(next)])
        try db.query("INSERT INTO selected_rows SELECT path,?,NULL,bytes,data FROM selection_restore s WHERE NOT EXISTS (SELECT 1 FROM selected_rows r WHERE r.path=s.path AND r.last IS NULL)", [.number(next)])
    }
    func recordRemoved(token: String, paths: [String]) throws {
        let db = try database(); _ = try version(token, db: db)
        try db.transaction {
            for path in paths { try db.query("INSERT OR IGNORE INTO removed_selection VALUES(?,?)", [.text(token), .text(path)]) }
        }
    }
    func removing(token: String, paths: [String]) throws -> SelectionBulk {
        let db = try database(), previous = try version(token, db: db), next = try nextVersion(db)
        var result = ""
        try db.transaction {
            accepted = token
            try restore(previous, next: next, db: db)
            for path in paths { try db.query("INSERT OR IGNORE INTO removed_selection VALUES(?,?)", [.text(token), .text(path)]) }
            try db.query("UPDATE selected_rows SET last=? WHERE last IS NULL AND path IN (SELECT path FROM removed_selection WHERE token=?)", [.number(next), .text(token)])
            result = try publish(version: next, db: db)
        }
        try db.checkpoint(); return try summary(token: result)
    }
    private func scopes(_ sections: [String], source: DiskDatabase, db: DiskDatabase) throws {
        let revision = try source.state()?.revision ?? 0
        for scope in sections {
            guard let request = DiskBrowseRequest(id: scope.hasPrefix("select:") ? String(scope.dropFirst(7)) : scope) else { continue }
            var cached = false
            try db.query("SELECT 1 FROM scope_stamps WHERE scope=? AND revision=? AND created>?", [.text(scope), .number(revision), .date(Date().addingTimeInterval(-30))]) { _ in cached = true }
            if cached { continue }
            try db.transaction {
                try db.query("DELETE FROM selected_scopes WHERE scope=?", [.text(scope)])
                try source.streamScope(request) { file in try db.query("INSERT OR IGNORE INTO selected_scopes VALUES(?,?)", [.text(scope), .text(file.path)]) }
                try db.query("INSERT OR REPLACE INTO scope_stamps VALUES(?,?,?)", [.text(scope), .number(revision), .date(Date())])
            }
        }
    }
    func apply(_ request: SelectionBulkRequest, sourceURL: URL) throws -> SelectionBulk {
        let db = try database()
        accepted = request.token
        guard request.operation == "read" || pinned.isEmpty else { throw DiskDatabase.Failure(message: "File removal is using this selection. Wait for it to finish.") }
        guard ["read", "toggle", "toggleAll"].contains(request.operation) else { throw DiskDatabase.Failure(message: "Invalid selection operation.") }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw DiskDatabase.Failure(message: "Disk inventory changed. Refresh and try again.") }
        let source = try DiskDatabase(url: sourceURL, root: root, home: home), next = try nextVersion(db)
        guard try source.state() != nil else { throw DiskDatabase.Failure(message: "Disk inventory is incomplete. Wait for the scan to finish.") }
        if request.operation == "read", let token = request.token {
            try scopes(request.sections, source: source, db: db)
            return try summary(token: token, visible: request.visible, sections: request.sections)
        }
        let previous = try request.token.map { try version($0, db: db) } ?? 0
        var token = ""
        try db.transaction {
            if request.token != nil { try restore(previous, next: next, db: db) }
            if request.token == nil {
                try db.query("UPDATE selected_rows SET last=? WHERE last IS NULL", [.number(next)])
                let ids = Set(request.ids)
                if !ids.isEmpty && !(request.operation == "toggleAll" && request.scopePageID == nil) {
                    guard let files = try source.selectedFiles(ids, folder: root, reviewed: request.reviewed, origins: request.origins) else { throw DiskDatabase.Failure(message: "Selected files changed. Review them again.") }
                    for file in files { try insert(file, at: next, db: db) }
                }
            }
            try db.execute("DELETE FROM candidates")
            if request.operation == "toggleAll" {
                if let scope = request.scopePageID, let browse = DiskBrowseRequest(id: scope.hasPrefix("select:") ? String(scope.dropFirst(7)) : scope) {
                    try source.streamScope(browse) { try stage($0, db: db) }
                    try db.query("DELETE FROM selected_scopes WHERE scope=?", [.text(scope)])
                    try db.query("INSERT INTO selected_scopes SELECT ?,path FROM candidates", [.text(scope)])
                    try db.query("INSERT OR REPLACE INTO scope_stamps VALUES(?,?,?)", [.text(scope), .number(try source.state()?.revision ?? 0), .date(Date())])
                } else {
                    guard let files = try source.selectedFiles(Set(request.ids), folder: root, reviewed: request.reviewed, origins: request.origins) else { throw DiskDatabase.Failure(message: "Selected files changed. Review them again.") }
                    for file in files { try stage(file, db: db) }
                }
            } else if request.operation == "toggle", let id = request.toggledID {
                let path = try path(id)
                if try selected(path, at: request.token == nil ? next : previous, db: db) {
                    try db.query("SELECT data FROM selected_rows WHERE path=? AND last IS NULL", [.text(path)]) { try stage(JSONDecoder().decode(DiskFile.self, from: DiskDatabase.data($0, 0)), db: db) }
                } else {
                    guard let file = try source.selectedFiles([id], folder: root, reviewed: request.reviewed, origins: request.origins)?.first else { throw DiskDatabase.Failure(message: "The file changed. Review it again.") }; try stage(file, db: db)
                }
            }
            if request.operation != "read" {
                let uncovered = try db.query("SELECT 1 FROM candidates c WHERE NOT EXISTS (SELECT 1 FROM selected_rows r WHERE r.path=c.path AND r.last IS NULL) LIMIT 1")
                if uncovered == 0 { try db.query("UPDATE selected_rows SET last=? WHERE last IS NULL AND path IN (SELECT path FROM candidates)", [.number(next)]) }
                else { try db.query("INSERT INTO selected_rows SELECT path,?,NULL,bytes,data FROM candidates c WHERE NOT EXISTS (SELECT 1 FROM selected_rows r WHERE r.path=c.path AND r.last IS NULL)", [.number(next)]) }
            }
            token = try publish(version: next, db: db)
        }
        try scopes(request.sections, source: source, db: db)
        try db.checkpoint(); return try summary(token: token, visible: request.visible, sections: request.sections)
    }
    private func insert(_ file: DiskFile, at revision: UInt64, db: DiskDatabase) throws {
        try db.query("INSERT INTO selected_rows VALUES(?,?,NULL,?,?)", [.text(file.path), .number(revision), .number(file.bytes), .data(try JSONEncoder().encode(file))])
    }
    private func stage(_ file: DiskFile, db: DiskDatabase) throws {
        try Task.checkCancellation()
        guard !file.retainedDuplicateKeeper, let identity = file.identity else { return }
        try db.query("INSERT INTO candidates VALUES(?,?,?,?) ON CONFLICT(link) DO UPDATE SET path=excluded.path,bytes=excluded.bytes,data=excluded.data WHERE excluded.path<candidates.path", [.text(file.path), .number(file.bytes), .data(try JSONEncoder().encode(file)), .text("\(identity.device):\(identity.inode)")])
    }
}

extension DiskDatabase {
    /// Full scope streaming is independent of the bounded browse cache. No item-count or elapsed-time truncation.
    func streamScope(_ request: DiskBrowseRequest, visit: (DiskFile) throws -> Void) throws {
        guard Self.contains(request.folder, below: root), try directory(request.folder) != nil else { throw Failure(message: "Invalid selection scope.") }
        var pending: [DiskFile] = []
        func flush() throws {
            let open = OpenFileUse.inspect(Set(pending.map(\.path)))
            for file in pending where open[file.path]?.isEmpty != false { try visit(file) }
            pending.removeAll(keepingCapacity: true)
        }
        func emit(_ file: DiskFile) throws { pending.append(file); if pending.count == 200 { try flush() } }
        if request.kind == .duplicates {
            var cursor = request; cursor.afterPath = nil; cursor.afterSize = nil
            while true {
                try Task.checkCancellation()
                let page = try duplicatePage(cursor)
                for file in page.files { try emit(file) }
                guard let next = page.next else { break }; cursor = next
            }
            try flush(); return
        }
        if !request.includeSmaller && request.kind != .direct {
            guard let filter = browseFilter(request) else { throw Failure(message: "This selection scope is unavailable.") }
            try query("SELECT path,bytes,logical,uid,modified FROM file_details f WHERE " + filter.0 + " AND " + countedDetails + " ORDER BY category,parent,logical DESC,path", filter.1) {
                try Task.checkCancellation()
                let file = try decodeDetail($0)
                guard !file.retainedDuplicateKeeper else { return }
                guard file.identity != nil, inventoryIncludes(file.path), try ownershipEvidence(file.path) == nil else { throw Failure(message: "Files changed or ownership is uncertain. Review this scope again.") }
                try emit(file)
            }
            try flush(); return
        }
        var after = ""
        let prefix = request.folder == "/" ? "/" : request.folder + "/"
        while true {
            var folders: [String] = []
            try query("SELECT path FROM dirs WHERE (path=? OR (path>=? AND path<?)) AND path>? ORDER BY path LIMIT 128", [.text(request.folder), .text(prefix), .text(String(prefix.dropLast()) + "0"), .text(after)]) { folders.append(Self.text($0, 0)) }
            guard let last = folders.last else { break }
            for folder in folders {
                if let exact = request.selectionParent, folder != exact { continue }
                if request.kind == .direct, folder != request.folder { continue }
                guard inventoryIncludes(folder + "/candidate") else { continue }
                var failure: Error?, batch: [DiskFile] = []
                func flush() throws {
                    let open = OpenFileUse.inspect(Set(batch.map(\.path)))
                    for file in batch where open[file.path] == nil { try visit(file) }
                    batch.removeAll(keepingCapacity: true)
                }
                let complete = DirectoryWalk.entries(at: folder, includingModificationDate: true) { name, entry in
                    guard failure == nil else { return }
                    do {
                        try Task.checkCancellation()
                        let path = folder == "/" ? "/" + name : folder + "/" + name
                        guard entry.isRegularFile, !entry.isDataless, entry.allocatedBytes > 0, entry.ownerUID == getuid(), inventoryIncludes(path) else { return }
                        let category = DiskCategory.inventoryCategory(path)
                        if let type = request.largeType, type != category.rawValue { return }
                        if let selected = request.category, selected != .largeFiles, selected != category { return }
                        let file = try reviewedFile(.init(path: path, bytes: entry.allocatedBytes, logicalBytes: entry.logicalBytes, ownerUID: entry.ownerUID, modifiedAt: entry.modifiedAt))
                        guard !file.retainedDuplicateKeeper else { return }
                        guard file.identity != nil, try ownershipEvidence(path) == nil else { return }
                        batch.append(file)
                        if batch.count >= 200 { try flush() }
                    } catch { failure = error }
                }
                if let failure { throw failure }
                try flush()
                guard complete else { throw Failure(message: "This folder is unreadable. Its files were not added to the selection.") }
            }
            after = last
        }
        try flush()
    }
}
