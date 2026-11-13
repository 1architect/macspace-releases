import Foundation
import Synchronization
import CoreServices
import CryptoKit
import Darwin
import MacSpacePlatform
import MacSpaceSdk

private final class DiskScanCancellation: @unchecked Sendable {
    private let value = Atomic(false)
    func cancel() { value.store(true, ordering: .relaxed) }
    var isCancelled: Bool { value.load(ordering: .relaxed) }
}

/// Only metadata and short transactions occupy this actor. Duplicate content reads run outside it.
private actor DiskDatabaseWriter: DiskDuplicateStorage {
    private var database: DiskDatabase?
    private let url: URL
    private var active: URL?
    private var retired: [(url: URL, identity: ReviewedDirectoryRemoval.Identity)] = []
    private var pointer: URL { url.appendingPathExtension("current") }
    private var checkpoint: String { "inventory.current." + SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined() }
    private let root: String
    private let excluded: [String]
    private let home: String
    init(url: URL, root: String, excluded: [String], home: String) { self.url = url; self.root = root; self.excluded = excluded; self.home = home }
    func boot() throws -> DiskIndex {
        if let database { return try database.state() ?? DiskIndex(root: root) }
        _ = try MetadataKeys.key(.inventory, create: true)
        _ = try DiskCacheAccess(url)
        let expected = try MetadataKeys.checkpoint(checkpoint)
        let raw = try? PrivateFile(pointer).read(maximum: 1024)
        let name = raw.flatMap { String(data: $0, encoding: .utf8) } ?? url.lastPathComponent
        let suffix = name.hasPrefix(url.lastPathComponent + ".") ? String(name.dropFirst(url.lastPathComponent.count + 1)) : ""
        let recognized = name == url.lastPathComponent || UUID(uuidString: suffix) != nil
        let trusted = recognized && expected == Data(name.utf8)
        if !trusted { try DiskCacheRetention.removeOwnedArtifacts(base: url, home: home) }
        let destination = trusted && name != url.lastPathComponent ? url.deletingLastPathComponent().appendingPathComponent(name) : url
        active = destination
        try DiskCacheRetention.prune(base: url, keeping: [destination])
        let db: DiskDatabase
        do { db = try DiskDatabase(url: destination, root: root, home: home) }
        catch let failure as DiskDatabase.Failure where failure.isCorrupt {
            // Only confirmed unreadable ciphertext/corruption permits a disposable rebuild.
            // Busy, permission, boundary and other I/O failures must preserve the existing cache.
            _ = try MetadataKeys.key(.inventory, create: false)
            try DiskCacheRetention.removeOwnedArtifacts(base: url, home: home)
            active = url
            db = try DiskDatabase(url: url, root: root, home: home)
        }
        database = db
        try MetadataKeys.checkpoint(checkpoint, value: Data((active ?? url).lastPathComponent.utf8))
        if try db.state() == nil, db.compact { try db.clearIncomplete() }
        return try db.state() ?? DiskIndex(root: root)
    }
    func location() -> URL { active ?? url }
    private func generation(_ work: (DiskDatabase) throws -> Void) throws -> URL {
        guard let database, let active else { throw DiskDatabase.Failure(message: "Disk index is unavailable") }
        let destination = url.appendingPathExtension(UUID().uuidString)
        try database.seal()
        let next = try database.copied(to: destination); next.unpublished = true
        try work(next)
        try next.seal(); next.unpublished = false
        try MetadataKeys.checkpoint(checkpoint, value: Data(destination.lastPathComponent.utf8))
        try PrivateFile(pointer, createDirectories: true).write(Data(destination.lastPathComponent.utf8))
        if let identity = ReviewedDirectoryRemoval.cleanupIdentity(active.path) { retired.append((active, identity)) }
        self.database = next; self.active = destination
        return destination
    }
    func load(_ changes: DiskEvents.Changes, cursor: UInt64, progress: LoadProgressRelay, cancellation: DiskScanCancellation) throws -> URL {
        guard let database else { throw DiskDatabase.Failure(message: "Disk index is unavailable") }
        let metadata = try database.state()
        if !database.compact || metadata.map({ $0.storageRevision != 4 }) == true {
            _ = try generation { try $0.compactReviewIndex() }
        }
        guard let database = self.database else { throw DiskDatabase.Failure(message: "Disk index is unavailable") }
        var changes = changes
        if try database.state() == nil || database.directory(root) == nil { changes = .init(recursive: [root]) }
        if !changes.recursive.isEmpty || !changes.shallow.isEmpty {
            // Enumeration and totals dominate this read. Inventory migration and duplicate checks
            // usually have no pending work; do not reserve most of the indicator for those stages.
            let pendingChanges = changes, excluded = self.excluded
            let work: (DiskDatabase) throws -> Void = { next in
                var scanner = DiskDatabaseScanner(db: next, excluded: excluded)
                scanner.cancelled = { cancellation.isCancelled }
                try scanner.scan(pendingChanges, cursor: cursor, progress: progress.part(0.04...0.92))
            }
            if try database.state() != nil, !changes.recursive.isEmpty || changes.shallow.count > 128 { _ = try generation(work) }
            else { try work(database) }
        }
        guard try self.database?.state() != nil else { throw DiskDatabase.Failure(message: "Disk index is unavailable") }
        try self.database?.preparePersonalInventory(progress: progress.part(0.92...0.94), cancelled: { cancellation.isCancelled })
        if cancellation.isCancelled { throw CancellationError() }
        // Empty/filtered history is still consumed history. Persist its boundary so it is not
        // replayed again on every launch when no metadata rows needed reconciliation.
        try self.database?.advanceEventCursor(cursor)
        return active ?? url
    }
    func retireReaders() {
        for old in retired {
            guard let current = ReviewedDirectoryRemoval.cleanupIdentity(old.url.path), current.device == old.identity.device,
                  current.inode == old.identity.inode, current.uid == old.identity.uid else { continue }
            if let removal = try? ReviewedDirectoryRemoval.prepareCleanup([.init(path: old.url.path, expected: current)], within: [old.url.deletingLastPathComponent().path]) {
                try? removal.remove(at: 0)
            }
            // Closed-connection sidecars are retired by the VFS using their pinned identities.
        }
        retired.removeAll()
    }
    func beginDuplicatePass(folder: String, minimumSize: UInt64) throws { try database?.beginDuplicatePass(folder: folder, minimumSize: minimumSize) }
    func duplicateMetadata(after: String) throws -> [DiskFile] { try database?.duplicateMetadata(after: after) ?? [] }
    func stageDuplicate(_ file: DiskFile, identity: FileReviewIdentity) throws { try database?.stageDuplicate(file, identity: identity) }
    func duplicateWork(sample: Bool, after: String) throws -> [DiskDuplicateWork] { try database?.duplicateWork(sample: sample, after: after) ?? [] }
    func saveDuplicate(_ work: DiskDuplicateWork, sample: Data, digest: Data?) throws { try database?.saveDuplicate(work, sample: sample, digest: digest) }
    func failDuplicate(_ path: String) throws { try database?.failDuplicate(path) }
    func finishDuplicatePass() throws { try database?.finishDuplicatePass() }
    func ownership(_ catalog: DiskApplications) throws { try database?.recordOwnership(catalog) }
    func flush() { try? database?.checkpoint() }
    func close() { database = nil; active = nil; retired.removeAll() }
}

