import AppKit
import Foundation
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceSystemDataPrivileged

@objc(MacSpaceSystemDataEntry)
public final class SystemDataEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { SystemDataModule() }
}

/// System Data: what fills it, what is safe to free, and guided manual cleanup for what only another app can remove.
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
        let snapshot = await store.snapshot(maxAge: 600, privileged: context.privileged)
        defer { Task { await store.invalidate() } }
        switch request.actionID {
        case "clean":
            guard let id = request.parameters["id"], let item = snapshot.report.items.first(where: { $0.id == id }) else {
                return .failed("That item is no longer listed. Refresh and try again.")
            }
            progress(ActionProgress(message: "Cleaning \(item.title)…"))
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
            return Self.purgeAssets()
        case "purgeFiles":
            progress(ActionProgress(message: "Asking macOS to remove the files apps marked purgeable…"))
            return Self.purgeFiles()
        case "cleanAll":
            var details: [String] = []
            var freed: UInt64 = 0
            let before = DataVolume.freeBytes()
            let cleanable = snapshot.report.items.filter { $0.cleanup.kind == .deleteWhenNotRunning && !$0.inUse && ($0.expectedReclaimBytes ?? 0) > 0 }
            progress(ActionProgress(fraction: 0.1, message: "Cleaning system caches…"))
            let caches = Self.clean(cleanable)
            details += caches.details
            progress(ActionProgress(fraction: 0.5, message: "Deleting old reports…"))
            if snapshot.reports.totalBytes > 0 { details += Self.cleanReports(snapshot.reports).details }
            progress(ActionProgress(fraction: 0.7, message: "Removing unused system assets…"))
            if (snapshot.purgeableAssetsBytes ?? 0) > 0 { details += Self.purgeAssets().details }
            progress(ActionProgress(fraction: 0.85, message: "Removing files apps marked purgeable…"))
            if (snapshot.purgeableFilesBytes ?? 0) > 0 { details += Self.purgeFiles().details }
            if let before, let after = DataVolume.freeBytes(), after > before { freed = after - before }
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
            return ActionResult(outcome: .failed, message: "Nothing was cleaned.", details: details, refresh: true)
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

    static func purgeAssets() -> ActionResult {
        let result: CacheDeletePurgeResult
        if let cli = ToolLocator.cli() {
            result = CacheDeleteClient.purgeInSubprocess(executable: cli)
        } else {
            result = CacheDeleteClient().purge(services: [CacheDeleteService.mobileAsset])
        }
        if let error = result.error { return .failed(error) }
        return .succeeded("Freed \(ByteFormat.string(result.freedBytes ?? 0)) of unused system assets, measured on the volume.",
                          details: ["macOS reported \(ByteFormat.string(result.purgedBytes ?? 0)) removed in \(String(format: "%.1f", result.elapsedSeconds ?? 0)) s."])
    }

    /// Apple's own purge of the files apps marked purgeable, run now instead of when the disk is nearly full.
    static func purgeFiles() -> ActionResult {
        let service = CacheDeleteService.fsPurgeableData, urgency = CacheDeleteService.fsPurgeableDataUrgency
        let result: CacheDeletePurgeResult
        if let cli = ToolLocator.cli() {
            result = CacheDeleteClient.purgeInSubprocess(executable: cli, service: service, urgency: urgency)
        } else {
            result = CacheDeleteClient().purge(services: [service], urgency: urgency)
        }
        if let error = result.error { return .failed(error) }
        return .succeeded("Freed \(ByteFormat.string(result.freedBytes ?? 0)) of purgeable app files, measured on the volume.",
                          details: ["macOS reported \(ByteFormat.string(result.purgedBytes ?? 0)) of purgeable files removed in \(String(format: "%.1f", result.elapsedSeconds ?? 0)) s."])
    }

    static func measuredFreed(_ before: UInt64?, _ after: UInt64?) -> UInt64? {
        guard let before, let after else { return nil }
        return after > before ? after - before : 0
    }

    static func freedMessage(_ freed: UInt64?, cleaned: Int) -> String {
        guard let freed else { return "Cleaned \(cleaned) item(s)." }
        return freed > 0 ? "Freed \(ByteFormat.string(freed)), measured on the volume." : "Cleaned \(cleaned) item(s); macOS has not reported the space as free yet."
    }
}
