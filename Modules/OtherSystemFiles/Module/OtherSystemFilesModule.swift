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
        OtherSystemFilesScreenBuilder.tile(await store.snapshot())
    }

    public func screen(context: ModuleContext) async -> Screen {
        OtherSystemFilesScreenBuilder.screen(await store.snapshot())
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
            let estimate = await store.snapshot().estimatedBytes
            let purge = Self.purgeFiles(progress: progress)
            if purge.removedNothing { await store.noteDeclined(estimate: estimate) }
            if purge.freed > 0 { await store.noteRemoved(purge.freed, estimate: estimate) }
            return purge.result
        default:
            return .failed("Unknown action \(request.actionID).")
        }
    }

    /// Apple's own purge of the files apps marked purgeable, run in the CLI child process: first at the urgency the disk's
    /// "purgeable" figure uses, then at the one macOS uses when the disk is critically full, for what the first left (it can
    /// remove part of them and then decline the rest). Only when neither removed anything are the files reported as declined. The
    /// space freed is measured on the volume, over both.
    static func purgeFiles(progress: ProgressSink) -> (result: ActionResult, removedNothing: Bool, freed: UInt64) {
        let service = CacheDeleteService.fsPurgeableData
        let before = DataVolume.freeBytes()
        var reported: UInt64 = 0
        var elapsed: Double = 0
        var lastError: String?
        let steps = [(CacheDeleteService.fsPurgeableDataUrgency, "Asking macOS to remove the files apps marked purgeable…"),
                     (CacheDeleteService.fsPurgeableDataForceUrgency, "Asking macOS again, as when the disk is critically full…")]
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
        if let before, let after = DataVolume.freeBytes(), after > before { freed = after - before }
        if reported == 0 && freed < 1_000_000 {
            if let lastError { return (.failed(lastError), false, 0) }
            // CacheDelete can answer at once that it removed nothing while its estimate still counts the files.
            return (ActionResult(outcome: .needsAttention, message: "macOS removed nothing.",
                                 details: ["Asked twice, the second time as when the disk is critically full, macOS declined to delete these files now. It keeps them until it needs the space, and its estimate of them lags behind; MacSpace offers them again once that estimate grows."],
                                 refresh: true), true, 0)
        }
        return (.succeeded("Freed \(ByteFormat.string(freed)) of purgeable app files, measured on the volume.",
                           details: ["macOS reported \(ByteFormat.string(reported)) removed in \(String(format: "%.1f", elapsed)) s."]),
                false, max(freed, reported))
    }
}
