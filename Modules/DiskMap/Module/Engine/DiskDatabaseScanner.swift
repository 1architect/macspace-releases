import Foundation
import Synchronization
import Darwin
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceDiskMapPrivileged

/// Native directory streaming writes directly into an on-disk transaction. No whole-disk Swift object graph exists.
struct DiskDatabaseScanner {
    private final class ScanFailure {
        private let failed = Atomic(false)
        // The writer lock protects the error. Walkers only consult the atomic flag.
        var error: Error? { didSet { failed.store(error != nil, ordering: .relaxed) } }
        var hasError: Bool { failed.load(ordering: .relaxed) }
    }

    let db: DiskDatabase
    let excluded: [String]
    var metadata: (String) -> stat? = { path in var info = stat(); return lstat(path, &info) == 0 ? info : nil }
    var cancelled: @Sendable () -> Bool = { false }
    var parallelRootRefresh = true
    private var devices = Set<dev_t>()
    private var catalogChanged = false
    private var report: LoadProgressSink?
    private var expectedWork = 0
    private var completedWork = 0
    private var reportedWork = 0
    private var includesEntryWork = false
    private var estimatesUnknownScopes = false
    private var refreshesWholeRoot = false

    private mutating func advanced(directory: Bool) {
        guard expectedWork > 0, directory || includesEntryWork else { return }
        completedWork += 1
        let step = max(32, expectedWork / 128)
        guard completedWork - reportedWork >= step else { return }
        reportedWork = completedWork
        let fraction = estimatesUnknownScopes
            ? Double(completedWork) / (Double(completedWork) + Double(expectedWork))
            : min(1, Double(completedWork) / Double(expectedWork))
        report?(0.8 * fraction)
    }
    private func walkExclusions() -> (String) -> Bool {
        let prefixes = excluded.map { ($0, $0 == "/" ? "/" : $0 + "/") }
        return { path in
            // Most entries match no exclusion. Validate the path only for a potential match.
            prefixes.contains { path == $0.0 || path.hasPrefix($0.1) }
                && FileReviewPolicy.isNormalizedAbsolutePath(path)
        }
    }

