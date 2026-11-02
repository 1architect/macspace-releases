import Foundation
import CoreServices
import Darwin
import MacSpacePlatform
import MacSpaceSdk

/// A single serial writer owns transactions. The presentation actor has its own bounded-cache reader,
/// so navigation neither retains whole-index snapshots nor waits for disk scans or ownership writes.
private actor DiskDatabaseWriter {
    private var database: DiskDatabase?
    private let url: URL
    private var active: URL?
    private var retired: [URL] = []
    private var pointer: URL { url.appendingPathExtension("current") }
    private let legacy: URL
    private let root: String
    private let excluded: [String]
    init(url: URL, legacy: URL, root: String, excluded: [String]) { self.url = url; self.legacy = legacy; self.root = root; self.excluded = excluded }
    func boot(progress: LoadProgressSink?) throws -> DiskIndex {
        let name = (try? String(contentsOf: pointer, encoding: .utf8)) ?? ""
        let destination = !name.isEmpty && !name.contains("/") && name.hasPrefix(url.lastPathComponent) ? url.deletingLastPathComponent().appendingPathComponent(name) : url
        active = destination
        let db = try DiskDatabase(url: destination, root: root); database = db
        if try db.state() == nil { try db.clearIncomplete() }
        if try db.state() == nil, FileManager.default.fileExists(atPath: legacy.path) { try? db.importLegacy(legacy) }
        if try db.state() == nil {
            try db.clearIncomplete()
            var scanner = DiskDatabaseScanner(db: db, excluded: excluded)
            try scanner.scan(.init(), cursor: FSEventsGetCurrentEventId(), progress: progress)
        }
        return try db.state() ?? DiskIndex(root: root)
    }
    func location() -> URL { active ?? url }
    func scan(_ changes: DiskEvents.Changes, progress: LoadProgressSink?) throws -> URL {
        guard let database, let active else { return url }
        // Large/subtree reads prepare a new on-disk generation. Readers keep the previous committed map,
        // while bounded commits/checkpoints prevent a disk-sized dirty-write spike in the app.
        if !changes.recursive.isEmpty || changes.shallow.count > 128 {
            let destination = url.appendingPathExtension(UUID().uuidString)
            let full = changes.recursive.contains(root)
            if !full {
                try database.seal()
                guard clonefile(active.path, destination.path, 0) == 0 else {
                    try FileManager.default.copyItem(at: active, to: destination)
                    return try prepareGeneration(destination, previous: active, changes: changes, progress: progress)
                }
            }
            if full {
                let next = try DiskDatabase(url: destination, root: root)
                next.unpublished = true
                if let state = try database.state() { try next.saveState(state) }
                return try finishGeneration(next, at: destination, previous: active, changes: changes, progress: progress)
            }
            return try prepareGeneration(destination, previous: active, changes: changes, progress: progress)
        }
        var scanner = DiskDatabaseScanner(db: database, excluded: excluded)
        try scanner.scan(changes, cursor: FSEventsGetCurrentEventId(), progress: progress)
        return active
    }
    private func prepareGeneration(_ destination: URL, previous: URL, changes: DiskEvents.Changes, progress: LoadProgressSink?) throws -> URL {
        let next = try DiskDatabase(url: destination, root: root); next.unpublished = true
        return try finishGeneration(next, at: destination, previous: previous, changes: changes, progress: progress)
    }
    private func finishGeneration(_ next: DiskDatabase, at destination: URL, previous: URL, changes: DiskEvents.Changes, progress: LoadProgressSink?) throws -> URL {
        var scanner = DiskDatabaseScanner(db: next, excluded: excluded)
        try scanner.scan(changes, cursor: FSEventsGetCurrentEventId(), progress: progress)
        try next.seal(); next.unpublished = false
        try destination.lastPathComponent.write(to: pointer, atomically: true, encoding: .utf8)
        database = next; active = destination; retired.append(previous)
        return destination
    }
    func retireReaders() {
        for old in retired {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: old.path + suffix) }
        }
        retired.removeAll()
    }
    func ownership(_ catalog: DiskApplications) throws { try database?.recordOwnership(catalog) }
    func flush() { try? database?.checkpoint() }
}

