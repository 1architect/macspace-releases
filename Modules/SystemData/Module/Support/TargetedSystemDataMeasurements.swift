import Darwin
import Foundation
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceSystemDataPrivileged

/// Remeasure only what an action touched. Unrelated scan data and the scan's age stay intact.
enum TargetedSystemDataMeasurements {
    static func itemIDs(_ request: ActionRequest, snapshot: SystemDataSnapshot) -> Set<String> {
        switch request.actionID {
        case "clean": return Set([request.parameters["id"]].compactMap { $0 })
        case "cleanReports": return ["reports:diagnostic"]
        case "deleteVersions": return ["versions:documents"]
        case "deleteStagedUpdate": return ["update:staged"]
        case "deleteWallpaperDownloads": return Set(snapshot.report.items.filter { $0.id.hasPrefix(SystemDataScreenBuilder.wallpaperDownloadsPrefix) }.map(\.id))
        case "emptyTrash": return Set(snapshot.report.items.filter { $0.kind == .trash }.map(\.id))
        case "eraseUnifiedLog": return [SystemDataScreenBuilder.unifiedLogID]
        case "deleteSymbolicationCache": return [SystemDataScreenBuilder.symbolsID]
        case "purgeAssets", "releaseUnusedModels": return ["assets:system"]
        case "cleanAll": return ["reports:diagnostic", "assets:system", SystemDataScreenBuilder.unifiedLogID]
        default: return []
        }
    }

    static func reconcile(_ snapshot: SystemDataSnapshot, request: ActionRequest,
                          privileged: (any PrivilegedChannel)?) async -> SystemDataSnapshot {
        let entries: [CacheEntry]
        if request.actionID == "freeCaches" {
            let selected = Set(Selection.ids(request.parameters["ids"]))
            entries = CachesPage.entries(snapshot).filter { selected.contains($0.id) }.flatMap(\.parts)
        } else { entries = request.actionID == "cleanAll" ? CachesPage.chosen(snapshot).flatMap(\.parts) : [] }
        var ids = itemIDs(request, snapshot: snapshot)
        ids.formUnion(entries.filter { $0.within == $0.id }.map(\.id))
        if entries.contains(where: { $0.source == .homebrew }) {
            ids.formUnion(["packages:homebrew", "appcache:Homebrew"])
        }
        let paths = Array(Set(snapshot.report.items.filter { ids.contains($0.id) }.flatMap(\.paths) + entries.flatMap(\.paths)))
        // What the system assets became is read beside the targets: one after the other, the assets folder was walked twice in a row.
        let assetsChanged = ["purgeAssets", "releaseUnusedModels", "cleanAll"].contains(request.actionID)
        async let families = assetsChanged ? Task.detached(priority: .utility) { AssetFamilyScanner().scan() }.value : nil
        async let purgeable = assetsChanged ? Task.detached(priority: .utility) { SystemDataStore.livePurgeable() }.value : nil
        let reads = await Task.detached(priority: .utility) { () -> [String: FileTreeSize] in
            let found = LockedArray<FileTreeSize?>(repeating: nil, count: paths.count)
            let next = JobCounter(count: paths.count)
            DispatchQueue.concurrentPerform(iterations: min(3, max(paths.count, 1))) { _ in
                while let index = next.next() {
                    let path = paths[index]
                    if let size = FileTreeSizer(countsPurgeable: true, refusesLinks: true).size(at: URL(fileURLWithPath: path)), size.unreadableFolders == 0 {
                        found.set(index, size)
                        continue
                    }
                    var info = stat()
                    // Unreadable is unknown, never an empty folder.
                    if lstat(path, &info) != 0, errno == ENOENT { found.set(index, FileTreeSize(logicalBytes: 0, allocatedBytesEstimate: 0)) }
                }
            }
            return Dictionary(uniqueKeysWithValues: zip(paths, found.values).compactMap { path, size in size.map { (path, $0) } })
        }.value
        var sizes = reads
        let root = paths.filter { sizes[$0] == nil && RootMeasuredLocations.isAllowed($0) }
        if let privileged, !root.isEmpty,
           let data = try? await privileged.perform(operation: SystemDataPrivilegedOperations.measure, arguments: ["paths": root.sorted().joined(separator: "\n")]),
           let response = try? JSONDecoder().decode(RootMeasurementResponse.self, from: data) {
            for (path, bytes) in response.sizes {
                sizes[path] = FileTreeSize(logicalBytes: bytes, allocatedBytesEstimate: bytes, purgeableBytes: response.purgeable?[path] ?? 0)
            }
        }
        let targetSizes = sizes
        let assets = assetsChanged ? (families: await families, purgeable: await purgeable) : nil
        return await Task.detached(priority: .utility) {
            var updated = applying(targetSizes, itemIDs: ids, entries: entries, to: snapshot)
            if request.actionID == "cleanReports" || request.actionID == "cleanAll" {
                updated.reports = DiagnosticReportCleaner(directories: DiagnosticReportCleaner.standardDirectories(home: FileManager.default.homeDirectoryForCurrentUser))
                    .plan(olderThanDays: snapshot.reports.olderThanDays)
            }
            if entries.contains(where: { $0.source == .homebrew }) { updated.homebrew = HomebrewCleanup.plan() }
            if let assets {
                updated.purgeableAssetsBytes = assets.purgeable
                updated.assetFamilies = assets.families ?? updated.assetFamilies
                updated.assetsRetrying = PurgeRetrier.shared.isRetrying(CacheDeleteService.mobileAsset)
                updated.assetsHeld = SystemAssetGuard.holdsAssets
                updated.ownerCleanupAvailable = AssetModelCleanup.refusal(.released) == nil
            }
            return updated
        }.value
    }

