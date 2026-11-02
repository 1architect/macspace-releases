import Foundation
import CoreServices
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceDiskMapPrivileged

actor DiskStore {
    private let root: String
    private let cache: URL
    private var published: DiskSnapshot?
    private let writer: DiskCacheWriter
    private var watcher: DiskEvents?
    private var flight: Task<DiskSnapshot, Error>?
    private var relay: LoadProgressRelay?
    private var explicitlyInvalidated = false
    private var ownershipCatalog: DiskApplications?
    private var ownershipEvidence = Set<DiskOwnershipClaim>()
    private var ownershipFlight: Task<DiskSnapshot, Never>?

    init(root: String = "/", cache: URL? = nil) {
        self.root = root
        let destination = cache ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.macspace.disk-map/Index-v2.scan")
        self.cache = destination
        writer = DiskCacheWriter(url: destination)
    }
    private var exclusions: [String] { [cache.deletingLastPathComponent().path] + (root == "/" ? ["/System/Volumes", "/Volumes", "/dev", "/Network"] : []) }
    func invalidate() { explicitlyInvalidated = true }
    func mark(_ paths: [String], recursive: Bool = false) { watcher?.mark(paths, recursive: recursive) }
    func status() -> DiskIndex? { statusView()?.index }
    func statusView() -> DiskSnapshot? { watcher?.hasChanges == false && !explicitlyInvalidated && flight == nil ? published : nil }
    func navigation() async -> DiskSnapshot {
        if let published { return published }
        return await view()
    }
    /// Evidence is interned once across the measured tree, then only newly measured directories are attributed.
    func recordOwnership(_ catalog: DiskApplications) async {
        if let ownershipFlight { _ = await ownershipFlight.value; return }
        let evidence = Set(catalog.apps.flatMap(\.ownership))
        ownershipCatalog = catalog
        guard let snapshot = published, snapshot.index.ownershipClaims == nil || evidence != ownershipEvidence else { return }
        let task = Task.detached(priority: .utility) {
            var index = snapshot.index
            index.ownershipClaims = DiskOwnership.assign(to: &index, catalog: catalog)
            return DiskSnapshot(index)
        }
        ownershipFlight = task
        let result = await task.value
        ownershipFlight = nil
        guard published?.index.revision == snapshot.index.revision else { return }
        ownershipEvidence = evidence; published = result
        await writer.submit(result.index)
    }
    func flushPersistence() async { await writer.flush() }
    func snapshot(progress: LoadProgressSink? = nil) async -> DiskIndex { await view(progress: progress).index }
    func view(progress: LoadProgressSink? = nil) async -> DiskSnapshot {
        if let flight { if let progress { relay?.attach(progress) }; return (try? await flight.value) ?? published ?? DiskSnapshot(DiskIndex(root: root)) }
        if published == nil, let saved = try? DiskCache.read(from: cache, root: root) { published = DiskSnapshot(saved) }
        if watcher == nil {
            watcher = DiskEvents(root: root, since: published?.index.eventID ?? 0, excluded: exclusions)
            // Drain the historical replay before treating a persisted snapshot as current.
            watcher?.flush()
        }
        var changes = watcher?.drain() ?? DiskEvents.Changes()
        if explicitlyInvalidated { changes.recursive.insert(root); explicitlyInvalidated = false }
        guard published == nil || !changes.shallow.isEmpty || !changes.recursive.isEmpty else { return published! }
        let old = published?.index ?? DiskIndex(root: root)
        let cursor = FSEventsGetCurrentEventId()
        let reports = LoadProgressRelay(); if let progress { reports.attach(progress) }; relay = reports
        let excluded = exclusions
        let captured = changes
        let catalog = ownershipCatalog
        let task = Task.detached(priority: .utility) {
            var scanner = DiskScanner(index: old, excluded: excluded, recordVisitedDirectories: false)
            var result = try scanner.scan(changed: captured.shallow, recursive: captured.recursive, progress: { reports.report($0) })
            if let catalog { result.ownershipClaims = DiskOwnership.assign(to: &result, catalog: catalog, paths: scanner.measuredDirectories) }
            result.eventID = cursor
            result.revision = old.revision + 1
            if old.root == "/" || old.root == DataVolume.path, let values = try? URL(fileURLWithPath: DataVolume.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]), let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage {
                result.volumeUsed = UInt64(max(0, Int64(total) - available))
            }
            return DiskSnapshot(result)
        }
        flight = task
        do {
            let result = try await task.value
            published = result
            await writer.submit(result.index)
        } catch {
            watcher?.mark(Array(changes.shallow))
            watcher?.mark(Array(changes.recursive), recursive: true)
        }
        flight = nil; relay = nil
        return published ?? DiskSnapshot(old)
    }
}