actor DiskStore {
    private let root: String
    private let url: URL
    private let excluded: [String]
    private let writer: DiskDatabaseWriter
    private var reader: DiskDatabase?
    private var published: DiskSnapshot?
    private var watcher: DiskEvents?
    private var flight: Task<Void, Never>?
    private var relay: LoadProgressRelay?
    private var explicitlyInvalidated = false
    private var evidenceRevision: Date?
    private var ownershipFlight: Task<Void, Never>?

    init(root: String = "/", cache: URL? = nil) {
        self.root = root
        let legacy = cache ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.macspace.disk-map/Index-v2.scan")
        let destination = cache.map { $0.appendingPathExtension("sqlite") } ?? legacy.deletingLastPathComponent().appendingPathComponent("Index-v3.sqlite")
        url = destination
        excluded = [legacy.deletingLastPathComponent().path] + (root == "/" ? ["/System/Volumes", "/Volumes", "/dev", "/Network"] : [])
        writer = DiskDatabaseWriter(url: destination, legacy: legacy, root: root, excluded: excluded)
    }
    func invalidate() { explicitlyInvalidated = true }
    func mark(_ paths: [String], recursive: Bool = false) { watcher?.mark(paths, recursive: recursive) }
    func status() -> DiskIndex? { statusView()?.index }
    func statusView() -> DiskSnapshot? { watcher?.hasChanges == false && !explicitlyInvalidated && flight == nil ? published : nil }
    func navigation(folder: String? = nil) async -> DiskSnapshot {
        if folder == nil, let published { return published }
        if let reader { return (try? autoreleasepool { try reader.snapshot(folder: folder, inventory: folder == nil || folder == root) }) ?? published ?? DiskSnapshot(DiskIndex(root: root)) }
        _ = await view()
        return (try? reader?.snapshot(folder: folder, inventory: folder == nil || folder == root)) ?? published ?? DiskSnapshot(DiskIndex(root: root))
    }
    func recordOwnership(_ catalog: DiskApplications) async {
        guard evidenceRevision != catalog.catalogReadAt else { return }
        if let ownershipFlight { await ownershipFlight.value; return }
        let writer = writer
        let task = Task.detached(priority: .utility) { try? await writer.ownership(catalog) }
        ownershipFlight = Task { _ = await task.value }
        _ = await task.value
        evidenceRevision = catalog.catalogReadAt; ownershipFlight = nil
        if let reader { published = try? autoreleasepool { try reader.snapshot() } }
    }
    func flushPersistence() async { await writer.flush() }
    func snapshot(progress: LoadProgressSink? = nil) async -> DiskIndex { await view(progress: progress).index }
    func view(progress: LoadProgressSink? = nil) async -> DiskSnapshot {
        if let flight { if let progress { relay?.attach(progress) }; await flight.value; return published ?? DiskSnapshot(DiskIndex(root: root)) }
        let reports = LoadProgressRelay(); if let progress { reports.attach(progress) }; relay = reports
        let task = Task { await reconcile(reports: reports) }
        flight = task
        await task.value
        flight = nil; relay = nil
        return published ?? DiskSnapshot(DiskIndex(root: root))
    }
    private func reconcile(reports: LoadProgressRelay) async {
        do {
            if reader == nil {
                let metadata = try await writer.boot(progress: { reports.report($0) })
                reader = try DiskDatabase(url: await writer.location(), root: root)
                watcher = DiskEvents(root: root, since: metadata.eventID, excluded: excluded)
                watcher?.flush()
            }
            var changes = watcher?.drain() ?? .init()
            if explicitlyInvalidated { changes.recursive.insert(root); explicitlyInvalidated = false }
            if !changes.shallow.isEmpty || !changes.recursive.isEmpty {
                do {
                    let before = await writer.location()
                    let destination = try await writer.scan(changes, progress: { reports.report($0) })
                    if before != destination { reader = try DiskDatabase(url: destination, root: root); await writer.retireReaders() }
                }
                catch { watcher?.mark(Array(changes.shallow)); watcher?.mark(Array(changes.recursive), recursive: true); throw error }
                published = nil
            }
            if published == nil { published = try reader?.snapshot() }
        } catch { /* Keep the last committed page; a subsequent refresh retries transient I/O failures. */ }
    }
}
