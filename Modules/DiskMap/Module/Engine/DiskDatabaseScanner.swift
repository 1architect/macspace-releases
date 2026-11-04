import Foundation
import Darwin
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceDiskMapPrivileged

/// Native directory streaming writes directly into an on-disk transaction. No whole-disk Swift object graph exists.
struct DiskDatabaseScanner {
    let db: DiskDatabase
    let excluded: [String]
    var metadata: (String) -> stat? = { path in var info = stat(); return lstat(path, &info) == 0 ? info : nil }
    var cancelled: @Sendable () -> Bool = { false }
    private var devices = Set<dev_t>()
    private var catalogChanged = false
    private var report: LoadProgressSink?
    private var entries = 0
    private(set) var visited = 0
    init(db: DiskDatabase, excluded: [String]) { self.db = db; self.excluded = excluded }
    mutating func scan(_ changes: DiskEvents.Changes, cursor: UInt64, progress: LoadProgressSink?) throws {
        if cancelled() { throw CancellationError() }
        // Bounded batches may survive a cancelled first walk. Only a committed state record proves completion.
        if try db.state() == nil { try db.clearIncomplete() }
        if let info = metadata(db.root) { devices.insert(info.st_dev) }
        if db.root == "/", let info = metadata(DataVolume.path) { devices.insert(info.st_dev) }
        let started = Date()
        report = progress
        defer { report = nil }
        try db.transaction {
            var state = try db.state() ?? DiskIndex(root: db.root)
            let initial = try db.directory(db.root) == nil
            let recursive = initial ? [db.root] : changes.recursive.sorted { $0.count < $1.count }
            var covered: [String] = []
            progress?(0)
            if initial {
                try db.beginInitialCollection()
                let walkStarted = Date()
                try initialScan()
                db.phase?("walk", Date().timeIntervalSince(walkStarted), visited)
                let indexStarted = Date()
                try db.createIndexes(progress: { progress?(0.7 + 0.1 * $0) })
                db.phase?("indexes", Date().timeIntervalSince(indexStarted), visited)
                covered = [db.root]
            } else {
                for path in recursive where !covered.contains(where: { DiskDatabase.contains(path, below: $0) }) {
                    try read(path, recursive: true); covered.append(path)
                }
            }
            let shallow = changes.shallow.filter { path in !covered.contains(where: { DiskDatabase.contains(path, below: $0) }) }.sorted()
            for (n, path) in shallow.enumerated() { try read(path, recursive: false); progress?(0.8 * Double(n + 1) / Double(max(shallow.count, 1))) }
            let totalsStarted = Date()
            try db.reconcileTotals(all: initial, progress: { progress?(0.8 + 0.19 * $0) })
            db.phase?("totals", Date().timeIntervalSince(totalsStarted), visited)
            if initial { state.storageRevision = 4; state.personalInventoryVersion = DiskIndex.personalInventorySchemaVersion }
            state.eventID = cursor; state.revision += 1
            if initial || changes.recursive.contains(db.root) {
                state.browseVersion = DiskIndex.browseSchemaVersion; state.summaryVersion = DiskIndex.summarySchemaVersion
            }
            if initial || catalogChanged || state.catalogRevision == nil { state.catalogRevision = (state.catalogRevision ?? 0) + 1 }
            if db.root == "/" || db.root == DataVolume.path,
               let values = try? URL(fileURLWithPath: DataVolume.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]), let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage {
                state.volumeUsed = UInt64(max(0, Int64(total) - free))
            }
            try db.saveState(state)
            progress?(1)
        }
        try db.checkpoint()
        db.phase?("scan", Date().timeIntervalSince(started), visited)
    }
    private static func bundleIdentifier(_ path: String, parent: String, entry: DirectoryWalk.Entry) -> String? {
        guard path.hasSuffix("/Info.plist"), entry.logicalBytes <= 1_048_576,
              parent.hasSuffix("/Contents") || parent.hasSuffix("/Resources") || ["app", "appex", "xpc", "bundle", "framework", "plugin"].contains((parent as NSString).pathExtension),
              let id = autoreleasepool(invoking: { NSDictionary(contentsOfFile: path)?["CFBundleIdentifier"] as? String }), AppOwner.validIdentifier(id) else { return nil }
        return id
    }

    /// Filesystem waits overlap across eight existing native workers; SQLite still has one writer.
    private mutating func initialScan() throws {
        struct Totals {
            var bytes: UInt64 = 0; var items: UInt64 = 0; var bundle: String?; var readable = true
            var files: [(DiskFile, String)] = []
            var folders: [DiskDirectory] = []
        }
        let db = db, metadata = metadata, devices = devices, excluded = excluded, report = report, cancelled = cancelled
        guard let info = metadata(db.root) else { throw DiskDatabase.Failure(message: "The scan root is unreadable") }
        try db.put(DiskDirectory(path: db.root, ownerUID: info.st_uid))
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else {
            try db.query("UPDATE dirs SET readable=0 WHERE path=?", [.text(db.root)]); return
        }
        let lock = NSLock()
        var failure: Error?, count = 0, directories = 0
        func writing(_ work: () throws -> Void) {
            lock.withLock {
                guard failure == nil else { return }
                do { if cancelled() { throw CancellationError() }; try Task.checkCancellation(); try work(); try db.flushBatch() }
                catch { failure = error }
            }
        }
        func flush(_ totals: inout Totals) {
            writing {
                for node in totals.folders { try db.ensureDirectory(node.path, ownerUID: node.ownerUID) }
                for (file, link) in totals.files {
                    try db.put(file, link: link)
                    count += 1
                }
                report?(0.7 * Double(count) / Double(count + 100_000))
            }
            totals.files.removeAll(keepingCapacity: true); totals.folders.removeAll(keepingCapacity: true)
        }
        DirectoryWalk.scan(db.root, devices: devices, pool: ScanPool(free: 7), makeState: { Totals() }, visit: { totals, makePath, entry in
            totals.items += 1
            let path = makePath()
            if cancelled() { writing { throw CancellationError() }; return false }
            guard devices.contains(entry.device), !excluded.contains(where: { DiskDatabase.contains(path, below: $0) }) else { return false }
            if entry.isDirectory {
                guard !lock.withLock({ failure != nil }), let info = metadata(path), info.st_mode & S_IFMT == S_IFDIR else { return false }
                totals.folders.append(DiskDirectory(path: path, ownerUID: info.st_uid))
                if totals.folders.count >= 256 { flush(&totals) }
                return info.st_flags & UInt32(SF_DATALESS) == 0
            }
            guard entry.isRegularFile && !entry.isDataless else { return false }
            let parent = DiskDatabase.parent(path)
            let identity = entry.linkCount > 1 ? metadata(path) : nil
            let link = identity.map { "\($0.st_dev):\($0.st_ino)" } ?? ""
            if entry.linkCount > 1 && identity == nil { totals.readable = false }
            let file = DiskFile(path: path, bytes: entry.allocatedBytes, logicalBytes: entry.logicalBytes, ownerUID: entry.ownerUID, modifiedAt: entry.modifiedAt)
            if link.isEmpty { totals.bytes += file.bytes }
            if let id = Self.bundleIdentifier(path, parent: parent, entry: entry) { totals.bundle = id }
            totals.files.append((file, link))
            if totals.files.count >= 256 { flush(&totals) }
            return false
        }, finished: { totals, path, complete in
            flush(&totals)
            writing {
                try db.ensureDirectory(path)
                try db.query("UPDATE dirs SET direct=?,bundle=?,readable=?,items=? WHERE path=?", [.number(totals.bytes), .text(totals.bundle ?? ""), .number(complete && totals.readable ? 1 : 0), complete ? .number(totals.items) : .optional(nil), .text(path)])
                directories += 1
            }
            totals.bytes = 0; totals.items = 0; totals.bundle = nil; totals.readable = true
        })
        if let failure { throw failure }
        visited = directories
    }

    private mutating func read(_ path: String, recursive: Bool) throws {
        if cancelled() { throw CancellationError() }; try Task.checkCancellation()
        guard DiskDatabase.contains(path, below: db.root), !excluded.contains(where: { DiskDatabase.contains(path, below: $0) }) else { return }
        guard let info = metadata(path) else {
            if errno == ENOENT || errno == ENOTDIR { try db.remove(path) }
            else if var retained = try db.directory(path) { retained.readable = false; try db.put(retained) }
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, devices.contains(info.st_dev) else {
            try db.remove(path)
            return
        }
        if path.hasSuffix(".app") || (path.range(of: ".app/", options: .literal) != nil) { catalogChanged = true }
        try db.markTotals(path)
        if info.st_flags & UInt32(SF_DATALESS) != 0 {
            var retained = try db.directory(path) ?? DiskDirectory(path: path, ownerUID: info.st_uid)
            retained.readable = false; try db.put(retained); return
        }
        let old = try db.directory(path), oldChildren = try db.children(path)
        var node = DiskDirectory(path: path, itemCount: 0, ownerUID: info.st_uid)
        var folders: [String] = [], failure: Error?
        let oldLinkParents = try db.linkParents(at: path)
        for parent in oldLinkParents { try db.markTotals(parent) }
        try db.execute("SAVEPOINT directory_read")
        try db.ensureDirectory(path, ownerUID: info.st_uid)
        try db.clearFiles(parent: path)
        let complete = autoreleasepool {
            DirectoryWalk.entries(at: path, includingModificationDate: true) { name, entry in
                guard failure == nil else { return }
                do {
                    if cancelled() { throw CancellationError() }; try Task.checkCancellation()
                    node.itemCount = (node.itemCount ?? 0) + 1
                    entries += 1
                    if entries % 2048 == 0 { report?(0.8 * Double(entries) / Double(entries + 100_000)) }
                    let child = path == "/" ? "/" + name : path + "/" + name
                    guard devices.contains(entry.device), !excluded.contains(where: { DiskDatabase.contains(child, below: $0) }) else { return }
                    if entry.isDirectory { folders.append(child) }
                    else if entry.isRegularFile && !entry.isDataless {
                        if let id = Self.bundleIdentifier(child, parent: path, entry: entry) { node.bundleIdentifier = id }
                        let file = DiskFile(path: child, bytes: entry.allocatedBytes, logicalBytes: entry.logicalBytes, ownerUID: entry.ownerUID, modifiedAt: entry.modifiedAt)
                        let identity = entry.linkCount > 1 || !oldLinkParents.isEmpty ? metadata(child) : nil
                        let hasIdentity = identity != nil
                        let key = identity.map { "\($0.st_dev):\($0.st_ino)" } ?? ""
                        if entry.linkCount > 1 && !hasIdentity { node.readable = false }
                        var knownLink = false, changedLink = false
                        // Compare one indexed representative: unchanged aliases must not rewrite the family.
                        if hasIdentity {
                            try db.query("SELECT bytes<>? OR logical<>? OR uid IS NOT ? OR modified IS NOT ? FROM entries WHERE link=? AND link<>'' LIMIT 1",
                                         [.number(file.bytes), .number(file.logicalBytes), .optional(file.ownerUID), .date(file.modifiedAt), .text(key)]) {
                                knownLink = true; changedLink = DiskDatabase.number($0, 0) != 0
                            }
                        }
                        if hasIdentity && (entry.linkCount > 1 || knownLink) {
                            if changedLink {
                                // The nonempty predicate is required for SQLite to use the partial hard-link indexes.
                                try db.updateLink(file, link: key)
                            }
                            try db.put(file, link: key)
                        } else {
                            node.directBytes += file.bytes
                            if file.bytes > 0 { try db.put(file) }
                        }
                    }
                } catch { failure = error }
            }
        }
        if let failure {
            try db.execute("ROLLBACK TO directory_read"); try db.execute("RELEASE directory_read")
            throw failure
        }
        if !complete {
            try db.execute("ROLLBACK TO directory_read"); try db.execute("RELEASE directory_read")
            var retained = old ?? node; retained.readable = false; try db.put(retained); return
        }
        try db.execute("RELEASE directory_read")
        visited += 1
        if old?.bundleIdentifier != node.bundleIdentifier || path.contains(".app/") || path.hasSuffix(".app") { catalogChanged = true }
        if Set(oldChildren) != Set(folders), folders.contains(where: { $0.hasSuffix(".app") }) || oldChildren.contains(where: { $0.hasSuffix(".app") }) || (path.range(of: "/Library/", options: .literal) != nil) { catalogChanged = true }
        for removed in Set(oldChildren).subtracting(folders) { try db.remove(removed) }
        try db.put(node)
        try db.flushBatch()
        for parent in try db.linkParents(at: path) { try db.markTotals(parent) }
        for child in folders {
            if try recursive || db.directory(child) == nil { try read(child, recursive: true) }
        }
    }
}
