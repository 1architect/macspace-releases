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
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS candidates(path TEXT PRIMARY KEY,bytes INTEGER,data BLOB,link TEXT UNIQUE,digest BLOB) WITHOUT ROWID")
        try db.execute("CREATE INDEX IF NOT EXISTS temp.candidate_digest ON candidates(digest,path)")
        try db.execute("DELETE FROM selected_scopes")
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS scope_conflicts(scope TEXT PRIMARY KEY) WITHOUT ROWID")
        try db.execute("CREATE TABLE IF NOT EXISTS preflight_files(token TEXT,path TEXT,data BLOB,PRIMARY KEY(token,path)) WITHOUT ROWID; DELETE FROM preflight_files")
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
        var count: UInt64 = 0, bytes: UInt64 = 0, checked: [String] = [], all: [String] = [], partial: [String] = []
        try db.query("SELECT count,bytes FROM selected_versions WHERE token=?", [.text(token)]) { count = DiskDatabase.number($0, 0); bytes = DiskDatabase.number($0, 1) }
        for id in visible { if try selected(path(id), at: revision, db: db) { checked.append(id) } }
        for scope in sections {
            var missing = false, known = false
            try db.query("SELECT 1 FROM selected_scopes WHERE scope=? LIMIT 1", [.text(scope)]) { _ in known = true }
            try db.query("SELECT 1 FROM selected_scopes s WHERE scope=? AND NOT EXISTS (SELECT 1 FROM selected_rows r WHERE r.path=s.path AND r.first<=? AND (r.last IS NULL OR r.last>?)) LIMIT 1", [.text(scope), .number(revision), .number(revision)]) { _ in missing = true }
            let conflict = try db.query("SELECT 1 FROM scope_conflicts WHERE scope=?", [.text(scope)]) > 0
            if known && !missing && !conflict { all.append(scope) }
            else if known, try db.query("SELECT 1 FROM selected_scopes s JOIN selected_rows r ON r.path=s.path WHERE scope=? AND r.first<=? AND (r.last IS NULL OR r.last>?) LIMIT 1", [.text(scope), .number(revision), .number(revision)]) > 0 { partial.append(scope) }
        }
        return .init(token: token, count: count, bytes: bytes, checked: checked, all: all, partialScopes: partial)
    }
    private func survivorProof(_ file: DiskFile, source: DiskDatabase, db: DiskDatabase, revision: UInt64,
                               cache: inout [Data: DiskDuplicateVerification]) throws -> DiskDuplicateVerification? {
        guard let evidence = file.duplicateVerification else { return nil }
        if let known = cache[evidence.digest], let identity = file.identity,
           FileReviewIdentity(known.keeper) == known.keeperIdentity, source.duplicateEligibility.allows(known.keeper),
           try source.ownershipEvidence(known.keeper) == nil, try !selected(known.keeper, at: revision, db: db) {
            return .init(path: file.path, identity: identity, keeper: known.keeper, keeperIdentity: known.keeperIdentity, digest: evidence.digest)
        }
        let proof = try source.duplicateVerification(file.path, isSelected: { try self.selected($0, at: revision, db: db) })
        if let proof { cache[evidence.digest] = proof }
        return proof
    }
    private func validatedSummary(token: String, request: SelectionBulkRequest, source: DiskDatabase) throws -> SelectionBulk {
        var result = try summary(token: token, visible: request.visible, sections: request.sections)
        let db = try database(), revision = try version(token, db: db)
        var after = ""
        while true {
            let batch = try files(token: token, after: after, limit: 200)
            guard let last = batch.last else { break }
            let open = OpenFileUse.inspect(Set(batch.map(\.path)))
            var survivors: [Data: DiskDuplicateVerification] = [:]
            for original in batch {
                if let readers = open[original.path], !readers.isEmpty {
                    let reason = loc("Open in \(readers.map(\.process).sorted().joined(separator: ", "))")
                    result.unavailableReason = reason
                    result.issues = [.init(id: DiskFileRemoval.id(original.path), title: (original.path as NSString).lastPathComponent, path: original.path, bytes: original.bytes, reason: reason)]
                    return result
                }
                guard FileReviewIdentity(original.path) == original.identity else {
                    let reason = loc("Selected files changed or are unavailable. Review your selection again.")
                    result.unavailableReason = reason
                    result.issues = [.init(id: DiskFileRemoval.id(original.path), title: (original.path as NSString).lastPathComponent,
                        path: original.path, bytes: original.bytes, reason: reason)]
                    return result
                }
                if original.duplicateVerification != nil {
                    let current = try source.reviewedFile(original)
                    let survivor = try survivorProof(current, source: source, db: db, revision: revision, cache: &survivors)
                    if survivor == nil {
                        let reason = loc("Leave at least one verified copy of each duplicate set unselected.")
                        result.unavailableReason = reason
                        result.issues = [.init(id: DiskFileRemoval.id(original.path), title: (original.path as NSString).lastPathComponent,
                            path: original.path, bytes: original.bytes, reason: reason)]
                        return result
                    }
                }
            }
            after = last.path
        }
        return result
    }
    func resolved(_ files: [DiskFile], token: String, sourceURL: URL) throws -> [DiskFile] {
        let db = try database(), revision = try version(token, db: db)
        let source = try DiskDatabase(url: sourceURL, root: root, home: home)
        var survivors: [Data: DiskDuplicateVerification] = [:]
        return try files.map { original in
            var file = original
            if original.duplicateVerification != nil {
                let current = try source.reviewedFile(original)
                guard let proof = try survivorProof(current, source: source, db: db, revision: revision, cache: &survivors),
                      original.duplicateVerification.map({ $0.digest == proof.digest }) != false else {
                    throw DiskDatabase.Failure(message: loc("Leave at least one verified copy of each duplicate set unselected."))
                }
                file.duplicateVerification = proof
            }
            return file
        }
    }
    func pin(token: String) throws { _ = try version(token, db: database()); pinned.insert(token) }
    func unpin(token: String) {
        pinned.remove(token)
        if let storage { try? storage.query("DELETE FROM preflight_files WHERE token=?", [.text(token)]) }
    }
    func recordPreflight(_ files: [DiskFile], token: String) throws {
        let db = try database(); _ = try version(token, db: db)
        guard pinned.contains(token) else { throw DiskDatabase.Failure(message: "Selection is not locked for removal.") }
        try db.transaction {
            for file in files { try db.query("INSERT OR REPLACE INTO preflight_files VALUES(?,?,?)", [.text(token), .text(file.path), .data(try JSONEncoder().encode(file))]) }
        }
    }
    func executionFiles(_ files: [DiskFile], token: String) throws -> [DiskFile] {
        let policy = DiskDuplicateEligibility(home: home)
        let db = try database(); _ = try version(token, db: db)
        guard pinned.contains(token) else { throw DiskDatabase.Failure(message: "Selection is not locked for removal.") }
        return try files.map { original in
            var reviewed: DiskFile?
            try db.query("SELECT data FROM preflight_files WHERE token=? AND path=?", [.text(token), .text(original.path)]) {
                reviewed = try JSONDecoder().decode(DiskFile.self, from: DiskDatabase.data($0, 0))
            }
            guard let reviewed, reviewed.identity == original.identity else { throw DiskDatabase.Failure(message: "Selected files changed. Review them again.") }
            if let proof = reviewed.duplicateVerification {
                guard policy.allows(reviewed.path), policy.allows(proof.keeper) else { throw DiskDatabase.Failure(message: loc("Project resources are excluded from duplicate cleanup.")) }
            }
            return reviewed
        }
    }
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
    private func candidates(_ request: DiskBrowseRequest, source: DiskDatabase, db: DiskDatabase, at revision: UInt64) throws -> Bool {
        try db.execute("DELETE FROM candidates")
        try source.streamScope(request) { try stage($0, db: db) }
        guard request.kind == .duplicates else { return false }
        var after = Data(), conflict = false
        while true {
            var digests: [Data] = []
            try db.query("SELECT DISTINCT digest FROM candidates WHERE digest>? ORDER BY digest LIMIT 32", [.data(after)]) { digests.append(DiskDatabase.data($0, 0)) }
            guard let last = digests.last else { break }
            for digest in digests {
                let survivor = try source.duplicateHeaderSurvivor(digest,
                    isSelected: { try self.selected($0, at: revision, db: db) },
                    isCandidate: { try db.query("SELECT 1 FROM candidates WHERE path=?", [.text($0)]) > 0 })
                if let survivor { try db.query("DELETE FROM candidates WHERE path=?", [.text(survivor)]) }
                else { conflict = true }
            }
            after = last
        }
        return conflict
    }
    private func scopes(_ sections: [String], token: String, source: DiskDatabase, db: DiskDatabase) throws {
        let revision = try source.state()?.revision ?? 0, selectionVersion = try version(token, db: db)
        for scope in sections {
            guard let request = DiskBrowseRequest(id: scope.hasPrefix("select:") ? String(scope.dropFirst(7)) : scope) else { continue }
            var cached = false
            if request.kind != .duplicates {
                try db.query("SELECT 1 FROM scope_stamps WHERE scope=? AND revision=? AND created>?", [.text(scope), .number(revision), .date(Date().addingTimeInterval(-30))]) { _ in cached = true }
            }
            if cached { continue }
            try db.transaction {
                let conflict = try candidates(request, source: source, db: db, at: selectionVersion)
                try db.query("DELETE FROM selected_scopes WHERE scope=?", [.text(scope)])
                try db.query("INSERT INTO selected_scopes SELECT ?,path FROM candidates", [.text(scope)])
                try db.query("DELETE FROM scope_conflicts WHERE scope=?", [.text(scope)])
                if conflict { try db.query("INSERT INTO scope_conflicts VALUES(?)", [.text(scope)]) }
                try db.query("INSERT OR REPLACE INTO scope_stamps VALUES(?,?,?)", [.text(scope), .number(revision), .date(Date())])
            }
        }
    }
    func apply(_ request: SelectionBulkRequest, sourceURL: URL) throws -> SelectionBulk {
        let db = try database()
        accepted = request.token
        guard ["read", "membership"].contains(request.operation) || pinned.isEmpty else { throw DiskDatabase.Failure(message: "File removal is using this selection. Wait for it to finish.") }
        guard ["read", "membership", "toggle", "toggleAll"].contains(request.operation) else { throw DiskDatabase.Failure(message: "Invalid selection operation.") }
        if request.operation == "membership", let token = request.token {
            return try summary(token: token, visible: request.visible, sections: request.sections)
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw DiskDatabase.Failure(message: "Disk inventory changed. Refresh and try again.") }
        let source = try DiskDatabase(url: sourceURL, root: root, home: home), next = try nextVersion(db)
        guard try source.state() != nil else { throw DiskDatabase.Failure(message: "Disk inventory is incomplete. Wait for the scan to finish.") }
        if request.operation == "read", let token = request.token {
            try scopes(request.sections, token: token, source: source, db: db)
            return try validatedSummary(token: token, request: request, source: source)
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
                    _ = try candidates(browse, source: source, db: db, at: next)
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
        try scopes(request.sections, token: token, source: source, db: db)
        try db.checkpoint(); return try validatedSummary(token: token, request: request, source: source)
    }
    private func insert(_ file: DiskFile, at revision: UInt64, db: DiskDatabase) throws {
        try db.query("INSERT INTO selected_rows VALUES(?,?,NULL,?,?)", [.text(file.path), .number(revision), .number(file.bytes), .data(try JSONEncoder().encode(file))])
    }
    private func stage(_ file: DiskFile, db: DiskDatabase) throws {
        try Task.checkCancellation()
        guard let identity = file.identity else { return }
        try db.query("INSERT INTO candidates VALUES(?,?,?,?,?) ON CONFLICT(link) DO UPDATE SET path=excluded.path,bytes=excluded.bytes,data=excluded.data,digest=excluded.digest WHERE excluded.path<candidates.path", [.text(file.path), .number(file.bytes), .data(try JSONEncoder().encode(file)), .text("\(identity.device):\(identity.inode)"), file.duplicateVerification.map { .data($0.digest) } ?? .optional(nil)])
    }
}

