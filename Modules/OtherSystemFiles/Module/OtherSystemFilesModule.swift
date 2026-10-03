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
            progress(ActionProgress(message: "Asking macOS to remove the files apps marked purgeable…"))
            let estimate = await store.snapshot().estimatedBytes
            let purge = Self.purgeFiles()
            if purge.removedNothing { await store.noteDeclined(estimate: estimate) }
            return purge.result
        default:
            return .failed("Unknown action \(request.actionID).")
        }
    }

    /// Apple's own purge of one service, run in the CLI child process. The freed space is measured on the volume.
    static func purgeFiles() -> (result: ActionResult, removedNothing: Bool) {
        let service = CacheDeleteService.fsPurgeableData, urgency = CacheDeleteService.fsPurgeableDataUrgency
        let result: CacheDeletePurgeResult
        if let cli = ToolLocator.cli() {
            result = CacheDeleteClient.purgeInSubprocess(executable: cli, service: service, urgency: urgency)
        } else {
            result = CacheDeleteClient().purge(services: [service], urgency: urgency)
        }
        if let error = result.error { return (.failed(error), false) }
        // CacheDelete can answer at once that it removed nothing (amount 0 within a millisecond, 2026-10-03), while its estimate still
        // counts the files. That is not a success: say so, rather than "freed Zero KB". Its whole answer is printed by the CLI.
        if (result.purgedBytes ?? 0) == 0 && (result.freedBytes ?? 0) < 1_000_000 {
            return (ActionResult(outcome: .needsAttention, message: "macOS removed nothing.",
                                 details: ["macOS answered in \(String(format: "%.3f", result.elapsedSeconds ?? 0)) s that none of these files can go now. It keeps them until it needs the space, and its estimate of them lags behind; MacSpace offers them again once that estimate grows."],
                                 refresh: true), true)
        }
        return (.succeeded("Freed \(ByteFormat.string(result.freedBytes ?? 0)) of purgeable app files, measured on the volume.",
                           details: ["macOS reported \(ByteFormat.string(result.purgedBytes ?? 0)) removed in \(String(format: "%.1f", result.elapsedSeconds ?? 0)) s."]),
                false)
    }
}
