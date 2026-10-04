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
                return .failed("That item is no longer listed. Refresh and try again.")
            }
            progress(ActionProgress(message: "Freeing \(item.title)…"))
            return Self.clean([item])
        case "cleanReports":
            progress(ActionProgress(message: "Deleting old reports…"))
            return Self.cleanReports(snapshot.reports)
        case "openFullDiskAccess":
            NSWorkspace.shared.open(LivePermissionChecker.fullDiskAccessSettingsURL)
            return ActionResult(outcome: .succeeded, message: "Opened System Settings. Allow MacSpace, then press Refresh.", refresh: false)
        case "deleteStagedUpdate":
            progress(ActionProgress(message: "Deleting the leftover update files…"))
            return await Self.deleteStagedUpdate(context.privileged)
        case "deleteVersions":
            progress(ActionProgress(message: "Stopping revisiond and deleting the version history…"))
            return await Self.deleteVersions(context.privileged)
        case "purgeAssets":
            progress(ActionProgress(message: "Asking macOS to remove unused system assets…"))
            return Self.purgeAssets(store: store)
        case "cleanAll":
            var details: [String] = []
            var freed: UInt64 = 0
            let before = DataVolume.freeBytes()
            let cleanable = snapshot.report.items.filter { $0.cleanup.kind == .deleteWhenNotRunning && !$0.inUse && ($0.expectedReclaimBytes ?? 0) > 0 }
            progress(ActionProgress(fraction: 0.1, message: "Freeing system caches…"))
            let caches = Self.clean(cleanable)
            details += caches.details
            progress(ActionProgress(fraction: 0.5, message: "Deleting old reports…"))
            if snapshot.reports.totalBytes > 0 { details += Self.cleanReports(snapshot.reports).details }
            progress(ActionProgress(fraction: 0.7, message: "Removing unused system assets…"))
            if (snapshot.purgeableAssetsBytes ?? 0) > 0, !snapshot.assetsRetrying { details += Self.purgeAssets(store: store).details }
            if let before, let after = DataVolume.settledFreeBytes(), after > before { freed = after - before }
            return .succeeded("Freed \(ByteFormat.string(freed)), measured on the volume.", details: details)
        default:
            return .failed("Unknown action \(request.actionID).")
        }
    }

    // MARK: Actions

    static func clean(_ items: [SystemDataItem]) -> ActionResult {
        let inspector = SystemDataInspector()
        let report = SystemDataCleaner().clean(items, allowedRoots: SystemDataCleaner.allowedRoots(inspector.locations))
        let failed = report.results.filter { !$0.deleted }
        let freed = measuredFreed(report.freeBytesBefore, report.freeBytesAfter)
        let details = report.results.map { "\($0.deleted ? "Deleted" : "Skipped"): \($0.itemID). \($0.detail)" }
        if !failed.isEmpty && failed.count == report.results.count {
            return ActionResult(outcome: .failed, message: "Nothing was freed.", details: details, refresh: true)
        }
        return .succeeded(freedMessage(freed, cleaned: report.results.count - failed.count), details: details)
    }

    static func cleanReports(_ plan: CleanupPlan) -> ActionResult {
        let result = DiagnosticReportCleaner(directories: []).execute(plan)
        let details = result.failed.map { "Could not delete \($0.key): \($0.value)" }
        return .succeeded("Deleted \(result.deleted.count) report(s), \(ByteFormat.string(result.freedBytes)).", details: details)
    }

    /// Deletes the Versions store through the helper. The freed space is measured on the volume, as for every other cleanup.
    static func deleteVersions(_ channel: (any PrivilegedChannel)?) async -> ActionResult {
        guard let channel else { return .failed("The helper is not installed. Install it in Settings, then try again.") }
        let before = DataVolume.freeBytes()
        let result: VersionStoreResult
        do { result = try await channel.perform(VersionStoreResult.self, operation: SystemDataPrivilegedOperations.deleteVersions) }
        catch { return .failed("The helper could not delete the version history: \(error.localizedDescription)") }
        guard result.executed else { return .failed(result.error ?? "Nothing was deleted.") }
        let measured = measuredFreed(before, DataVolume.freeBytes())
        let stored = (result.bytesBefore ?? 0) > (result.bytesAfter ?? 0) ? (result.bytesBefore ?? 0) - (result.bytesAfter ?? 0) : 0
        var details = ["Removed \(result.removedEntries) item(s) from the store; it went from \(ByteFormat.string(result.bytesBefore ?? 0)) to \(ByteFormat.string(result.bytesAfter ?? 0))."]
        if let error = result.error { details.append(error) }
        let message = measured.map { "Deleted the version history. The volume gained \(ByteFormat.string($0)); the store shrank by \(ByteFormat.string(stored))." }
            ?? "Deleted the version history; the store shrank by \(ByteFormat.string(stored))."
        return ActionResult(outcome: result.error == nil ? .succeeded : .needsAttention, message: message, details: details)
    }

    /// Deletes the files of an update that is already installed, through the helper (which checks they are really a leftover).
    static func deleteStagedUpdate(_ channel: (any PrivilegedChannel)?) async -> ActionResult {
        guard let channel else { return .failed("The helper is not installed. Install it in Settings, then try again.") }
        let before = DataVolume.freeBytes()
        let result: StagedUpdateResult
        do { result = try await channel.perform(StagedUpdateResult.self, operation: SystemDataPrivilegedOperations.deleteStagedUpdate) }
        catch { return .failed("The helper could not delete the files: \(error.localizedDescription)") }
        guard result.executed else { return .failed(result.error ?? "Nothing was deleted.") }
        let stored = (result.bytesBefore ?? 0) > (result.bytesAfter ?? 0) ? (result.bytesBefore ?? 0) - (result.bytesAfter ?? 0) : 0
        let message = measuredFreed(before, DataVolume.freeBytes()).map { "Deleted the leftover update files. The volume gained \(ByteFormat.string($0)); the folder shrank by \(ByteFormat.string(stored))." }
            ?? "Deleted the leftover update files; the folder shrank by \(ByteFormat.string(stored))."
        return ActionResult(outcome: result.error == nil ? .succeeded : .needsAttention, message: message, details: result.error.map { [$0] } ?? [])
    }

    /// macOS is asked again right before; if it keeps them, again in the background, and the page reads the Mac again once it lets
    /// them go (`PurgeRun`).
    static func purgeAssets(store: SystemDataStore) -> ActionResult {
        let outcome = PurgeRun(service: CacheDeleteService.mobileAsset).run(threshold: PurgeRun.noise) { _ in await store.invalidate() }
        return PurgeRun.result(outcome, what: "unused system assets")
    }

    static func measuredFreed(_ before: UInt64?, _ after: UInt64?) -> UInt64? {
        guard let before, let after else { return nil }
        return after > before ? after - before : 0
    }

    static func freedMessage(_ freed: UInt64?, cleaned: Int) -> String {
        guard let freed else { return "Deleted \(cleaned) item(s)." }
        return freed > 0 ? "Freed \(ByteFormat.string(freed)), measured on the volume." : "Deleted \(cleaned) item(s); macOS has not reported the space as free yet."
    }
}
