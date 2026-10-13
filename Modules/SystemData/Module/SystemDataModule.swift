import AppKit
import Foundation
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceSystemDataPrivileged

@objc(MacSpaceSystemDataEntry)
public final class SystemDataEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { SystemDataModule() }
}

/// System Data: what fills it, and what is safe to free.
public struct SystemDataModule: MacSpaceModule {
    private let store = SystemDataStore()
    static let moduleID = "com.macspace.system-data"

    public init() {}

    public func invalidate() async { await store.invalidate() }

    public func tile(context: ModuleContext) async -> Tile {
        SystemDataScreenBuilder.tile(await snapshot(privileged: context.privileged))
    }

    public func screen(context: ModuleContext) async -> Screen {
        SystemDataScreenBuilder.screen(await snapshot(privileged: context.privileged))
    }

    /// The scan, with what the user chose on the caches page, which changes without the Mac changing.
    private func snapshot(maxAge: TimeInterval = SystemDataStore.defaultMaxAge, privileged: (any PrivilegedChannel)?) async -> SystemDataSnapshot {
        var snapshot = await store.snapshot(maxAge: maxAge, privileged: privileged)
        snapshot.choices = CacheChoices.load()
        return snapshot
    }

    /// Actions that change only what the user chose, not the Mac: the scan is kept.
    static let choiceActions: Set<String> = ["saveCacheChoice"]

    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        if Self.choiceActions.contains(request.actionID) { return Self.choose(request) }
        let result = await handle(request, context: context, progress: progress)
        // Forgotten before the result goes back, not after: the app reads the tile and the page again as soon as it has the result,
        // and a cache dropped later (in a task of its own) gave it the figures from before the action.
        await store.invalidate()
        return result
    }

    private func handle(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        let snapshot = await snapshot(maxAge: 600, privileged: context.privileged)
        switch request.actionID {
        case "clean":
            guard let id = request.parameters["id"], let item = snapshot.report.items.first(where: { $0.id == id }) else {
                return .failed(loc("Already gone"))
            }
            progress(ActionProgress(message: loc("Freeing space…")))
            return Self.clean([item])
        case "cleanReports":
            progress(ActionProgress(message: loc("Freeing space…")))
            return Self.cleanReports(snapshot.reports)
        case "openFullDiskAccess":
            NSWorkspace.shared.open(LivePermissionChecker.fullDiskAccessSettingsURL)
            return ActionResult(outcome: .succeeded, message: "", refresh: false)
        case "openSoftwareUpdate":
            if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") { NSWorkspace.shared.open(url) }
            return ActionResult(outcome: .succeeded, message: "", refresh: false)
        case "deleteStagedUpdate":
            progress(ActionProgress(message: loc("Freeing space…")))
            return await Self.deleteStagedUpdate(context.privileged)
        case "deleteWallpaperDownloads":
            progress(ActionProgress(message: loc("Freeing space…")))
            return await Self.deleteWallpaperDownloads(context.privileged)
        case "deleteVersions":
            progress(ActionProgress(message: loc("Freeing space…")))
            return await Self.deleteVersions(context.privileged)
        case "purgeAssets":
            progress(ActionProgress(message: loc("Freeing space…")))
            return Self.purgeAssets(store: store)
        case "freeCaches":
            progress(ActionProgress(message: loc("Freeing space…")))
            let ids = Set(Selection.ids(request.parameters["ids"]))
            return Self.freeCaches(CachesPage.entries(snapshot).filter { ids.contains($0.id) }, in: snapshot)
        case "openTrash":
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
            return ActionResult(outcome: .succeeded, message: "", refresh: false)
        case "cleanAll":
            let cleaned = Self.cleanSafe(snapshot, store: store, progress: progress)
            return .succeeded(Self.freedMessage(cleaned.freed), details: cleaned.details, freedBytes: cleaned.freed)
        default:
            return .failed(loc("Unknown action \(request.actionID)."))
        }
    }

    /// Automatic cleanup: what the main Free button frees (the caches chosen on the caches page, old reports, unused system assets).
    /// Never the version history or anything else that cannot be undone.
    public func autoClean(context: ModuleContext) async -> CleanupReport? {
        let snapshot = await snapshot(maxAge: 0, privileged: context.privileged)
        guard SystemDataScreenBuilder.cleanBytes(snapshot) >= SystemDataScreenBuilder.worthARow else { return nil }
        let cleaned = Self.cleanSafe(snapshot, store: store, progress: { _ in })
        await store.invalidate()
        return CleanupReport(freedBytes: cleaned.freed, summary: loc("Caches, old reports and unused system assets"), details: cleaned.details)
    }

    /// Everything Clean frees, measured on the volume over the whole run.
    static func cleanSafe(_ snapshot: SystemDataSnapshot, store: SystemDataStore, progress: ProgressSink) -> (freed: UInt64, details: [String]) {
        var details: [String] = []
        let before = DataVolume.freeBytes()
        let caches = CachesPage.chosen(snapshot)
        progress(ActionProgress(fraction: 0.1, message: loc("Freeing space…")))
        if !caches.isEmpty { details += freeCaches(caches, in: snapshot).details }
        progress(ActionProgress(fraction: 0.5, message: loc("Freeing space…")))
        if snapshot.reports.totalBytes > 0 { details += cleanReports(snapshot.reports).details }
        progress(ActionProgress(fraction: 0.7, message: loc("Freeing space…")))
        if (snapshot.purgeableAssetsBytes ?? 0) > 0, !snapshot.assetsRetrying, !snapshot.assetsHeld { details += purgeAssets(store: store).details }
        var freed: UInt64 = 0
        if let before, let after = DataVolume.settledFreeBytes(), after > before { freed = after - before }
        return (freed, details)
    }

    // MARK: Actions

    /// Keeps what the user chose on the caches page (`CacheChoices`): the checked caches and header boxes. The page is built again
    /// from the scan already made.
    static func choose(_ request: ActionRequest) -> ActionResult {
        var choices = CacheChoices.load()
        choices.chosen = Set(Selection.ids(request.parameters["ids"]))
        choices.all = Set(Selection.ids(request.parameters["all"]))
        choices.save()
        return ActionResult(outcome: .succeeded, message: "", refresh: true)
    }

    /// Frees caches of the caches page, each its own way: app caches read again first (`cleanAppCaches`), web and system caches
    /// through the cleaner, developer caches through `DeveloperCaches.free`, Homebrew's through its own cleanup. One whose app is
    /// open is skipped. The space freed is measured on the volume over the whole run.
    static func freeCaches(_ entries: [CacheEntry], in snapshot: SystemDataSnapshot) -> ActionResult {
        let chosen = entries.filter { !$0.open }
        guard !chosen.isEmpty else { return .failed(loc("Already gone")) }
        let ids = Set(chosen.map(\.id))
        let before = DataVolume.freeBytes()
        var details: [String] = []
        let apps = chosen.filter { $0.source == .app }.map(\.id)
        if !apps.isEmpty { details += cleanAppCaches(apps, in: snapshot).details }
        let items = snapshot.report.items.filter { item in chosen.contains { $0.id == item.id && ($0.source == .web || $0.source == .system) } }
        if !items.isEmpty { details += clean(items).details }
        let developer = snapshot.developerCaches.filter { ids.contains($0.id) }
        if !developer.isEmpty { details += DeveloperCaches.free(developer) }
        if let plan = snapshot.homebrew, ids.contains(CachesPage.homebrewOld) || ids.contains(CachesPage.homebrewDownloads) {
            details += cleanHomebrew(plan.brew, allDownloads: ids.contains(CachesPage.homebrewDownloads)).details
        }
        let freed = measuredFreed(before, DataVolume.settledFreeBytes())
        if !details.contains(where: { $0.hasPrefix("Deleted") || $0.hasPrefix("brew cleanup") }) {
            return ActionResult(outcome: .failed, message: loc("Couldn't free it"), details: details, refresh: true)
        }
        return .succeeded(freedMessage(freed), details: details, freedBytes: freed)
    }

    static func clean(_ items: [SystemDataItem]) -> ActionResult {
        let inspector = SystemDataInspector()
        let report = SystemDataCleaner().clean(items, allowedRoots: SystemDataCleaner.allowedRoots(inspector.locations))
        let failed = report.results.filter { !$0.deleted }
        let freed = measuredFreed(report.freeBytesBefore, report.freeBytesAfter)
        let details = report.results.map { "\($0.deleted ? "Deleted" : "Skipped"): \($0.itemID). \($0.detail)" }
        if !failed.isEmpty && failed.count == report.results.count {
            return ActionResult(outcome: .failed, message: loc("Couldn't free it"), details: details, refresh: true)
        }
        return .succeeded(freedMessage(freed), details: details, freedBytes: freed)
    }

    /// Deletes the chosen app caches. Each is read again first (`AppCaches.measure`): one that looks like data now stays. Then the cleaner's own checks, as for every cache: its app or tool not running, nothing open in
    /// it, renamed then deleted.
    static func cleanAppCaches(_ ids: [String], in snapshot: SystemDataSnapshot, now: Date = Date()) -> ActionResult {
        let chosen = snapshot.report.appCaches.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return .failed(loc("Already gone")) }
        var details: [String] = []
        var items: [SystemDataItem] = []
        for var cache in chosen {
            if let dates = AppCaches.measure(cache.path, now: now) {
                cache.lastChange = dates.lastChange
                cache.recentBytes = dates.recentBytes
                cache.dataLikeBytes = dates.dataLikeBytes
            }
            // Read again: one that now looks like data stays. One in use may go: the user chose it, and the page said it comes back.
            guard AppCaches.outcome(cache, now: now) != .heldBack else {
                details.append("Skipped: \(cache.id). It now holds media or documents.")
                continue
            }
            // Its owner by folder name (a tool, a bundle identifier) and by the app's own name, so the running check finds either.
            var owners = [cache.name.hasSuffix(".ShipIt") ? String(cache.name.dropLast(".ShipIt".count)) : cache.name]
            if cache.title != owners[0] { owners.append(cache.title) }
            items.append(SystemDataItem(id: cache.id, title: cache.title, kind: .appCache, paths: [cache.path], bytes: cache.bytes, readable: true,
                                        owners: owners, inUse: false,
                                        cleanup: SystemDataCleanup(kind: .deleteWhenNotRunning, description: "", command: nil), notes: []))
        }
        guard !items.isEmpty else { return ActionResult(outcome: .failed, message: loc("Couldn't free it"), details: details, refresh: true) }
        let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches").standardizedFileURL.path
        let report = SystemDataCleaner().clean(items, allowedRoots: [caches])
        details += report.results.map { "\($0.deleted ? "Deleted" : "Skipped"): \($0.itemID). \($0.detail)" }
        let freed = measuredFreed(report.freeBytesBefore, report.freeBytesAfter)
        if !report.results.contains(where: \.deleted) {
            return ActionResult(outcome: .failed, message: loc("Couldn't free it"), details: details, refresh: true)
        }
        return .succeeded(freedMessage(freed), details: details, freedBytes: freed)
    }

    /// Runs Homebrew's cleanup (`HomebrewCleanup`), unless Homebrew is busy: a cleanup then would delete what an install is unpacking.
    static func cleanHomebrew(_ brew: String, allDownloads: Bool) -> ActionResult {
        guard let processes = ProcessCheck.live.processes() else { return .failed(loc("Nothing was freed: MacSpace couldn't check which apps are open.")) }
        if HomebrewCleanup.isRunning(brew, processes: processes) { return .failed(loc("Homebrew is busy. Try again when it's done.")) }
        let before = DataVolume.freeBytes()
        let run = HomebrewCleanup.clean(brew, allDownloads: allDownloads)
        let freed = measuredFreed(before, DataVolume.settledFreeBytes())
        var details = ["brew cleanup\(allDownloads ? " --prune=all" : "") with HOMEBREW_NO_AUTOREMOVE, HOMEBREW_NO_AUTO_UPDATE and HOMEBREW_NO_ANALYTICS."]
        if let reported = run.freed { details.append("Homebrew reported \(ByteFormat.string(reported)).") }
        guard run.succeeded else {
            if let error = run.error { details.append(error) }
            return ActionResult(outcome: .failed, message: loc("Homebrew's cleanup failed"), details: details, refresh: true)
        }
        return .succeeded(freedMessage(freed ?? run.freed), details: details, freedBytes: freed)
    }

    static func cleanReports(_ plan: CleanupPlan) -> ActionResult {
        let result = DiagnosticReportCleaner(directories: []).execute(plan)
        let details = result.failed.map { "Could not delete \($0.key): \($0.value)" }
        return .succeeded(freedMessage(result.freedBytes), details: details, freedBytes: result.freedBytes)
    }

    /// Deletes the Versions store through the helper. The freed space is measured on the volume, as for every other cleanup.
    static func deleteVersions(_ channel: (any PrivilegedChannel)?) async -> ActionResult {
        guard let channel else { return .failed(loc("Install the helper in Settings")) }
        let before = DataVolume.freeBytes()
        let result: VersionStoreResult
        do { result = try await channel.perform(VersionStoreResult.self, operation: SystemDataPrivilegedOperations.deleteVersions) }
        catch { return .failed(loc("Couldn't free it"), details: [error.localizedDescription]) }
        guard result.executed else { return .failed(loc("Couldn't free it"), details: result.error.map { [$0] } ?? []) }
        let measured = measuredFreed(before, DataVolume.freeBytes())
        let stored = (result.bytesBefore ?? 0) > (result.bytesAfter ?? 0) ? (result.bytesBefore ?? 0) - (result.bytesAfter ?? 0) : 0
        var details = ["Removed \(result.removedEntries) item(s) from the store; it went from \(ByteFormat.string(result.bytesBefore ?? 0)) to \(ByteFormat.string(result.bytesAfter ?? 0))."]
        if let error = result.error { details.append(error) }
        let message = freedMessage(measured ?? stored)
        return ActionResult(outcome: result.error == nil ? .succeeded : .needsAttention, message: message, details: details, freedBytes: measured)
    }

    /// Deletes the files of an update that is already installed, through the helper (which checks they are really a leftover).
    static func deleteStagedUpdate(_ channel: (any PrivilegedChannel)?) async -> ActionResult {
        guard let channel else { return .failed(loc("Install the helper in Settings")) }
        let before = DataVolume.freeBytes()
        let result: StagedUpdateResult
        do { result = try await channel.perform(StagedUpdateResult.self, operation: SystemDataPrivilegedOperations.deleteStagedUpdate) }
        catch { return .failed(loc("Couldn't free it"), details: [error.localizedDescription]) }
        guard result.executed else { return .failed(loc("Couldn't free it"), details: result.error.map { [$0] } ?? []) }
        let stored = (result.bytesBefore ?? 0) > (result.bytesAfter ?? 0) ? (result.bytesBefore ?? 0) - (result.bytesAfter ?? 0) : 0
        let message = freedMessage(measuredFreed(before, DataVolume.freeBytes()) ?? stored)
        return ActionResult(outcome: result.error == nil ? .succeeded : .needsAttention, message: message, details: result.error.map { [$0] } ?? [],
                            freedBytes: measuredFreed(before, DataVolume.freeBytes()))
    }

    /// Deletes the wallpaper and screen saver downloads idleassetsd left unfinished, through the helper, which finds the folders and
    /// picks the files itself (older than its retention window). Never part of Clean or automatic cleaning.
    static func deleteWallpaperDownloads(_ channel: (any PrivilegedChannel)?) async -> ActionResult {
        guard let channel else { return .failed(loc("Install the helper in Settings")) }
        let before = DataVolume.freeBytes()
        let result: WallpaperDownloadResult
        do { result = try await channel.perform(WallpaperDownloadResult.self, operation: SystemDataPrivilegedOperations.deleteWallpaperDownloads) }
        catch { return .failed(loc("Couldn't free it"), details: [error.localizedDescription]) }
        guard result.executed else { return .failed(loc("Couldn't free it"), details: result.error.map { [$0] } ?? []) }
        let measured = measuredFreed(before, result.removedFiles > 0 ? DataVolume.settledFreeBytes() : DataVolume.freeBytes())
        var details = ["Removed \(result.removedFiles) unfinished download(s) from \(result.folders) folder(s), \(ByteFormat.string(result.removedBytes)) on disk."]
        if result.keptRecentFiles > 0 {
            details.append("Kept \(result.keptRecentFiles) download(s) newer than \(WallpaperDownloadCleaner.retentionDays) days.")
        }
        if result.refusedEntries > 0 { details.append("Refused \(result.refusedEntries) item(s) that are not regular files.") }
        if let error = result.error { details.append(error) }
        let message = freedMessage(measured ?? result.removedBytes)
        return ActionResult(outcome: result.error == nil ? .succeeded : .needsAttention, message: message, details: details, freedBytes: measured)
    }

    /// macOS is asked again right before; if it keeps them, again in the background, and the page reads the Mac again once it lets
    /// them go (`PurgeRun`).
    static func purgeAssets(store: SystemDataStore) -> ActionResult {
        let outcome = PurgeRun(service: CacheDeleteService.mobileAsset).run { freed in
            // macOS let them go later, when asked again in the background.
            CleanupHistory.shared.record(moduleID: Self.moduleID, moduleName: "System Data", freedBytes: freed, trigger: .background,
                                         summary: loc("Unused system assets"))
            await store.invalidate()
        }
        return PurgeRun.result(outcome, what: "unused system assets")
    }

    static func measuredFreed(_ before: UInt64?, _ after: UInt64?) -> UInt64? {
        guard let before, let after else { return nil }
        return after > before ? after - before : 0
    }

    /// What a cleanup tells the user: the space it freed, measured on the volume, and nothing else.
    static func freedMessage(_ freed: UInt64?) -> String { PurgeRun.freedMessage(freed ?? 0) }
}