actor DiskStore {
    nonisolated let receiptCacheURL: URL
    private let cacheURL: URL
    private let root: String
    private let excluded: [String]
    private let writer: DiskDatabaseWriter
    private let selections: DiskSelectionStorage
    private let home: String
    private var reader: DiskDatabase?
    private var readerLocation: URL?
    private var published: DiskSnapshot?
    private var folderViews: [String: DiskSnapshot] = [:]
    private var folderUse: [String] = []
    private var watcher: DiskEvents?
    private var historyValidated = false
    private var bootFlight: Task<Void, Never>?
    private var flight: Task<Void, Never>?
    private var relay: LoadProgressRelay?
    private var explicitlyInvalidated = false
    private var deferredChanges = DiskEvents.Changes()
    private var hasDeferredChanges: Bool { !deferredChanges.shallow.isEmpty || !deferredChanges.recursive.isEmpty }
    private var evidenceRevision: Date?
    private var ownershipFlight: Task<Void, Never>?
    private var duplicateFlight: Task<DiskDuplicateReport, Error>?
    private var duplicateScope: String?
    private var duplicateRevision: UInt64?
    private var duplicateUnknown: Int?
    private var duplicateFailure = false
    private var loadFailed = false

    init(root: String = "/", cache: URL? = nil, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.root = root; self.home = home
        let destination = cache?.appendingPathExtension("sqlite") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.macspace.disk-map/Index-v3.sqlite")
        receiptCacheURL = destination.appendingPathExtension("receipts.json")
        cacheURL = destination
        excluded = [destination.deletingLastPathComponent().path] + (root == "/" ? ["/System/Volumes", "/Volumes", "/dev", "/Network"] : [])
        writer = DiskDatabaseWriter(url: destination, root: root, excluded: excluded, home: home)
        selections = DiskSelectionStorage(url: destination.appendingPathExtension("selection"), root: root, home: home)
    }
    private var scanCancellation = DiskScanCancellation()
    private var active = true
    private var desiredActive = true
    private var protectedStorageSuspended = false
    private var protectionDrain: Task<Void, Never>?
    func setActive(_ value: Bool) async {
        desiredActive = value
        if value { await resumeProtectedStorageIfAvailable() }
        await applyActivity(desiredActive && !protectedStorageSuspended)
    }
    private func applyActivity(_ value: Bool) async {
        #if MACSPACE_DEV
        DiskScanMetrics.write("DISK_ACTIVITY active=\(value) inFlight=\(flight != nil) historyValidated=\(historyValidated)")
        #endif
        active = value
        if value, reader != nil, watcher == nil { watcher = DiskEvents(root: root, since: published?.index.eventID ?? 0, excluded: excluded); historyValidated = false }
        if !value {
            watcher = nil; historyValidated = false
            scanCancellation.cancel(); duplicateFlight?.cancel(); flight?.cancel()
            for reading in browseReadings.values where !reading.done { reading.task.cancel() }
            browseReadings = browseReadings.filter { $0.value.done }
            let workers = Array(browseWorkers.values)
            for worker in workers { worker.cancel() }
            await bootFlight?.value
            await flight?.value
            _ = try? await duplicateFlight?.value
            await ownershipFlight?.value
            for worker in workers { _ = await worker.value }
            if !active { watcher = nil }
        }
    }
    func suspendProtectedStorage() async {
        if let protectionDrain { await protectionDrain.value; return }
        protectedStorageSuspended = true
        // Drain once without changing the host's desired activity. Readers cannot reopen
        // storage until every old worker/connection has finished closing.
        let task = Task {
            await applyActivity(false)
            reader = nil; readerLocation = nil; published = nil
            folderViews.removeAll(); folderUse.removeAll(); browseReadings.removeAll(); browseUse.removeAll()
            preparedBrowse.removeAll(); preparedBrowseUse.removeAll()
            await selections.close(); await writer.close()
            protectionDrain = nil
        }
        protectionDrain = task
        await task.value
    }
    func resumeProtectedStorageIfAvailable() async {
        guard protectedStorageSuspended, desiredActive else { return }
        if let protectionDrain { await protectionDrain.value }
        guard protectedStorageSuspended, desiredActive else { return }
        do { try MetadataKeys.requireAvailable(); _ = try MetadataKeys.key(.inventory, create: false) }
        catch { return }
        protectedStorageSuspended = false
        await applyActivity(true)
    }
    func prepareForUninstall() async throws {
        await setActive(false)
        reader = nil; readerLocation = nil
        published = nil; folderViews.removeAll(); folderUse.removeAll()
        browseReadings.removeAll(); browseUse.removeAll()
        preparedBrowse.removeAll(); preparedBrowseUse.removeAll()
        await selections.close()
        await writer.close()
        try DiskCacheRetention.removeOwnedArtifacts(base: cacheURL, home: home)
    }
    func invalidate() {
        folderViews.removeAll(); folderUse.removeAll()
        preparedBrowse.removeAll(); preparedBrowseUse.removeAll()
        explicitlyInvalidated = true
        for reading in browseReadings.values { reading.task.cancel() }
        browseReadings.removeAll(); browseUse.removeAll()
    }
    private func invalidateBrowse(_ changes: DiskEvents.Changes) {
        preparedBrowse.removeAll(); preparedBrowseUse.removeAll()
        let affected = browseReadings.filter { _, reading in
            let folder = reading.preview.request.folder
            return changes.shallow.contains { DiskDatabase.contains($0, below: folder) }
                || changes.recursive.contains { DiskDatabase.contains($0, below: folder) || DiskDatabase.contains(folder, below: $0) }
        }.keys
        for key in affected { browseReadings.removeValue(forKey: key)?.task.cancel(); browseUse.removeAll { $0 == key } }
    }
    func mark(_ paths: [String], recursive: Bool = false) {
        folderViews.removeAll(); folderUse.removeAll()
        if let watcher { watcher.mark(paths, recursive: recursive) }
        else {
            let normalized = DiskEvents(root: root, since: 0, excluded: excluded, startStream: false)
            normalized.mark(paths, recursive: recursive)
            let changes = normalized.drain()
            deferredChanges.shallow.formUnion(changes.shallow)
            deferredChanges.recursive.formUnion(changes.recursive)
        }
        invalidateBrowse(recursive ? .init(recursive: Set(paths)) : .init(shallow: Set(paths)))
    }
    func statusView() -> DiskSnapshot? {
        guard historyValidated, watcher?.isReplayingHistory == false, watcher?.hasChanges == false, !explicitlyInvalidated, !hasDeferredChanges, flight == nil, !loadFailed, published?.index.personalInventoryVersion == DiskIndex.personalInventorySchemaVersion else { return nil }
        return published
    }
    func navigation(folder: String? = nil) async -> DiskSnapshot {
        await openCache()
        if published == nil { _ = await view() }
        if folder == nil, let published { return published }
        guard let folder else { return published ?? failureSnapshot() }
        if let cached = folderViews[folder] { return cached }
        let result = (try? autoreleasepool { try reader?.snapshot(folder: folder, inventory: folder == root) }) ?? published ?? failureSnapshot()
        folderViews[folder] = result; folderUse.removeAll { $0 == folder }; folderUse.append(folder)
        while folderUse.count > 12 { folderViews.removeValue(forKey: folderUse.removeFirst()) }
        return result
    }
    func folderFiles(_ folder: String, includeSmaller: Bool = false, focusPath: String? = nil) async -> DiskBrowsePage? {
        await openCache()
        if published == nil { _ = await view() }
        if DiskManagedLibrary.contains(folder, home: home) {
            var request = DiskBrowseRequest(folder: folder, kind: .managed); request.inFolder = true; request.focusPath = focusPath
            return await browse(request)
        }
        var request = DiskBrowseRequest(folder: folder, kind: .category, category: .largeFiles); request.inFolder = true; request.focusPath = focusPath
        if !includeSmaller, let cached = await browse(request), !cached.files.isEmpty { return cached }
        request.includeSmaller = true
        return await browse(request)
    }
    private struct BrowseReading {
        var id: UUID
        var task: Task<DiskBrowsePage?, Never>
        var progress: LoadProgressRelay
        var preview: DiskBrowsePage
        var result: DiskBrowsePage?
        var done = false
    }
    private var browseReadings: [String: BrowseReading] = [:]
    private var browseWorkers: [UUID: Task<DiskBrowsePage?, Never>] = [:]
    private var browseUse: [String] = []
    private var preparedBrowse: [String: DiskBrowsePage] = [:]
    private var preparedBrowseUse: [String] = []
    private func retainBrowse(_ page: DiskBrowsePage) -> DiskBrowsePage {
        let key = page.request.pageID
        preparedBrowse[key] = page
        preparedBrowseUse.removeAll { $0 == key }; preparedBrowseUse.append(key)
        while preparedBrowseUse.count > 12 { preparedBrowse.removeValue(forKey: preparedBrowseUse.removeFirst()) }
        return page
    }
    /// Prepare bounded metadata projections before the main page exposes its navigation links.
    func prepareNavigation() {
        guard active, let index = published?.index, let reader else { return }
        var requests = [DiskBrowseRequest(folder: root, kind: .category, category: .largeFiles)]
        requests += (index.categories ?? []).filter { $0.count > 0 }.map { .init(folder: root, kind: .category, category: $0.category) }
        for request in requests {
            var scopes = [request]
            if request.category != .installers {
                var small = request; small.includeSmaller = true; small.smallerOnly = true
                scopes.append(small)
            }
            for scope in scopes where preparedBrowse[scope.pageID] == nil {
                if let page = try? reader.browse(scope) { _ = retainBrowse(page) }
            }
        }
    }
    private func finishBrowse(_ key: String, id: UUID, result: DiskBrowsePage?) {
        browseWorkers.removeValue(forKey: id)
        guard var reading = browseReadings[key], reading.id == id else { return }
        var failed = reading.preview; failed.loadingFraction = nil
        failed.unavailableReason = loc("Contents could not be read. Refresh to retry.")
        reading.result = result ?? failed; reading.done = true; browseReadings[key] = reading
    }
    func browse(_ request: DiskBrowseRequest, progress: @escaping LoadProgressSink = { _ in }) async -> DiskBrowsePage? {
        await openCache()
        if published == nil { _ = await view() }
        if request.kind == .duplicates { return try? reader?.duplicatePage(request) }
        if reader?.canReview(request) == false { return DiskBrowsePage(request: request, files: [], ownership: [:]) }
        if !request.usesMetadataInventory {
            if let cached = preparedBrowse[request.pageID] { return retainBrowse(cached) }
            guard let page = try? reader?.browse(request, progress: progress) else { return nil }
            return retainBrowse(page)
        }
        let key = request.pageID
        if let reading = browseReadings[key] {
            if reading.done { return reading.result }
            reading.progress.attach(progress)
            _ = await reading.task.value
            return browseReadings[key]?.result
        }
        guard active, let sourceURL = readerLocation else { return nil }
        let preview = DiskBrowsePage(request: request, files: [], ownership: [:])
        let reports = LoadProgressRelay(), root = root, home = home, id = UUID()
        reports.attach(progress)
        let task = Task.detached(priority: .utility) { [weak self] () -> DiskBrowsePage? in
            let result: DiskBrowsePage?
            do {
                try Task.checkCancellation()
                let db = try DiskDatabase(url: sourceURL, root: root, home: home)
                result = try db.browse(request, progress: reports.part(0...1))
            } catch { result = nil }
            await self?.finishBrowse(key, id: id, result: result)
            return result
        }
        browseReadings[key] = .init(id: id, task: task, progress: reports, preview: preview)
        browseWorkers[id] = task
        browseUse.removeAll { $0 == key }; browseUse.append(key)
        while browseUse.count > 4 {
            let oldest = browseUse.removeFirst(); browseReadings.removeValue(forKey: oldest)?.task.cancel()
        }
        _ = await task.value
        return browseReadings[key]?.result
    }
    func selection(_ request: SelectionBulkRequest) async throws -> SelectionBulk {
        if published == nil { _ = await view() }
        if request.operation != "membership", let flight { await flight.value }
        guard let source = readerLocation else { throw DiskDatabase.Failure(message: "Disk inventory is unavailable.") }
        return try await selections.apply(request, sourceURL: source)
    }
    func pinSelection(token: String) async throws { try await selections.pin(token: token) }
    func unpinSelection(token: String) async { await selections.unpin(token: token) }
    func selectionSummary(token: String) async throws -> SelectionBulk { try await selections.summary(token: token) }
    func retainSelectionReview(token: String) async throws { try await selections.retainReview(token: token) }
    func selectionFiles(token: String, after: String = "", limit: Int = 200) async throws -> [DiskFile] { try await selections.files(token: token, after: after, limit: limit) }
    func selectionContains(token: String, path: String) async throws -> Bool { try await selections.contains(token: token, path: path) }
    func resolveSelection(_ files: [DiskFile], token: String) async throws -> [DiskFile] {
        guard let source = readerLocation else { throw DiskDatabase.Failure(message: "Disk inventory is unavailable.") }
        return try await selections.resolved(files, token: token, sourceURL: source)
    }
    func recordPreflight(_ files: [DiskFile], token: String) async throws { try await selections.recordPreflight(files, token: token) }
    func executionFiles(_ files: [DiskFile], token: String) async throws -> [DiskFile] { try await selections.executionFiles(files, token: token) }
    func recordSelectionRemoved(token: String, paths: [String]) async throws { try await selections.recordRemoved(token: token, paths: paths) }
    func selectionAfterRemoving(token: String, paths: [String]) async throws -> SelectionBulk { try await selections.removing(token: token, paths: paths) }
    private func verifyDuplicates(folder: String, scoped: Bool, progress: @escaping LoadProgressSink = { _ in }) async throws {
        guard active else { throw CancellationError() }
        let revision = published?.index.revision
        if duplicateScope == folder && duplicateRevision == revision {
            if let duplicateFlight { _ = try await duplicateFlight.value }
            return
        }
        let previous = duplicateFlight; previous?.cancel(); _ = try? await previous?.value
        duplicateScope = folder; duplicateRevision = revision
        let writer = writer, home = home
        let task = Task { try await DiskDuplicatePipeline.run(storage: writer, folder: folder, scoped: scoped, progress: progress, eligible: { FileReviewPolicy.includes($0, home: home) }) }
        duplicateFlight = task
        do {
            let report = try await task.value
            duplicateUnknown = report.unknown; duplicateFailure = false
            publishDuplicates()
        } catch {
            duplicateScope = nil
            if !(error is CancellationError) { duplicateFailure = true; publishDuplicates() }
            throw error
        }
    }
    private func publishDuplicates() {
        folderViews.removeAll(); folderUse.removeAll()
        preparedBrowse.removeAll(); preparedBrowseUse.removeAll()
        if flight == nil, let reader, let snapshot = try? reader.snapshot() {
            var index = snapshot.index
            index.duplicateUnknown = duplicateUnknown; index.duplicateFailure = duplicateFailure
            published = DiskSnapshot(index)
        }
    }
    /// Resolves explicit IDs only. The caller must compare the host's ORIGINAL reviewed identity before execution.
    func selectedFiles(_ ids: Set<String>, folder: String, reviewed: [String: String]? = nil, origins: [String: String] = [:]) -> [DiskFile]? { try? reader?.selectedFiles(ids, folder: folder, reviewed: reviewed, origins: origins) }
    func canRemoveDirectory(_ path: String) -> Bool { (try? reader?.canRemoveDirectory(path)) == true }
    func recordOwnership(_ catalog: DiskApplications) async {
        guard evidenceRevision != catalog.catalogReadAt else { return }
        if let ownershipFlight { await ownershipFlight.value; return }
        let writer = writer
        let task = Task.detached(priority: .utility) { () -> Bool in
            do { try await writer.ownership(catalog); return true } catch { return false }
        }
        ownershipFlight = Task { _ = await task.value }
        if await task.value { evidenceRevision = catalog.catalogReadAt }
        ownershipFlight = nil
        publishDuplicates()
    }
    func flushPersistence() async { await writer.flush() }
    func snapshot(progress: LoadProgressSink? = nil) async -> DiskIndex {
        _ = await view(progress: progress)
        watcher?.flush()
        if flight == nil, watcher?.hasChanges == true { _ = await view(progress: progress) }
        if let flight { await flight.value }
        return published?.index ?? failureSnapshot().index
    }
    private func failureSnapshot() -> DiskSnapshot { var index = DiskIndex(root: root); index.loadError = true; return DiskSnapshot(index) }
    private func openCache() async {
        await resumeProtectedStorageIfAvailable()
        guard active, reader == nil else { return }
        if let bootFlight { await bootFlight.value }
        else { let task = Task { await boot() }; bootFlight = task; await task.value; bootFlight = nil }
    }
    private func boot() async {
        do {
            let bootStarted = Date()
            let metadata = try await writer.boot(), location = await writer.location()
            DiskScanMetrics.phase("cache-open", since: bootStarted)
            let snapshotStarted = Date()
            reader = try DiskDatabase(url: location, root: root, home: home); readerLocation = location
            if try reader?.state() != nil { published = try reader?.snapshot() }
            DiskScanMetrics.phase("cached-snapshot", since: snapshotStarted)
            if active { watcher = DiskEvents(root: root, since: metadata.eventID, excluded: excluded) }
            historyValidated = false
        } catch { loadFailed = true; published = failureSnapshot() }
    }
    func view(progress: LoadProgressSink? = nil) async -> DiskSnapshot {
        await resumeProtectedStorageIfAvailable()
        guard active else { return published ?? failureSnapshot() }
        await openCache()
        if let flight {
            if let progress { relay?.attach(progress) }
            await flight.value
            // A newly active caller may have joined a read cancelled by the last window closing.
            // Retry its preserved work instead of presenting the previous cache as a completed scan.
            if active && flight.isCancelled { return await view(progress: progress) }
            return published ?? failureSnapshot()
        }
        if let published, published.index.storageRevision == 4, published.index.personalInventoryVersion == DiskIndex.personalInventorySchemaVersion, !explicitlyInvalidated, !loadFailed, !hasDeferredChanges, historyValidated, watcher?.isReplayingHistory == false, watcher?.hasChanges == false {
            if duplicateScope == nil || duplicateRevision != published.index.revision {
                try? await verifyDuplicates(folder: root, scoped: false, progress: progress ?? { _ in })
            }
            progress?(1); return self.published ?? published
        }
        guard active else { return published ?? failureSnapshot() }
        let reports = LoadProgressRelay(); if let progress { reports.attach(progress) }; relay = reports
        scanCancellation = DiskScanCancellation()
        reports.report(0.02) // The completed cache/bootstrap stage is actual work, not an elapsed-time filler.
        let task = Task {
            await reconcile(reports: reports)
            flight = nil; relay = nil

        }
        flight = task
        // The host retains its completed content while this request reports reconciliation progress.
        await task.value
        if active && task.isCancelled { return await view(progress: progress) }
        return published ?? failureSnapshot()
    }
    private func reconcile(reports: LoadProgressRelay) async {
        var changes = DiskEvents.Changes()
        do {
            reports.report(0.02)
            let previous = duplicateFlight; previous?.cancel(); _ = try? await previous?.value
            duplicateFlight = nil; duplicateScope = nil
            let eventStarted = Date()
            if deferredChanges.recursive.contains(root) { watcher?.mark([root], recursive: true) }
            let consumedThrough = watcher?.flush() ?? published?.index.eventID ?? 0
            DiskScanMetrics.phase("event-replay", since: eventStarted)
            changes = watcher?.drain() ?? .init()
            changes.shallow.formUnion(deferredChanges.shallow)
            changes.recursive.formUnion(deferredChanges.recursive)
            deferredChanges = .init()
            if explicitlyInvalidated { changes.shallow.insert(root); explicitlyInvalidated = false }
            DiskScanMetrics.write("DISK_SCOPES shallow=\(changes.shallow.count) recursive=\(changes.recursive.count) root=\(changes.recursive.contains(root))")
            reports.report(0.04)
            let loadStarted = Date()
            let destination = try await writer.load(changes, cursor: consumedThrough, progress: reports, cancellation: scanCancellation)
            DiskScanMetrics.phase("metadata-load", since: loadStarted)
            invalidateBrowse(changes)
            folderViews.removeAll(); folderUse.removeAll()
            if readerLocation != destination {
                reader = try DiskDatabase(url: destination, root: root, home: home); readerLocation = destination
                await writer.retireReaders()
            }
            if let snapshot = try reader?.snapshot() { published = snapshot }
            loadFailed = false; historyValidated = true
            let duplicateStarted = Date()
            try await verifyDuplicates(folder: root, scoped: false, progress: reports.part(0.94...1))
            DiskScanMetrics.phase("duplicate-verification", since: duplicateStarted)
            if let snapshot = try reader?.snapshot() {
                var index = snapshot.index; index.duplicateUnknown = duplicateUnknown; index.duplicateFailure = duplicateFailure
                published = DiskSnapshot(index)
            }
            reports.report(1)
        } catch {
            // These sets already identify directories. Refeeding them as file events broadens shallow
            // scopes to their parents and loses them entirely if the watcher was suspended.
            deferredChanges.shallow.formUnion(changes.shallow)
            deferredChanges.recursive.formUnion(changes.recursive)
            if error is CancellationError { return }
            loadFailed = true
            var index = published?.index ?? DiskIndex(root: root); index.loadError = true; published = DiskSnapshot(index)
        }
    }
}
