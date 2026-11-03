import Foundation
import CoreServices
import Darwin
import MacSpacePlatform
import MacSpaceSdk

/// Only metadata and short transactions occupy this actor. Duplicate content reads run outside it.
private actor DiskDatabaseWriter: DiskDuplicateStorage {
    private var database: DiskDatabase?
    private let url: URL
    private var active: URL?
    private var retired: [URL] = []
    private var pointer: URL { url.appendingPathExtension("current") }
    private let root: String
    private let excluded: [String]
    private let home: String
    init(url: URL, root: String, excluded: [String], home: String) { self.url = url; self.root = root; self.excluded = excluded; self.home = home }
    func boot() throws -> DiskIndex {
        if let database { return try database.state() ?? DiskIndex(root: root) }
        let name = (try? String(contentsOf: pointer, encoding: .utf8)) ?? ""
        let suffix = name.hasPrefix(url.lastPathComponent + ".") ? String(name.dropFirst(url.lastPathComponent.count + 1)) : ""
        let destination = UUID(uuidString: suffix) != nil ? url.deletingLastPathComponent().appendingPathComponent(name) : url
        active = destination
        try DiskCacheRetention.prune(base: url, keeping: [destination])
        let db = try DiskDatabase(url: destination, root: root, home: home); database = db
        if try db.state() == nil, db.compact { try db.clearIncomplete() }
        return try db.state() ?? DiskIndex(root: root)
    }
    func location() -> URL { active ?? url }
    private func generation(_ work: (DiskDatabase) throws -> Void) throws -> URL {
        guard let database, let active else { throw DiskDatabase.Failure(message: "Disk index is unavailable") }
        let destination = url.appendingPathExtension(UUID().uuidString)
        defer {
            if self.active != destination {
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: destination.path + suffix) }
            }
        }
        try database.seal()
        if clonefile(active.path, destination.path, 0) != 0 { try FileManager.default.copyItem(at: active, to: destination) }
        let next = try DiskDatabase(url: destination, root: root, home: home); next.unpublished = true
        try work(next)
        try next.seal(); next.unpublished = false
        try destination.lastPathComponent.write(to: pointer, atomically: true, encoding: .utf8)
        self.database = next; self.active = destination; retired.append(active)
        return destination
    }
    func load(_ changes: DiskEvents.Changes, progress: LoadProgressRelay) throws -> URL {
        guard let database else { throw DiskDatabase.Failure(message: "Disk index is unavailable") }
        let metadata = try database.state()
        if !database.compact || metadata.map({ $0.storageRevision != 4 }) == true {
            _ = try generation { try $0.compactReviewIndex() }
        }
        guard let database = self.database else { throw DiskDatabase.Failure(message: "Disk index is unavailable") }
        var changes = changes
        if try database.state() == nil || database.directory(root) == nil { changes = .init(recursive: [root]) }
        if !changes.recursive.isEmpty || !changes.shallow.isEmpty {
            let cursor = FSEventsGetCurrentEventId(), pendingChanges = changes, excluded = self.excluded
            let work: (DiskDatabase) throws -> Void = { next in
                var scanner = DiskDatabaseScanner(db: next, excluded: excluded)
                try scanner.scan(pendingChanges, cursor: cursor, progress: progress.part(0...1))
            }
            if try database.state() != nil, !changes.recursive.isEmpty || changes.shallow.count > 128 { _ = try generation(work) }
            else { try work(database) }
        }
        guard try self.database?.state() != nil else { throw DiskDatabase.Failure(message: "Disk index is unavailable") }
        return active ?? url
    }
    func retireReaders() {
        for old in retired { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: old.path + suffix) } }
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
}

