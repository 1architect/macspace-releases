import Foundation
import MacSpacePlatform
import MacSpaceSdk

@objc(MacSpaceSystemDataEntry)
public final class SystemDataEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { SystemDataModule() }
}

/// System Data: what fills it, what is safe to free, and guided manual cleanup for what only another app can remove.
public struct SystemDataModule: MacSpaceModule {
    private let store = SystemDataStore()

    public init() {}

    public func invalidate() async { await store.invalidate() }

    public func summary(context: ModuleContext) async -> ScreenWidget {
        SystemDataScreenBuilder.summary(await store.snapshot(privileged: context.privileged))
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
        case "purgeAssets":
            progress(ActionProgress(message: "Asking macOS to remove unused system assets…"))
            return Self.purgeAssets()
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

    static func measuredFreed(_ before: UInt64?, _ after: UInt64?) -> UInt64? {
        guard let before, let after else { return nil }
        return after > before ? after - before : 0
    }

    static func freedMessage(_ freed: UInt64?, cleaned: Int) -> String {
        guard let freed else { return "Cleaned \(cleaned) item(s)." }
        return freed > 0 ? "Freed \(ByteFormat.string(freed)), measured on the volume." : "Cleaned \(cleaned) item(s); macOS has not reported the space as free yet."
    }
}
