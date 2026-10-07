import AppKit
import Foundation
import MacSpacePlatform
import MacSpaceSdk

@objc(MacSpaceOtherSystemFilesEntry)
public final class OtherSystemFilesEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { OtherSystemFilesModule() }
}

/// Other System Files: what macOS counts as purgeable, and freeing the part that measurably frees space (the files apps marked
/// purgeable), now instead of when the disk is nearly full.
public struct OtherSystemFilesModule: MacSpaceModule {
    private let store = PurgeableStore()

    public init() {}

    public func invalidate() async { await store.invalidate() }

    public func tile(context: ModuleContext) async -> Tile {
        OtherSystemFilesScreenBuilder.tile(await snapshot())
    }

    public func screen(context: ModuleContext) async -> Screen {
        OtherSystemFilesScreenBuilder.screen(await snapshot())
    }

    /// The last reading, with how far the removals of cloud downloads running now are: read live, not cached with the figures.
    private func snapshot() async -> PurgeableSnapshot {
        var snapshot = await store.snapshot()
        snapshot.removing = CloudDownloadRemovals.shared.current()
        return snapshot
    }

    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        let result = await handle(request, context: context, progress: progress)
        // Forgotten before the result goes back, not after: the app reads the tile and the page again as soon as it has the result,
        // and a cache dropped later (in a task of its own) gave it the figures from before the action.
        await store.invalidate()
        return result
    }

    private func handle(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        switch request.actionID {
        case "purgeFiles":
            return await purgeAndKeepAsking(progress: progress).result
        case "openSoftwareUpdate":
            NSWorkspace.shared.open(PreparedUpdate.settingsURL)
            return ActionResult(outcome: .succeeded, message: "", refresh: false)
        case "removeDownloads":
            return Self.removeDownloads(request.parameters["path"] ?? "", store: store)
        default:
            return .failed("Unknown action \(request.actionID).")
        }
    }

    /// Automatic cleanup: the purgeable app files, unless MacSpace is already asking macOS for them again.
    public func autoClean(context: ModuleContext) async -> CleanupReport? {
        let snapshot = await store.snapshot(maxAge: 0)
        guard snapshot.freeableBytes >= OtherSystemFilesScreenBuilder.threshold, !snapshot.retrying else { return nil }
        let purge = await purgeAndKeepAsking(progress: { _ in })
        await store.invalidate()
        return CleanupReport(freedBytes: purge.freed, summary: "Purgeable app files", details: purge.result.details)
    }

    /// Purges, and when macOS keeps all or much of the files, asks it again in the background at the urgency of a critically full
    /// disk; the page reads the Mac again once it lets them go. The user never has to ask again.
    private func purgeAndKeepAsking(progress: ProgressSink) async -> (result: ActionResult, freed: UInt64) {
        let estimate = await store.currentRawEstimate()
        PurgeRetrier.shared.cancel(CacheDeleteService.fsPurgeableData)
        let purge = Self.purgeFiles(estimate: estimate, progress: progress)
        if purge.freed > 0 {
            await store.noteRemoved(purge.freed, estimate: estimate)
            PurgeHoldouts.shared.clear(CacheDeleteService.fsPurgeableData)
        }
        if purge.removedNothing || estimate > purge.freed + OtherSystemFilesScreenBuilder.threshold {
            let store = self.store
            PurgeRetrier.shared.schedule(service: CacheDeleteService.fsPurgeableData, urgency: CacheDeleteService.fsPurgeableDataForceUrgency) { freed in
                if freed == 0 {
                    // Every request freed nothing: what macOS still estimates is what it keeps, and is no longer offered.
                    await store.invalidate()
                    PurgeHoldouts.shared.hold(CacheDeleteService.fsPurgeableData, bytes: await store.currentRawEstimate())
                } else {
                    PurgeHoldouts.shared.clear(CacheDeleteService.fsPurgeableData)
                    await store.noteRemoved(freed, estimate: estimate)
                    CleanupHistory.shared.record(moduleID: "com.macspace.other-system-files", moduleName: "Other System Files", freedBytes: freed,
                                                 trigger: .background, summary: "Purgeable app files")
                }
                await store.invalidate()
            }
        }
        return (purge.result, purge.freed)
    }

    /// Starts removing the downloaded copies of one cloud service's files that are already in the cloud, in the background: with
    /// thousands of files it takes minutes, and the page stays usable while the row shows how far it is. Only a folder the last scan
    /// found (`PurgeableDocuments.isCloudFolder` checks it again). What it freed, measured on the volume, goes to the history.
    static func removeDownloads(_ path: String, store: PurgeableStore) -> ActionResult {
        guard PurgeableDocuments.isCloudFolder(path), let source = PurgeableDocuments.scan(maxAge: 600).first(where: { $0.path == path }) else {
            return .failed("That cloud folder is no longer on this Mac")
        }
        let name = source.name
        CloudDownloadRemovals.shared.start(URL(fileURLWithPath: path)) { removal, freed in
            var summary = "\(name) downloads: \(removal.files) file(s) now only in the cloud"
            if removal.kept > 0 { summary += ", \(removal.kept) kept (not uploaded yet, in conflict, or refused)" }
            CleanupHistory.shared.record(moduleID: "com.macspace.other-system-files", moduleName: "Other System Files", freedBytes: freed,
                                         trigger: .manual, summary: summary)
            Task { await store.invalidate() }
        }
        return ActionResult(outcome: .succeeded, message: "", refresh: true)
    }

    /// Apple's own purge of the files apps marked purgeable, run in the CLI child process: first at the urgency the disk's
    /// "purgeable" figure uses, then at the one macOS uses when the disk is critically full, for what the first left (it can
    /// remove part of them and then decline the rest). The space freed is measured on the volume, over both; what macOS keeps is
    /// asked for again in the background (`PurgeRetrier`).
    static func purgeFiles(estimate: UInt64, progress: ProgressSink) -> (result: ActionResult, removedNothing: Bool, freed: UInt64) {
        let service = CacheDeleteService.fsPurgeableData
        let before = DataVolume.freeBytes()
        var reported: UInt64 = 0
        var elapsed: Double = 0
        var lastError: String?
        let steps = [(CacheDeleteService.fsPurgeableDataUrgency, "Freeing space…"),
                     (CacheDeleteService.fsPurgeableDataForceUrgency, "Freeing space…")]
        for (index, step) in steps.enumerated() {
            progress(ActionProgress(fraction: Double(index) / Double(steps.count), message: step.1))
            let result: CacheDeletePurgeResult
            if let cli = ToolLocator.cli() {
                result = CacheDeleteClient.purgeInSubprocess(executable: cli, service: service, urgency: step.0)
            } else {
                result = CacheDeleteClient().purge(services: [service], urgency: step.0)
            }
            if let error = result.error { lastError = error; continue }
            reported += result.purgedBytes ?? 0
            elapsed += result.elapsedSeconds ?? 0
        }
        var freed: UInt64 = 0
        if let before, let after = DataVolume.settledFreeBytes(), after > before { freed = after - before }
        if reported == 0 && freed < 1_000_000 {
            if let lastError { return (.failed(PurgeRun.failedMessage, details: [lastError]), false, 0) }
            // CacheDelete can answer at once that it removed nothing while its estimate still counts the files.
            return (ActionResult(outcome: .succeeded, message: PurgeRun.laterMessage,
                                 details: ["MacSpace asks macOS again over the next hour; the figures update as soon as it lets them go."]),
                    true, 0)
        }
        let removed = max(freed, reported)
        var details = ["macOS reported \(ByteFormat.string(reported)) removed in \(String(format: "%.1f", elapsed)) s."]
        if estimate > removed + OtherSystemFilesScreenBuilder.threshold {
            details.append("macOS kept the other \(ByteFormat.string(estimate - removed)) for now.")
        }
        return (.succeeded(PurgeRun.freedMessage(freed), details: details, freedBytes: freed), false, removed)
    }
}