actor DiskStore {
    private let root: String
    private let excluded: [String]
    private let writer: DiskDatabaseWriter
    private let selections: DiskSelectionStorage
    private let home: String
    private var reader: DiskDatabase?
    private var readerLocation: URL?
    private var published: DiskSnapshot?
    private var watcher: DiskEvents?
    private var bootFlight: Task<Void, Never>?
    private var flight: Task<Void, Never>?
    private var relay: LoadProgressRelay?
    private var explicitlyInvalidated = false
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
        excluded = [destination.deletingLastPathComponent().path] + (root == "/" ? ["/System/Volumes", "/Volumes", "/dev", "/Network"] : [])
        writer = DiskDatabaseWriter(url: destination, root: root, excluded: excluded, home: home)
        selections = DiskSelectionStorage(url: destination.appendingPathExtension("selection"), root: root, home: home)
    }
    func invalidate() { explicitlyInvalidated = true }
    func mark(_ paths: [String], recursive: Bool = false) { watcher?.mark(paths, recursive: recursive) }
    func statusView() -> DiskSnapshot? {
        guard watcher?.hasChanges == false, !explicitlyInvalidated, flight == nil, !loadFailed else { return nil }
        return published
    }
    func navigation(folder: String? = nil) async -> DiskSnapshot {
        if published == nil { _ = await view() }
        if folder == nil, let published { return published }
        return (try? autoreleasepool { try reader?.snapshot(folder: folder, inventory: folder == root) }) ?? published ?? failureSnapshot()
    }
    func browse(_ request: DiskBrowseRequest) async -> DiskBrowsePage? {
        if published == nil { _ = await view() }
        if request.kind == .duplicates { startDuplicates(folder: request.folder, scoped: request.folder != root) }
        return try? autoreleasepool { request.kind == .duplicates ? try reader?.duplicatePage(request) : try reader?.browse(request) }
    }
    func selection(_ request: SelectionBulkRequest) async throws -> SelectionBulk {
        if published == nil { _ = await view() }
        if let flight { await flight.value }
        guard let source = readerLocation else { throw DiskDatabase.Failure(message: "Disk inventory is unavailable.") }
        return try await selections.apply(request, sourceURL: source)
    }
    func pinSelection(token: String) async throws { try await selections.pin(token: token) }
    func unpinSelection(token: String) async { await selections.unpin(token: token) }
    func selectionSummary(token: String) async throws -> SelectionBulk { try await selections.summary(token: token) }
    func selectionFiles(token: String, after: String = "", limit: Int = 200) async throws -> [DiskFile] { try await selections.files(token: token, after: after, limit: limit) }
    func selectionContains(token: String, path: String) async throws -> Bool { try await selections.contains(token: token, path: path) }
    func recordSelectionRemoved(token: String, paths: [String]) async throws { try await selections.recordRemoved(token: token, paths: paths) }
    func selectionAfterRemoving(token: String, paths: [String]) async throws -> SelectionBulk { try await selections.removing(token: token, paths: paths) }
    private func startDuplicates(folder: String, scoped: Bool) {
        guard flight == nil else { return }
        let revision = published?.index.revision
        guard duplicateScope != folder || duplicateRevision != revision else { return }
        let previous = duplicateFlight; previous?.cancel()
        duplicateScope = folder; duplicateRevision = revision
        duplicateUnknown = nil; duplicateFailure = false
        let writer = writer
        duplicateFlight = Task {
            _ = try? await previous?.value
            try Task.checkCancellation()
            do {
                let report = try await DiskDuplicatePipeline.run(storage: writer, folder: folder, scoped: scoped, published: { [weak self] in await self?.publishDuplicates() })
                duplicateUnknown = report.unknown
                publishDuplicates()
                return report
            } catch {
                if !(error is CancellationError) { duplicateFailure = true; duplicateScope = nil; publishDuplicates() }
                throw error
            }
        }
    }
    private func publishDuplicates() {
        if flight == nil, let reader, let snapshot = try? reader.snapshot() {
            var index = snapshot.index
            index.duplicateUnknown = duplicateUnknown; index.duplicateFailure = duplicateFailure
            published = DiskSnapshot(index)
        }
    }
    /// Resolves explicit IDs only. The caller must compare the host's ORIGINAL reviewed identity before execution.
    func selectedFiles(_ ids: Set<String>, folder: String, reviewed: [String: String]? = nil, origins: [String: String] = [:]) -> [DiskFile]? { try? reader?.selectedFiles(ids, folder: folder, reviewed: reviewed, origins: origins) }
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
    private func boot() async {
        do {
            let metadata = try await writer.boot(), location = await writer.location()
            reader = try DiskDatabase(url: location, root: root, home: home); readerLocation = location
            if try reader?.state() != nil { published = try reader?.snapshot() }
            watcher = DiskEvents(root: root, since: metadata.eventID, excluded: excluded)
        } catch { loadFailed = true; published = failureSnapshot() }
    }
    func view(progress: LoadProgressSink? = nil) async -> DiskSnapshot {
        if reader == nil {
            if let bootFlight { await bootFlight.value }
            else { let task = Task { await boot() }; bootFlight = task; await task.value; bootFlight = nil }
        }
        if let flight {
            if let progress { relay?.attach(progress) }
            if let published { return published }
            await flight.value; return published ?? failureSnapshot()
        }
        if let published, published.index.storageRevision == 4, !explicitlyInvalidated, !loadFailed, watcher?.hasChanges == false {
            progress?(1); startDuplicates(folder: root, scoped: false); return published
        }
        let reports = LoadProgressRelay(); if let progress { reports.attach(progress) }; relay = reports
        let task = Task {
            await reconcile(reports: reports)
            flight = nil; relay = nil
            if !loadFailed { startDuplicates(folder: root, scoped: false) }
        }
        flight = task
        // A completed cached projection is available immediately, while changed branches reconcile in the background.
        if let published { progress?(1); return published }
        await task.value
        return published ?? failureSnapshot()
    }
    private func reconcile(reports: LoadProgressRelay) async {
        var changes = DiskEvents.Changes()
        do {
            reports.report(0)
            let previous = duplicateFlight; previous?.cancel(); _ = try? await previous?.value
            duplicateFlight = nil; duplicateScope = nil
            watcher?.flush()
            changes = watcher?.drain() ?? .init()
            if explicitlyInvalidated { changes.shallow.insert(root); explicitlyInvalidated = false }
            let destination = try await writer.load(changes, progress: reports)
            if readerLocation != destination {
                reader = try DiskDatabase(url: destination, root: root, home: home); readerLocation = destination
                await writer.retireReaders()
            }
            if let snapshot = try reader?.snapshot() { published = snapshot }
            loadFailed = false; reports.report(1)
        } catch {
            watcher?.mark(Array(changes.shallow)); watcher?.mark(Array(changes.recursive), recursive: true)
            loadFailed = true
            var index = published?.index ?? DiskIndex(root: root); index.loadError = true; published = DiskSnapshot(index)
        }
    }
}