extension DiskDatabase {
    /// Full scope streaming is independent of the bounded browse cache. No item-count or elapsed-time truncation.
    func streamScope(_ request: DiskBrowseRequest, visit: (DiskFile) throws -> Void) throws {
        guard request.kind != .managed, Self.contains(request.folder, below: root), try directory(request.folder) != nil else { throw Failure(message: "Invalid selection scope.") }
        var pending: [DiskFile] = []
        func flush() throws {
            let open = OpenFileUse.inspect(Set(pending.map(\.path)))
            for file in pending where open[file.path]?.isEmpty != false { try visit(file) }
            pending.removeAll(keepingCapacity: true)
        }
        func emit(_ file: DiskFile) throws { pending.append(file); if pending.count == 200 { try flush() } }
        if request.kind == .duplicates {
            try streamDuplicateScope(request) { try emit($0) }
            try flush(); return
        }
        if !request.usesMetadataInventory {
            guard let filter = browseFilter(request) else { throw Failure(message: "This selection scope is unavailable.") }
            try query("SELECT path,bytes,logical,uid,modified FROM file_details f WHERE " + filter.0 + " AND " + countedDetails + " ORDER BY category,parent,logical DESC,path", filter.1) {
                try Task.checkCancellation()
                let file = try decodeDetail($0)
                guard file.identity != nil, inventoryIncludes(file.path), try ownershipEvidence(file.path) == nil else { return }
                try emit(file)
            }
            try flush(); return
        }
        var after = ""
        while true {
            let folders = try reviewFolders(request, after: after, limit: 128)
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
                        if let type = request.fileType, DiskFileType.key(path) != type { return }
                        let file = try reviewedFile(.init(path: path, bytes: entry.allocatedBytes, logicalBytes: entry.logicalBytes, ownerUID: entry.ownerUID, modifiedAt: entry.modifiedAt), duplicateEvidence: false)
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
