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
        SystemDataScreenBuilder.tile(await snapshot(context: context))
    }

    public func screen(context: ModuleContext) async -> Screen {
        SystemDataScreenBuilder.screen(await snapshot(context: context))
    }

    /// The scan, with what the user chose on the caches page and in Settings, which changes without the Mac changing.
    private func snapshot(maxAge: TimeInterval = SystemDataStore.defaultMaxAge, context: ModuleContext) async -> SystemDataSnapshot {
        var snapshot = await store.snapshot(maxAge: maxAge, privileged: context.privileged)
        snapshot.choices = CacheChoices.load()
        snapshot.logFloor = SystemLogFloor.load()
        snapshot.cleaner = CacheCleaner.read(context)
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
        let snapshot = await snapshot(maxAge: 600, context: context)
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
            // Confirmed with the open apps named (`CachesPage.quitNote`): they quit.
            let ids = Set(Selection.ids(request.parameters["ids"]))
            return await Self.freeCaches(CachesPage.entries(snapshot).filter { ids.contains($0.id) }, in: snapshot, quitApps: true, progress: progress)
        case "openCleaner":
            if case let .app(_, url) = snapshot.cleaner { _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
            return ActionResult(outcome: .succeeded, message: "", refresh: false)
        case "openTrash":
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
            return ActionResult(outcome: .succeeded, message: "", refresh: false)
        case "emptyTrash":
            progress(ActionProgress(message: loc("Freeing space…")))
            return Self.emptyTrash()
        case "eraseUnifiedLog":
            progress(ActionProgress(message: loc("Freeing space…")))
            return await Self.eraseUnifiedLog(context.privileged)
        case "deleteSymbolicationCache":
            progress(ActionProgress(message: loc("Freeing space…")))
            return await Self.deleteSymbolicationCache(context.privileged)
        case "cleanAll":
            let log = SystemDataScreenBuilder.unifiedLogRow(snapshot) != nil
            var cleaned = await Self.cleanSafe(snapshot, store: store, quitApps: true, progress: progress, span: log ? 0...0.8 : 0...1)
            // The system log too, which only this button and its own row erase: automatic cleaning never does (it cannot be undone).
            if log {
                progress(ActionProgress(fraction: 0.85, message: loc("Freeing space…")))
                let erased = await Self.eraseUnifiedLog(context.privileged)
                cleaned.freed += erased.freedBytes ?? 0
                cleaned.details += erased.details
                progress(ActionProgress(fraction: 1, message: loc("Freeing space…")))
            }
            return .succeeded(Self.freedMessage(cleaned.freed), details: cleaned.details, freedBytes: cleaned.freed)
        default:
            return .failed(loc("Unknown action \(request.actionID)."))
        }
    }

    /// Automatic cleanup: what the main Free button frees (the caches chosen on the caches page, old reports, unused system assets).
    /// Never the version history or anything else that cannot be undone.
    public func autoClean(context: ModuleContext) async -> CleanupReport? {
        let snapshot = await snapshot(maxAge: 0, context: context)
        guard SystemDataScreenBuilder.cleanBytes(snapshot) >= SystemDataScreenBuilder.worthARow else { return nil }
        // It quits no app: the open apps' caches wait for a Free the user confirms.
        let cleaned = await Self.cleanSafe(snapshot, store: store, quitApps: false, progress: { _ in })
        await store.invalidate()
        return CleanupReport(freedBytes: cleaned.freed, summary: snapshot.cleaner == .macSpace ? loc("Caches, old reports and unused system assets") : loc("Old reports and unused system assets"), details: cleaned.details)
    }

    /// Everything Free frees, measured on the volume over the whole run. The chosen caches of open apps go only when `quitApps` (the
    /// user confirmed, with those apps named).
    static func cleanSafe(_ snapshot: SystemDataSnapshot, store: SystemDataStore, quitApps: Bool, progress: @escaping ProgressSink,
                          span: ClosedRange<Double> = 0...1) async -> (freed: UInt64, details: [String]) {
        func at(_ share: Double) -> Double { span.lowerBound + (span.upperBound - span.lowerBound) * share }
        var details: [String] = []
        let before = DataVolume.freeBytes()
        let caches = CachesPage.chosen(snapshot)
        progress(ActionProgress(fraction: at(0.03), message: loc("Freeing space…")))
        if !caches.isEmpty { details += await freeCaches(caches, in: snapshot, quitApps: quitApps, progress: progress, span: at(0.03)...at(0.6)).details }
        progress(ActionProgress(fraction: at(0.6), message: loc("Freeing space…")))
        if snapshot.reports.totalBytes > 0 { details += cleanReports(snapshot.reports).details }
        progress(ActionProgress(fraction: at(0.75), message: loc("Freeing space…")))
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

    /// Frees the chosen caches one by one, telling the page which are gone as it goes (`ActionProgress.finished`), so their rows leave
    /// one after the other. With `quitApps` (Free was confirmed with the open apps named, `CachesPage.quitNote`), those apps are quit
    /// first, all of them before any cache, and are not opened again: the user opens them when they want. One that does not quit (it
    /// asked to save and the user kept it open) keeps its cache. Without it (automatic cleaning), the open apps' caches stay.
    /// `span` is the part of the action's progress bar this takes.
    static func freeCaches(_ entries: [CacheEntry], in snapshot: SystemDataSnapshot, quitApps: Bool, progress: @escaping ProgressSink,
                           span: ClosedRange<Double> = 0...1) async -> ActionResult {
        var entries = entries
        guard !entries.isEmpty else { return .failed(loc("Already gone")) }
        let working = loc("Freeing space…")
        // The bar moves at once, and through the quitting too: an app that asks to save can take a while, and the button stood still.
        func at(_ share: Double) -> Double { span.lowerBound + (span.upperBound - span.lowerBound) * share }
        let quitting = quitApps ? entries.indices.filter { entries[$0].open } : []
        let quitShare = quitting.isEmpty ? 0.0 : 0.3
        progress(ActionProgress(fraction: at(0.03), message: working))
        for (step, index) in quitting.enumerated() {
            if await AppQuitter.quit(entries[index].owners, exact: entries[index].exactOwners) { entries[index].open = false }
            progress(ActionProgress(fraction: at(0.03 + (quitShare - 0.03) * Double(step + 1) / Double(quitting.count)), message: working))
        }
        let before = DataVolume.freeBytes()
        var details: [String] = []
        var finished: [String] = []
        for (index, entry) in entries.enumerated() {
            progress(ActionProgress(fraction: at(quitShare + (1 - quitShare) * Double(index) / Double(entries.count)), message: working, finished: finished))
            guard !entry.open else {
                details.append("Skipped: \(entry.id). Its app is open.")
                continue
            }
            // Homebrew's two rows are one cleanup: the downloads' takes the old versions too.
            if entry.id == CachesPage.homebrewOld, entries.contains(where: { $0.id == CachesPage.homebrewDownloads }) { continue }
            let freed = freeOne(entry, in: snapshot)
            details += freed.details
            if freed.done {
                finished.append(entry.id)
                if entry.id == CachesPage.homebrewDownloads, entries.contains(where: { $0.id == CachesPage.homebrewOld }) { finished.append(CachesPage.homebrewOld) }
            }
        }
        progress(ActionProgress(fraction: span.upperBound, message: working, finished: finished))
        let freed = measuredFreed(before, DataVolume.settledFreeBytes())
        guard !finished.isEmpty else { return ActionResult(outcome: .failed, message: loc("Couldn't free it"), details: details, refresh: true) }
        return .succeeded(freedMessage(freed), details: details, freedBytes: freed)
    }

    /// Frees one cache of the caches page its own way: an app cache read again first (`cleanAppCaches`), a web or system cache through
    /// the cleaner, a developer cache through `DeveloperCaches.free`, Homebrew's through its own cleanup.
    static func freeOne(_ entry: CacheEntry, in snapshot: SystemDataSnapshot) -> (done: Bool, details: [String]) {
        func deleted(_ details: [String]) -> Bool { details.contains { $0.hasPrefix("Deleted") } }
        switch entry.source {
        case .app:
            let details = cleanAppCaches([entry.id], in: snapshot).details
            return (deleted(details), details)
        case .web, .system, .appCopy:
            let items = snapshot.report.items.filter { $0.id == entry.id }
            guard !items.isEmpty else { return (false, ["Skipped: \(entry.id). Already gone."]) }
            let details = clean(items).details
            return (deleted(details), details)
        case .developer:
            let details = DeveloperCaches.free(snapshot.developerCaches.filter { $0.id == entry.id })
            return (deleted(details), details)
        case .homebrew:
            guard let plan = snapshot.homebrew else { return (false, ["Skipped: \(entry.id). Homebrew is gone."]) }
            let result = cleanHomebrew(plan.brew, allDownloads: entry.id == CachesPage.homebrewDownloads)
            return (result.outcome == .succeeded, result.details)
        }
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
    /// it, renamed then deleted. A container's caches folder stays, emptied of all but macOS's own (`AppCaches.containerContents`):
    /// the cleaner may delete only inside the chosen containers' caches folders, and checks their apps by bundle identifier alone.
    static func cleanAppCaches(_ ids: [String], in snapshot: SystemDataSnapshot, now: Date = Date(),
                               home: String = FileManager.default.homeDirectoryForCurrentUser.path, cleaner: SystemDataCleaner = SystemDataCleaner()) -> ActionResult {
        let chosen = snapshot.report.appCaches.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return .failed(loc("Already gone")) }
        var details: [String] = []
        var items: [SystemDataItem] = []
        var containerItems: [SystemDataItem] = []
        var containerFolders: [String] = []
        let cleanup = SystemDataCleanup(kind: .deleteWhenNotRunning, description: "", command: nil)
        for var cache in chosen {
            if let dates = AppCaches.measure(cache.path, now: now, skippingApple: cache.container != nil) {
                cache.lastChange = dates.lastChange
                cache.recentBytes = dates.recentBytes
                cache.dataLikeBytes = dates.dataLikeBytes
            }
            // Read again: one that now looks like data stays. One in use may go: the user chose it, and the page said it comes back.
            guard AppCaches.outcome(cache, now: now) != .heldBack else {
                details.append("Skipped: \(cache.id). It now holds media or documents.")
                continue
            }
            if let container = cache.container {
                // Only the caches folder of a third-party app's container, found again from its bundle identifier.
                guard let folder = AppCaches.containerCachesFolder(home: home, container: container), folder == cache.path else {
                    details.append("Skipped: \(cache.id). Not a third-party app's caches folder.")
                    continue
                }
                let contents = AppCaches.containerContents(folder)
                guard !contents.isEmpty else {
                    details.append("Skipped: \(cache.id). Nothing in it.")
                    continue
                }
                containerFolders.append(URL(fileURLWithPath: folder).standardizedFileURL.path)
                containerItems.append(SystemDataItem(id: cache.id, title: cache.title, kind: .appCache, paths: contents, bytes: cache.bytes, readable: true,
                                                     owners: cache.bundleIdentifiers.isEmpty ? [container] : cache.bundleIdentifiers, inUse: false,
                                                     cleanup: cleanup, notes: []))
                continue
            }
            // Its owner by folder name (a tool, a bundle identifier) and by the app's own name, so the running check finds either.
            var owners = [cache.name.hasSuffix(".ShipIt") ? String(cache.name.dropLast(".ShipIt".count)) : cache.name]
            if cache.title != owners[0] { owners.append(cache.title) }
            items.append(SystemDataItem(id: cache.id, title: cache.title, kind: .appCache, paths: [cache.path], bytes: cache.bytes, readable: true,
                                        owners: owners, inUse: false, cleanup: cleanup, notes: []))
        }
        guard !items.isEmpty || !containerItems.isEmpty else {
            return ActionResult(outcome: .failed, message: loc("Couldn't free it"), details: details, refresh: true)
        }
        var reports: [SystemDataCleanupReport] = []
        if !items.isEmpty {
            reports.append(cleaner.clean(items, allowedRoots: [URL(fileURLWithPath: home).appendingPathComponent("Library/Caches").standardizedFileURL.path]))
        }
        if !containerItems.isEmpty {
            reports.append(cleaner.clean(containerItems, allowedRoots: containerFolders, ownersAreBundleIdentifiers: true))
        }
        let results = reports.flatMap(\.results)
        details += results.map { "\($0.deleted ? "Deleted" : "Skipped"): \($0.itemID). \($0.detail)" }
        let freed = measuredFreed(reports.first?.freeBytesBefore, reports.last?.freeBytesAfter)
        if !results.contains(where: \.deleted) {
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

    /// Erases the unified log through the helper, with Apple's own `log erase` (`UnifiedLogCleaner`). Never part of Clean or automatic
    /// cleaning: the history macOS keeps for troubleshooting goes for good.
    static func eraseUnifiedLog(_ channel: (any PrivilegedChannel)?) async -> ActionResult {
        guard let channel else { return .failed(loc("Install the helper in Settings")) }
        let before = DataVolume.freeBytes()
        let result: UnifiedLogResult
        do { result = try await channel.perform(UnifiedLogResult.self, operation: SystemDataPrivilegedOperations.eraseUnifiedLog) }
        catch { return .failed(loc("Couldn't free it"), details: [error.localizedDescription]) }
        guard result.executed else { return .failed(loc("Couldn't free it"), details: result.error.map { [$0] } ?? []) }
        let measured = measuredFreed(before, DataVolume.settledFreeBytes())
        let stored = (result.bytesBefore ?? 0) > (result.bytesAfter ?? 0) ? (result.bytesBefore ?? 0) - (result.bytesAfter ?? 0) : 0
        if let after = result.bytesAfter { SystemLogFloor.save(after) }
        var details = ["log erase --all\(result.prunedFormatStrings ? " and --uuidtext" : ""): the log went from \(ByteFormat.string(result.bytesBefore ?? 0)) to \(ByteFormat.string(result.bytesAfter ?? 0))."]
        if let error = result.error { details.append(error) }
        return ActionResult(outcome: result.error == nil ? .succeeded : .needsAttention, message: freedMessage(measured ?? stored), details: details,
                            freedBytes: measured)
    }

    /// Empties the symbols cache coresymbolicationd keeps, through the helper (`SymbolicationCacheCleaner`), which stops the daemon
    /// so its mapped archive is let go; macOS rebuilds the cache. Never part of Clean or automatic cleaning: only the helper can do it.
    static func deleteSymbolicationCache(_ channel: (any PrivilegedChannel)?) async -> ActionResult {
        guard let channel else { return .failed(loc("Install the helper in Settings")) }
        let before = DataVolume.freeBytes()
        let result: SymbolicationCacheResult
        do { result = try await channel.perform(SymbolicationCacheResult.self, operation: SystemDataPrivilegedOperations.deleteSymbolicationCache) }
        catch { return .failed(loc("Couldn't free it"), details: [error.localizedDescription]) }
        guard result.executed else { return .failed(loc("Couldn't free it"), details: result.error.map { [$0] } ?? []) }
        let measured = measuredFreed(before, DataVolume.settledFreeBytes())
        let stored = (result.bytesBefore ?? 0) > (result.bytesAfter ?? 0) ? (result.bytesBefore ?? 0) - (result.bytesAfter ?? 0) : 0
        var details = ["Removed \(result.removedEntries) item(s); the cache went from \(ByteFormat.string(result.bytesBefore ?? 0)) to \(ByteFormat.string(result.bytesAfter ?? 0))."]
        if result.daemonStopped { details.append("coresymbolicationd was stopped; macOS starts it again when it is needed.") }
        if let error = result.error { details.append(error) }
        return ActionResult(outcome: result.error == nil ? .succeeded : .needsAttention, message: freedMessage(measured ?? stored), details: details,
                            freedBytes: measured)
    }

    /// Empties the Trash of the home folder, as the Finder's Empty Trash does: every item in it is deleted for good. Reading the Trash
    /// needs Full Disk Access, without which the page shows no Trash row. An item the Finder locked, or one another account owns,
    /// stays, and the result says how many.
    static func emptyTrash(trash: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"),
                           fileManager: FileManager = .default) -> ActionResult {
        guard let names = try? fileManager.contentsOfDirectory(atPath: trash.path) else {
            return .failed(loc("Couldn't free it"), details: ["The Trash could not be read."])
        }
        guard !names.isEmpty else { return .failed(loc("Already gone")) }
        let before = DataVolume.freeBytes()
        var removed = 0
        var kept: [String] = []
        for name in names {
            do { try fileManager.removeItem(at: trash.appendingPathComponent(name)); removed += 1 }
            catch { kept.append("\(name): \((error as NSError).localizedDescription)") }
        }
        let freed = measuredFreed(before, removed > 0 ? DataVolume.settledFreeBytes() : DataVolume.freeBytes())
        var details = ["Deleted \(removed) item(s) from the Trash."]
        if !kept.isEmpty { details.append("Kept \(kept.count) item(s) that could not be deleted (locked, or another account's): " + kept.joined(separator: "; ")) }
        guard removed > 0 else { return ActionResult(outcome: .failed, message: loc("Couldn't free it"), details: details, refresh: true) }
        return ActionResult(outcome: kept.isEmpty ? .succeeded : .needsAttention, message: freedMessage(freed), details: details, freedBytes: freed)
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
