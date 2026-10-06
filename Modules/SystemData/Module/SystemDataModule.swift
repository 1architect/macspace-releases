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
        SystemDataScreenBuilder.tile(await store.snapshot(privileged: context.privileged))
    }

    public func screen(context: ModuleContext) async -> Screen {
        SystemDataScreenBuilder.screen(await store.snapshot(privileged: context.privileged))
    }

    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        let result = await handle(request, context: context, progress: progress)
        // Forgotten before the result goes back, not after: the app reads the tile and the page again as soon as it has the result,
        // and a cache dropped later (in a task of its own) gave it the figures from before the action.
        await store.invalidate()
        return result
    }

    private func handle(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        let snapshot = await store.snapshot(maxAge: 600, privileged: context.privileged)
        switch request.actionID {
        case "clean":
            guard let id = request.parameters["id"], let item = snapshot.report.items.first(where: { $0.id == id }) else {
                return .failed("Already gone")
            }
            progress(ActionProgress(message: "Freeing space…"))
            return Self.clean([item])
        case "cleanReports":
            progress(ActionProgress(message: "Freeing space…"))
            return Self.cleanReports(snapshot.reports)
        case "openFullDiskAccess":
            NSWorkspace.shared.open(LivePermissionChecker.fullDiskAccessSettingsURL)
            return ActionResult(outcome: .succeeded, message: "", refresh: false)
        case "openSoftwareUpdate":
            if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") { NSWorkspace.shared.open(url) }
            return ActionResult(outcome: .succeeded, message: "", refresh: false)
        case "deleteStagedUpdate":
            progress(ActionProgress(message: "Freeing space…"))
            return await Self.deleteStagedUpdate(context.privileged)
        case "deleteVersions":
            progress(ActionProgress(message: "Freeing space…"))
            return await Self.deleteVersions(context.privileged)
        case "purgeAssets":
            progress(ActionProgress(message: "Freeing space…"))
            return Self.purgeAssets(store: store)
        case "cleanAll":
            let cleaned = Self.cleanSafe(snapshot, store: store, progress: progress)
            return .succeeded(Self.freedMessage(cleaned.freed), details: cleaned.details, freedBytes: cleaned.freed)
        default:
            return .failed("Unknown action \(request.actionID).")
        }
    }

    /// Automatic cleanup: what Clean frees (caches of apps that are not open, old reports, unused system assets). Never the version
    /// history or anything else that cannot be undone.
    public func autoClean(context: ModuleContext) async -> CleanupReport? {
        let snapshot = await store.snapshot(maxAge: 0, privileged: context.privileged)
        guard SystemDataScreenBuilder.cleanBytes(snapshot) >= SystemDataScreenBuilder.worthARow else { return nil }
        let cleaned = Self.cleanSafe(snapshot, store: store, progress: { _ in })
        await store.invalidate()
        return CleanupReport(freedBytes: cleaned.freed, summary: "Caches, old reports and unused system assets", details: cleaned.details)
    }

    /// Everything Clean frees, measured on the volume over the whole run.
    static func cleanSafe(_ snapshot: SystemDataSnapshot, store: SystemDataStore, progress: ProgressSink) -> (freed: UInt64, details: [String]) {
        var details: [String] = []
        let before = DataVolume.freeBytes()
        let cleanable = snapshot.report.items.filter { $0.cleanup.kind == .deleteWhenNotRunning && !$0.inUse && ($0.expectedReclaimBytes ?? 0) > 0 }
        progress(ActionProgress(fraction: 0.1, message: "Freeing space…"))
        if !cleanable.isEmpty { details += clean(cleanable).details }
        progress(ActionProgress(fraction: 0.5, message: "Freeing space…"))
        if snapshot.reports.totalBytes > 0 { details += cleanReports(snapshot.reports).details }
        progress(ActionProgress(fraction: 0.7, message: "Freeing space…"))
        if (snapshot.purgeableAssetsBytes ?? 0) > 0, !snapshot.assetsRetrying { details += purgeAssets(store: store).details }
        var freed: UInt64 = 0
        if let before, let after = DataVolume.settledFreeBytes(), after > before { freed = after - before }
        return (freed, details)
    }

    // MARK: Actions

    static func clean(_ items: [SystemDataItem]) -> ActionResult {
        let inspector = SystemDataInspector()
        let report = SystemDataCleaner().clean(items, allowedRoots: SystemDataCleaner.allowedRoots(inspector.locations))
        let failed = report.results.filter { !$0.deleted }
        let freed = measuredFreed(report.freeBytesBefore, report.freeBytesAfter)
        let details = report.results.map { "\($0.deleted ? "Deleted" : "Skipped"): \($0.itemID). \($0.detail)" }
        if !failed.isEmpty && failed.count == report.results.count {
            return ActionResult(outcome: .failed, message: "Couldn't free it", details: details, refresh: true)
        }
        return .succeeded(freedMessage(freed), details: details, freedBytes: freed)
    }

    static func cleanReports(_ plan: CleanupPlan) -> ActionResult {
        let result = DiagnosticReportCleaner(directories: []).execute(plan)
        let details = result.failed.map { "Could not delete \($0.key): \($0.value)" }
        return .succeeded(freedMessage(result.freedBytes), details: details, freedBytes: result.freedBytes)
    }

    /// Deletes the Versions store through the helper. The freed space is measured on the volume, as for every other cleanup.
    static func deleteVersions(_ channel: (any PrivilegedChannel)?) async -> ActionResult {
        guard let channel else { return .failed("Install the helper in Settings") }
        let before = DataVolume.freeBytes()
        let result: VersionStoreResult
        do { result = try await channel.perform(VersionStoreResult.self, operation: SystemDataPrivilegedOperations.deleteVersions) }
        catch { return .failed("Couldn't free it", details: [error.localizedDescription]) }
        guard result.executed else { return .failed("Couldn't free it", details: result.error.map { [$0] } ?? []) }
        let measured = measuredFreed(before, DataVolume.freeBytes())
        let stored = (result.bytesBefore ?? 0) > (result.bytesAfter ?? 0) ? (result.bytesBefore ?? 0) - (result.bytesAfter ?? 0) : 0
        var details = ["Removed \(result.removedEntries) item(s) from the store; it went from \(ByteFormat.string(result.bytesBefore ?? 0)) to \(ByteFormat.string(result.bytesAfter ?? 0))."]
        if let error = result.error { details.append(error) }
        let message = freedMessage(measured ?? stored)
        return ActionResult(outcome: result.error == nil ? .succeeded : .needsAttention, message: message, details: details, freedBytes: measured)
    }

    /// Deletes the files of an update that is already installed, through the helper (which checks they are really a leftover).
    static func deleteStagedUpdate(_ channel: (any PrivilegedChannel)?) async -> ActionResult {
        guard let channel else { return .failed("Install the helper in Settings") }
        let before = DataVolume.freeBytes()
        let result: StagedUpdateResult
        do { result = try await channel.perform(StagedUpdateResult.self, operation: SystemDataPrivilegedOperations.deleteStagedUpdate) }
        catch { return .failed("Couldn't free it", details: [error.localizedDescription]) }
        guard result.executed else { return .failed("Couldn't free it", details: result.error.map { [$0] } ?? []) }
        let stored = (result.bytesBefore ?? 0) > (result.bytesAfter ?? 0) ? (result.bytesBefore ?? 0) - (result.bytesAfter ?? 0) : 0
        let message = freedMessage(measuredFreed(before, DataVolume.freeBytes()) ?? stored)
        return ActionResult(outcome: result.error == nil ? .succeeded : .needsAttention, message: message, details: result.error.map { [$0] } ?? [],
                            freedBytes: measuredFreed(before, DataVolume.freeBytes()))
    }

    /// macOS is asked again right before; if it keeps them, again in the background, and the page reads the Mac again once it lets
    /// them go (`PurgeRun`).
    static func purgeAssets(store: SystemDataStore) -> ActionResult {
        let outcome = PurgeRun(service: CacheDeleteService.mobileAsset).run { freed in
            // macOS let them go later, when asked again in the background.
            CleanupHistory.shared.record(moduleID: Self.moduleID, moduleName: "System Data", freedBytes: freed, trigger: .background,
                                         summary: "Unused system assets")
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
