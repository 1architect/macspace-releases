import Foundation
import Darwin
import MacSpacePlatform
import MacSpaceSdk

/// Native directory streaming writes directly into an on-disk transaction. No whole-disk Swift object graph exists.
struct DiskDatabaseScanner {
    let db: DiskDatabase
    let excluded: [String]
    var metadata: (String) -> stat? = { path in var info = stat(); return lstat(path, &info) == 0 ? info : nil }
    private var devices = Set<dev_t>()
    private var catalogChanged = false
    private(set) var visited = 0
    init(db: DiskDatabase, excluded: [String]) { self.db = db; self.excluded = excluded }
    mutating func scan(_ changes: DiskEvents.Changes, cursor: UInt64, progress: LoadProgressSink?) throws {
        if let info = metadata(db.root) { devices.insert(info.st_dev) }
        if db.root == "/", let info = metadata(DataVolume.path) { devices.insert(info.st_dev) }
        try db.transaction {
            var state = try db.state() ?? DiskIndex(root: db.root)
            let initial = try db.directory(db.root) == nil
            let recursive = initial ? [db.root] : changes.recursive.sorted { $0.count < $1.count }
            var covered: [String] = []
            progress?(0)
            for path in recursive where !covered.contains(where: { DiskDatabase.contains(path, below: $0) }) {
                try read(path, recursive: true); covered.append(path)
            }
            let shallow = changes.shallow.filter { path in !covered.contains(where: { DiskDatabase.contains(path, below: $0) }) }.sorted()
            for (n, path) in shallow.enumerated() { try read(path, recursive: false); progress?(Double(n + 1) / Double(max(shallow.count, 1))) }
            try db.reconcileTotals(all: initial)
            state.eventID = cursor; state.revision += 1
            if initial || catalogChanged || state.catalogRevision == nil { state.catalogRevision = (state.catalogRevision ?? 0) + 1 }
            if db.root == "/" || db.root == DataVolume.path,
               let values = try? URL(fileURLWithPath: DataVolume.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]), let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage {
                state.volumeUsed = UInt64(max(0, Int64(total) - free))
            }
            try db.saveState(state)
            progress?(1)
        }
        try db.checkpoint()
    }
    private mutating func read(_ path: String, recursive: Bool) throws {
        try Task.checkCancellation()
        guard DiskDatabase.contains(path, below: db.root), !excluded.contains(where: { DiskDatabase.contains(path, below: $0) }) else { return }
        guard let info = metadata(path), info.st_mode & S_IFMT == S_IFDIR, devices.contains(info.st_dev) else {
            if errno == ENOENT || errno == ENOTDIR { try db.remove(path) }
            return
        }
        if path.hasSuffix(".app") || path.contains(".app/") { catalogChanged = true }
        try db.markTotals(path)
        if info.st_flags & UInt32(SF_DATALESS) != 0 {
            try db.remove(path); try db.put(DiskDirectory(path: path, ownerUID: info.st_uid)); return
        }
        let old = try db.directory(path), oldChildren = try db.children(path)
        var node = DiskDirectory(path: path, ownerUID: info.st_uid)
        var folders: [String] = [], failure: Error?
        let oldLinkParents = try db.linkParents(at: path)
        for parent in oldLinkParents { try db.markTotals(parent) }
        try db.execute("SAVEPOINT directory_read")
        try db.query("DELETE FROM files WHERE parent=?", [.text(path)])
        let complete = autoreleasepool {
            DirectoryWalk.entries(at: path) { name, entry in
                guard failure == nil else { return }
                do {
                    try Task.checkCancellation()
                    let child = path == "/" ? "/" + name : path + "/" + name
                    guard devices.contains(entry.device), !excluded.contains(where: { DiskDatabase.contains(child, below: $0) }) else { return }
                    if entry.isDirectory { folders.append(child) }
                    else if entry.isRegularFile && !entry.isDataless {
                        if name == "Info.plist", path.hasSuffix("/Contents") || path.hasSuffix("/Resources") {
                            node.bundleIdentifier = NSDictionary(contentsOfFile: child)?["CFBundleIdentifier"] as? String
                        }
                        let file = DiskFile(path: child, bytes: entry.allocatedBytes, logicalBytes: entry.logicalBytes, ownerUID: entry.ownerUID)
                        var info = stat()
                        let hasIdentity = (entry.linkCount > 1 || !oldLinkParents.isEmpty) && lstat(child, &info) == 0
                        let key = hasIdentity ? "\(info.st_dev):\(info.st_ino)" : ""
                        let knownLink = try hasIdentity && (db.query("SELECT 1 FROM files WHERE link=? AND link<>'' LIMIT 1", [.text(key)]) > 0)
                        if entry.linkCount > 1 || knownLink {
                            try db.query("UPDATE files SET bytes=?,logical=? WHERE link=?", [.number(file.bytes), .number(file.logicalBytes), .text(key)])
                            try db.put(file, link: key)
                        } else {
                            node.directBytes += file.bytes
                            if file.logicalBytes >= DiskIndex.largeFileMinimum && file.bytes > 0 { try db.put(file) }
                        }
                    }
                } catch { failure = error }
            }
        }
        if let failure { try db.execute("ROLLBACK TO directory_read"); try db.execute("RELEASE directory_read"); throw failure }
        if !complete {
            try db.execute("ROLLBACK TO directory_read"); try db.execute("RELEASE directory_read")
            var retained = old ?? node; retained.readable = false; try db.put(retained); return
        }
        try db.execute("RELEASE directory_read")
        visited += 1
        if Set(oldChildren) != Set(folders), folders.contains(where: { $0.hasSuffix(".app") }) || oldChildren.contains(where: { $0.hasSuffix(".app") }) || path.contains("/Library/") { catalogChanged = true }
        for removed in Set(oldChildren).subtracting(folders) { try db.remove(removed) }
        try db.put(node)
        try db.flushBatch()
        for parent in try db.linkParents(at: path) { try db.markTotals(parent) }
        for child in folders {
            if try recursive || db.directory(child) == nil { try read(child, recursive: true) }
        }
    }
}