    static func applying(_ sizes: [String: FileTreeSize], itemIDs: Set<String>, entries: [CacheEntry] = [],
                         to snapshot: SystemDataSnapshot) -> SystemDataSnapshot {
        var updated = snapshot
        let before = SystemDataScreenBuilder.measured(snapshot.report).reduce(0) { $0 + SystemDataScreenBuilder.counted($1, snapshot) }
        func size(_ paths: [String]) -> (bytes: UInt64, purgeable: UInt64)? {
            guard !paths.isEmpty, paths.allSatisfy({ sizes[$0] != nil }) else { return nil }
            return paths.reduce((0, 0)) { ($0.0 + sizes[$1]!.bytes, $0.1 + sizes[$1]!.purgeableBytes) }
        }
        for index in updated.report.items.indices where itemIDs.contains(updated.report.items[index].id) {
            let item = updated.report.items[index]
            guard let measured = size(item.paths) else { continue }
            updated.report.items[index].bytes = measured.bytes
            updated.report.items[index].purgeableBytes = measured.purgeable
            updated.report.items[index].elsewhereBytes = item.elsewhereBytes.map { $0 >= (item.bytes ?? 0) ? measured.bytes : min($0, measured.bytes) }
            if item.expectedReclaimBytes != nil {
                updated.report.items[index].expectedReclaimBytes = item.kind == .codeSignClone
                    ? item.paths.compactMap { FileTreeSizer.unsharedBytes(at: $0) }.reduce(0, +) : measured.bytes
            }
        }
        for entry in entries {
            guard let measured = size(entry.paths) else { continue }
            if let index = updated.report.appCaches.firstIndex(where: { $0.id == entry.id }) {
                updated.report.appCaches[index].bytes = measured.bytes
                updated.report.appCaches[index].recentBytes = min(updated.report.appCaches[index].recentBytes, measured.bytes)
                updated.report.appCaches[index].dataLikeBytes = min(updated.report.appCaches[index].dataLikeBytes, measured.bytes)
            }
            if let within = entry.within, !itemIDs.contains(within), let parent = updated.report.items.firstIndex(where: { $0.id == within }) {
                let item = updated.report.items[parent]
                let oldBytes = item.bytes ?? 0
                let bytes = measured.bytes <= entry.bytes ? oldBytes - min(oldBytes, entry.bytes - measured.bytes) : oldBytes + (measured.bytes - entry.bytes)
                updated.report.items[parent].bytes = bytes
                updated.report.items[parent].cachesBytes = item.cachesBytes.map { old in
                    measured.bytes <= entry.bytes ? old - min(old, entry.bytes - measured.bytes) : old + (measured.bytes - entry.bytes)
                }
                updated.report.items[parent].purgeableBytes = item.purgeableBytes.map { min($0, bytes) }
                updated.report.items[parent].elsewhereBytes = item.elsewhereBytes.map { $0 >= oldBytes ? bytes : min($0, bytes) }
            }
            if let index = updated.developerCaches.firstIndex(where: { $0.id == entry.id }) { updated.developerCaches[index].bytes = measured.bytes }
        }
        updateTotals(&updated, previousCounted: before)
        return updated
    }

    /// Reconcile the displayed baseline using the same scoped measurements as the graph. The next full scan replaces this
    /// estimate with macOS's categories again; a volume-wide free-space delta never changes individual items.
    static func updateTotals(_ snapshot: inout SystemDataSnapshot, previousCounted: UInt64) {
        let after = SystemDataScreenBuilder.measured(snapshot.report).reduce(0) { $0 + SystemDataScreenBuilder.counted($1, snapshot) }
        if let used = snapshot.settings?.used {
            snapshot.settings?.used = after <= previousCounted ? used - min(used, previousCounted - after) : used + (after - previousCounted)
        }
        snapshot.report.measuredBytes = snapshot.report.items.compactMap(\.bytes).reduce(0, +)
    }
}