    private(set) var visited = 0
    init(db: DiskDatabase, excluded: [String]) { self.db = db; self.excluded = excluded }
    mutating func scan(_ changes: DiskEvents.Changes, cursor: UInt64, progress: LoadProgressSink?) throws {
        if cancelled() { throw CancellationError() }
        // Bounded batches may survive a cancelled first walk. Only a committed state record proves completion.
        if try db.state() == nil { try db.clearIncomplete() }
        if let info = metadata(db.root) { devices.insert(info.st_dev) }
        if db.root == "/", let info = metadata(DataVolume.path) { devices.insert(info.st_dev) }
        let started = Date()
        // Keep the working pages for the bulk write/ancestor pass resident. Idle readers retain
        // the smaller cache, and the scanner releases these pages again at its checkpoint.
        try db.execute("PRAGMA cache_size=-16384")
        defer { try? db.execute("PRAGMA cache_size=-2048") }
        report = progress
        defer { report = nil }
        try db.transaction {
            var state = try db.state() ?? DiskIndex(root: db.root)
            let initial = try db.directory(db.root) == nil
            let recursive = initial ? [db.root] : changes.recursive.sorted { $0.count < $1.count }
            var covered: [String] = []
            for path in recursive where DiskDatabase.contains(path, below: db.root)
                && !covered.contains(where: { DiskDatabase.contains(path, below: $0) }) { covered.append(path) }
            let shallow = changes.shallow.filter { path in
                DiskDatabase.contains(path, below: db.root) && !covered.contains(where: { DiskDatabase.contains(path, below: $0) })
            }.sorted()
            completedWork = 0; reportedWork = 0; expectedWork = 0; includesEntryWork = false; estimatesUnknownScopes = false
            refreshesWholeRoot = !initial && covered.contains(db.root)
            if !initial {
                let work = try db.scanWork(recursive: covered, shallow: shallow)
                estimatesUnknownScopes = work.unknownScopes
                includesEntryWork = work.entries != nil || work.unknownScopes
                expectedWork = work.directories + (work.entries ?? 0)
                // A newly discovered subtree has no cached inventory to size it. Keep reporting work estimates
                // there instead of declaring traversal complete after its first directory.
                if work.unknownScopes { expectedWork = max(expectedWork, 100_000) }
            }
            progress?(0)
            if initial {
                try db.beginInitialCollection()
                let walkStarted = Date()
                try initialScan()
                db.phase?("walk", Date().timeIntervalSince(walkStarted), visited)
                let indexStarted = Date()
                try db.createIndexes(progress: { progress?(0.7 + 0.1 * $0) })
                db.phase?("indexes", Date().timeIntervalSince(indexStarted), visited)
            } else if refreshesWholeRoot && parallelRootRefresh {
                let walkStarted = Date()
                try nativeRefresh()
                db.phase?("parallel-refresh", Date().timeIntervalSince(walkStarted), visited)
            } else {
                for path in covered { try read(path, recursive: true) }
            }
            for path in shallow { try read(path, recursive: false) }
            progress?(0.8)
            let totalsStarted = Date()
            try db.reconcileTotals(all: initial || refreshesWholeRoot, progress: { progress?(0.8 + 0.19 * $0) })
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
              bundleContainer(parent),
              let id = autoreleasepool(invoking: { NSDictionary(contentsOfFile: path)?["CFBundleIdentifier"] as? String }), AppOwner.validIdentifier(id) else { return nil }
        return id
    }
    private static func bundleContainer(_ path: String) -> Bool {
        path.hasSuffix("/Contents") || path.hasSuffix("/Resources")
            || ["app", "appex", "xpc", "bundle", "framework", "plugin"].contains((path as NSString).pathExtension)
    }

    /// Filesystem waits overlap across eight existing native workers; SQLite still has one writer.
    private mutating func initialScan() throws {
        struct Totals {
            var bytes: UInt64 = 0; var items: UInt64 = 0; var bundle: String?; var readable = true
            var pendingFiles = 0
            var directoryCreated = false
            var directory: String?
            var excludedDirectory = false
            var checkExclusions = false
            var personal = false
            var bundleContainer = false
            var files: [(DiskFile, String)] = []
            var folders: [DiskDirectory] = []
        }
        let db = db, metadata = metadata, devices = devices, isExcluded = walkExclusions(), report = report, cancelled = cancelled
        let inventoryIncludes = db.inventoryIncludes, uid = getuid()
        let personalPolicy = db.usesPersonalPolicy
        let excludedParents = Set(excluded.map(DiskDatabase.parent))
        guard let info = metadata(db.root) else { throw DiskDatabase.Failure(message: "The scan root is unreadable") }
        try db.put(DiskDirectory(path: db.root, ownerUID: info.st_uid))
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else {
            try db.query("UPDATE dirs SET readable=0 WHERE path=?", [.text(db.root)]); return
        }
        let lock = NSLock()
        let failure = ScanFailure()
        var count = 0, directories = 0
        func writing(_ work: () throws -> Void) {
            lock.withLock {
                guard !failure.hasError else { return }
                do { if cancelled() { throw CancellationError() }; try Task.checkCancellation(); try work(); try db.flushBatch() }
                catch { failure.error = error }
            }
        }
        func flush(_ totals: inout Totals, finished: (path: String, complete: Bool)? = nil) {
            guard finished != nil || totals.pendingFiles > 0 || !totals.folders.isEmpty else { return }
            let ownPath = finished?.path ?? totals.files.first.map { DiskDatabase.parent($0.0.path) } ?? totals.folders.first.map { DiskDatabase.parent($0.path) }
            let ownerUID = totals.directoryCreated ? nil : ownPath.flatMap { metadata($0)?.st_uid }
            writing {
                if let finished {
                    try db.collectInitialDirectory(DiskDirectory(path: finished.path, itemCount: finished.complete ? totals.items : nil,
                        directBytes: totals.bytes, readable: finished.complete && totals.readable, bundleIdentifier: totals.bundle, ownerUID: ownerUID))
                    directories += 1
                } else if !totals.directoryCreated, !totals.files.isEmpty || !totals.folders.isEmpty, let ownPath {
                    // Only a directory with retained files needs a placeholder before its enumeration finishes.
                    try db.ensureDirectory(ownPath, ownerUID: ownerUID, parentExists: true)
                    totals.directoryCreated = true
                }
                // Dataless children are not traversed; retain their existing zero/unknown placeholders.
                for node in totals.folders { try db.ensureDirectory(node.path, ownerUID: node.ownerUID, parentExists: true) }
                for (file, link) in totals.files {
                    try db.put(file, link: link, parentExists: true)
                }
                count += totals.pendingFiles
                report?(0.7 * Double(count) / Double(count + 100_000))
            }
            totals.pendingFiles = 0
            totals.files.removeAll(keepingCapacity: true); totals.folders.removeAll(keepingCapacity: true)
        }
        DirectoryWalk.scan(db.root, devices: devices, pool: ScanPool(free: 7), makeState: { Totals() }, visit: { totals, makePath, entry in
            totals.items += 1
            if cancelled() { writing { throw CancellationError() }; return false }
            guard devices.contains(entry.device), entry.isDirectory || (entry.isRegularFile && !entry.isDataless) else { return false }
            if totals.directory == nil {
                let directory = DiskDatabase.parent(makePath())
                totals.directory = directory
                totals.excludedDirectory = isExcluded(directory)
                totals.checkExclusions = excludedParents.contains(directory)
                totals.personal = !personalPolicy || inventoryIncludes(directory + "/candidate")
                totals.bundleContainer = Self.bundleContainer(directory)
            }
            guard !totals.excludedDirectory else { return false }
            if entry.isDirectory {
                let path = makePath()
                guard !isExcluded(path) else { return false }
                guard !failure.hasError, let info = metadata(path), info.st_mode & S_IFMT == S_IFDIR else { return false }
                if info.st_flags & UInt32(SF_DATALESS) != 0 {
                    totals.folders.append(DiskDirectory(path: path, ownerUID: info.st_uid))
                    if totals.folders.count >= 256 { flush(&totals) }
                    return false
                }
                return true
            }
            if totals.checkExclusions, isExcluded(makePath()) { return false }
            let identity = entry.linkCount > 1 ? metadata(makePath()) : nil
            let link = identity.map { "\($0.st_dev):\($0.st_ino)" } ?? ""
            if entry.linkCount > 1 && identity == nil { totals.readable = false }
            if link.isEmpty { totals.bytes += entry.allocatedBytes }
            if totals.bundleContainer, entry.logicalBytes <= 1_048_576,
               let id = Self.bundleIdentifier(makePath(), parent: totals.directory!, entry: entry) { totals.bundle = id }
            // Most files only contribute directory bytes. Classify candidates on the readers, as the native refresh does,
            // instead of allocating records and reparsing all paths while every worker waits for the SQLite writer.
            if !link.isEmpty || (totals.personal && entry.allocatedBytes > 0 && entry.ownerUID == uid && inventoryIncludes(makePath())) {
                totals.files.append((DiskFile(path: makePath(), bytes: entry.allocatedBytes, logicalBytes: entry.logicalBytes, ownerUID: entry.ownerUID, modifiedAt: entry.modifiedAt), link))
            }
            totals.pendingFiles += 1
            if totals.pendingFiles >= 256 { flush(&totals) }
            return false
        }, finished: { totals, path, complete in
            flush(&totals, finished: (path, complete))
            totals.bytes = 0; totals.items = 0; totals.bundle = nil; totals.readable = true
            totals.directoryCreated = false
            totals.directory = nil
        })
        if let error = failure.error { throw error }
        visited = directories
    }

    private mutating func read(_ path: String, recursive: Bool) throws {
        if cancelled() { throw CancellationError() }; try Task.checkCancellation()
        guard DiskDatabase.contains(path, below: db.root), !excluded.contains(where: { DiskDatabase.contains(path, below: $0) }) else { return }
        advanced(directory: true)
        // Deleting a bundle must invalidate the catalog even though its metadata is already gone.
        if path.hasSuffix(".app") || path.contains(".app/") { catalogChanged = true }
        guard let info = metadata(path) else {
            if errno == ENOENT || errno == ENOTDIR { try db.remove(path, markAffectedTotals: !refreshesWholeRoot) }
            else if var retained = try db.directory(path) { retained.readable = false; try db.put(retained) }
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, devices.contains(info.st_dev) else {
            try db.remove(path, markAffectedTotals: !refreshesWholeRoot)
            return
        }
        if !refreshesWholeRoot { try db.markTotals(path) }
        if info.st_flags & UInt32(SF_DATALESS) != 0 {
            var retained = try db.directory(path) ?? DiskDirectory(path: path, ownerUID: info.st_uid)
            retained.readable = false; try db.put(retained); return
        }
        let old = try db.directory(path), oldChildren = try db.children(path)
        var node = DiskDirectory(path: path, itemCount: 0, bytes: refreshesWholeRoot ? old?.bytes ?? 0 : 0, ownerUID: info.st_uid)
        var folders: [String] = [], failure: Error?
        let oldLinkParents = refreshesWholeRoot ? [] : try db.linkParents(at: path)
        let hadLinkedEntries = refreshesWholeRoot ? try db.hasLinkedEntries(parent: path) : !oldLinkParents.isEmpty
        for parent in oldLinkParents { try db.markTotals(parent) }
        try db.execute("SAVEPOINT directory_read")
        try db.ensureDirectory(path, ownerUID: info.st_uid)
        if refreshesWholeRoot { try db.beginDirectoryRefresh() } else { try db.clearFiles(parent: path) }
        let complete = autoreleasepool {
            DirectoryWalk.entries(at: path, includingModificationDate: true) { name, entry in
                guard failure == nil else { return }
                do {
                    if cancelled() { throw CancellationError() }; try Task.checkCancellation()
                    node.itemCount = (node.itemCount ?? 0) + 1
                    advanced(directory: false)
                    let child = path == "/" ? "/" + name : path + "/" + name
                    guard devices.contains(entry.device), !excluded.contains(where: { DiskDatabase.contains(child, below: $0) }) else { return }
                    if entry.isDirectory { folders.append(child) }
                    else if entry.isRegularFile && !entry.isDataless {
                        if let id = Self.bundleIdentifier(child, parent: path, entry: entry) { node.bundleIdentifier = id }
                        let file = DiskFile(path: child, bytes: entry.allocatedBytes, logicalBytes: entry.logicalBytes, ownerUID: entry.ownerUID, modifiedAt: entry.modifiedAt)
                        let identity = entry.linkCount > 1 || hadLinkedEntries ? metadata(child) : nil
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
                            try db.put(file, link: key, trackSeen: refreshesWholeRoot, parentExists: true)
                        } else {
                            node.directBytes += file.bytes
                            if file.bytes > 0 { try db.put(file, trackSeen: refreshesWholeRoot, parentExists: true) }
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
        if refreshesWholeRoot { try db.finishDirectoryRefresh(path) }
        try db.execute("RELEASE directory_read")
        visited += 1
        if old?.bundleIdentifier != node.bundleIdentifier || path.contains(".app/") || path.hasSuffix(".app") { catalogChanged = true }
        if Set(oldChildren) != Set(folders), folders.contains(where: { $0.hasSuffix(".app") }) || oldChildren.contains(where: { $0.hasSuffix(".app") }) || (path.range(of: "/Library/", options: .literal) != nil) { catalogChanged = true }
        for removed in Set(oldChildren).subtracting(folders) { try db.remove(removed, markAffectedTotals: !refreshesWholeRoot) }
        try db.put(node)
        try db.flushBatch()
        if !refreshesWholeRoot { for parent in try db.linkParents(at: path) { try db.markTotals(parent) } }
        for child in folders {
            if try recursive || db.directory(child) == nil { try read(child, recursive: true) }
        }
    }
}

extension DiskDatabaseScanner {
    /// Eight bounded native readers feed one staged SQLite writer. No per-directory transaction/query chain
    /// is needed, and an incomplete enumeration never erases the previously completed directory inventory.
    private mutating func nativeRefresh() throws {
        guard let rootInfo = metadata(db.root), rootInfo.st_mode & S_IFMT == S_IFDIR,
              rootInfo.st_flags & UInt32(SF_DATALESS) == 0 else {
            try read(db.root, recursive: true)
            return
        }
        struct Batch {
            var items: UInt64 = 0, pendingItems = 0
            var bytes: UInt64 = 0
            var bundle: String?
            var readable = true, app = false, hadLinks: Bool?
            var files: [(DiskFile, String)] = []
            var folders: [(String, UInt32?)] = []
        }
        let db = db, metadata = metadata, devices = devices, isExcluded = walkExclusions(), report = report, cancelled = cancelled
        let inventoryIncludes = db.inventoryIncludes, includeEntries = includesEntryWork, expected = expectedWork
        let linkedParents = try db.linkedDirectoryPaths(limit: 4096)
        try db.beginNativeRefresh()
        try db.nativeDirectorySeen(db.root, uid: rootInfo.st_uid)
        let lock = NSLock()
        let failure = ScanFailure()
        var directories = 0, entries = 0, reported = 0
        var changedCatalog = try db.query("SELECT 1 FROM dirs WHERE substr(path,-4)='.app' LIMIT 1") > 0
        func writing(_ operation: () throws -> Void) {
            lock.withLock {
                guard !failure.hasError else { return }
                do {
                    if cancelled() { throw CancellationError() }
                    try Task.checkCancellation()
                    try operation(); try db.flushBatch()
                } catch { failure.error = error }
            }
        }
        func progress() {
            let done = includeEntries ? entries + directories : directories
            guard expected > 0, done - reported >= max(32, expected / 128) else { return }
            reported = done
            report?(0.72 * min(1, Double(done) / Double(expected)))
        }
        func flush(_ batch: inout Batch) {
            guard batch.pendingItems > 0 || !batch.files.isEmpty || !batch.folders.isEmpty else { return }
            writing {
                for (path, uid) in batch.folders { try db.nativeDirectorySeen(path, uid: uid) }
                for (file, link) in batch.files { try db.put(file, link: link, staging: true, parentExists: true) }
                entries += batch.pendingItems
                if batch.app { changedCatalog = true }
                progress()
            }
            batch.pendingItems = 0
            batch.files.removeAll(keepingCapacity: true); batch.folders.removeAll(keepingCapacity: true)
        }
        let walkStarted = Date()
        DirectoryWalk.scan(db.root, devices: devices, pool: ScanPool(free: 7), makeState: { Batch() }, visit: { batch, makePath, entry in
            batch.items += 1; batch.pendingItems += 1
            if cancelled() { writing { throw CancellationError() }; return false }
            guard devices.contains(entry.device), entry.isDirectory || (entry.isRegularFile && !entry.isDataless) else { return false }
            let path = makePath()
            guard !isExcluded(path) else { return false }
            if entry.isDirectory {
                batch.folders.append((path, entry.ownerUID))
                if path.hasSuffix(".app") || path.contains(".app/") { batch.app = true }
                if batch.folders.count >= 256 { flush(&batch) }
                guard !failure.hasError, let info = metadata(path), info.st_mode & S_IFMT == S_IFDIR else { return false }
                return info.st_flags & UInt32(SF_DATALESS) == 0
            }
            let parent = DiskDatabase.parent(path)
            if batch.hadLinks == nil {
                if let linkedParents { batch.hadLinks = linkedParents.contains(parent) }
                else { writing { batch.hadLinks = try db.hasLinkedEntries(parent: parent) } }
            }
            let identity = entry.linkCount > 1 || batch.hadLinks == true ? metadata(path) : nil
            var link = ""
            if let identity {
                let key = "\(identity.st_dev):\(identity.st_ino)"
                if entry.linkCount > 1 { link = key }
                else { writing { if try db.hasKnownLink(key) { link = key } } }
            } else if entry.linkCount > 1 { batch.readable = false }
            if link.isEmpty { batch.bytes += entry.allocatedBytes }
            if let id = Self.bundleIdentifier(path, parent: parent, entry: entry) { batch.bundle = id }
            if !link.isEmpty || (entry.allocatedBytes > 0 && entry.ownerUID == getuid() && inventoryIncludes(path)) {
                batch.files.append((DiskFile(path: path, bytes: entry.allocatedBytes, logicalBytes: entry.logicalBytes,
                    ownerUID: entry.ownerUID, modifiedAt: entry.modifiedAt), link))
            }
            if batch.files.count >= 256 || batch.pendingItems >= 1_024 { flush(&batch) }
            return false
        }, finished: { batch, path, complete in
            flush(&batch)
            writing {
                try db.nativeDirectoryFinished(path, direct: batch.bytes, bundle: batch.bundle,
                    readable: batch.readable, items: batch.items, complete: complete)
                directories += 1; progress()
            }
            batch = Batch()
        })
        if let error = failure.error { throw error }
        db.phase?("native-walk", Date().timeIntervalSince(walkStarted), directories)
        report?(0.72)
        let bundlesChanged = try db.finishNativeRefresh(cancelled: cancelled, progress: { report?(0.72 + 0.08 * $0) })
        catalogChanged = catalogChanged || changedCatalog || bundlesChanged
        visited = directories
    }
}
