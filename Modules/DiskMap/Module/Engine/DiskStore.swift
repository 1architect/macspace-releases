import Foundation
import CoreServices
import MacSpacePlatform
import MacSpaceSdk

actor DiskStore {
    private let root: String
    private let cache: URL
    private var index: DiskIndex?
    private var watcher: DiskEvents?
    private var flight: Task<DiskIndex, Error>?
    private var relay: LoadProgressRelay?
    private var explicitlyInvalidated = false

    init(root: String = "/", cache: URL? = nil) {
        self.root = root
        self.cache = cache ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.macspace.disk-map/Index-v2.scan")
    }
    private var exclusions: [String] { [cache.deletingLastPathComponent().path] + (root == "/" ? ["/System/Volumes", "/Volumes", "/dev", "/Network"] : []) }
    func invalidate() { explicitlyInvalidated = true }
    func mark(_ paths: [String], recursive: Bool = false) { watcher?.mark(paths, recursive: recursive) }
    func status() -> DiskIndex? { watcher?.hasChanges == false && !explicitlyInvalidated && flight == nil ? index : nil }

    func snapshot(progress: LoadProgressSink? = nil) async -> DiskIndex {
        if let flight { if let progress { relay?.attach(progress) }; return (try? await flight.value) ?? index ?? DiskIndex(root: root) }
        if index == nil { index = try? DiskCache.read(from: cache, root: root) }
        if watcher == nil {
            watcher = DiskEvents(root: root, since: index?.eventID ?? 0, excluded: exclusions)
            // Drain the historical replay before treating a persisted snapshot as current.
            watcher?.flush()
        }
        var changes = watcher?.drain() ?? DiskEvents.Changes()
        if explicitlyInvalidated { changes.recursive.insert(root); explicitlyInvalidated = false }
        guard index == nil || !changes.shallow.isEmpty || !changes.recursive.isEmpty else { return index! }
        let old = index ?? DiskIndex(root: root)
        let cursor = FSEventsGetCurrentEventId()
        let reports = LoadProgressRelay(); if let progress { reports.attach(progress) }; relay = reports
        let excluded = exclusions
        let captured = changes
        let task = Task.detached(priority: .utility) {
            var scanner = DiskScanner(index: old, excluded: excluded, recordVisitedDirectories: false)
            var result = try scanner.scan(changed: captured.shallow, recursive: captured.recursive, progress: { reports.report($0) })
            result.eventID = cursor
            result.revision = old.revision + 1
            if old.root == "/" || old.root == DataVolume.path, let values = try? URL(fileURLWithPath: DataVolume.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]), let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage {
                result.volumeUsed = UInt64(max(0, Int64(total) - available))
            }
            return result
        }
        flight = task
        do {
            let result = try await task.value
            index = result
            try? DiskCache.write(result, to: cache)
        } catch {
            watcher?.mark(Array(changes.shallow))
            watcher?.mark(Array(changes.recursive), recursive: true)
        }
        flight = nil; relay = nil
        return index ?? old
    }
}
