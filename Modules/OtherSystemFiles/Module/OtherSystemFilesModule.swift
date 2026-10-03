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
        defer { Task { await store.invalidate() } }
        switch request.actionID {
        case "purgeFiles":
            progress(ActionProgress(message: "Asking macOS to remove the files apps marked purgeable…"))
            return Self.purgeFiles()
        default:
            return .failed("Unknown action \(request.actionID).")
        }
    }

    /// Apple's own purge of one service, run in the CLI child process. The freed space is measured on the volume.
    static func purgeFiles() -> ActionResult {
        let service = CacheDeleteService.fsPurgeableData, urgency = CacheDeleteService.fsPurgeableDataUrgency
        let result: CacheDeletePurgeResult
        if let cli = ToolLocator.cli() {
            result = CacheDeleteClient.purgeInSubprocess(executable: cli, service: service, urgency: urgency)
        } else {
            result = CacheDeleteClient().purge(services: [service], urgency: urgency)
        }
        if let error = result.error { return .failed(error) }
        // CacheDelete can answer at once without removing anything (no amount in its answer). That is not a success: say so, with
        // its answer, rather than "freed Zero KB".
        if (result.purgedBytes ?? 0) == 0 && (result.freedBytes ?? 0) < 1_000_000 {
            let answer = (result.answer ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
            return ActionResult(outcome: .needsAttention, message: "macOS removed nothing.",
                                details: ["macOS keeps these files until it needs the space, and declined to delete them now."]
                                    + (answer.isEmpty ? ["Its answer was empty."] : ["Its answer: " + answer.joined(separator: "; ")]),
                                refresh: true)
        }
        return .succeeded("Freed \(ByteFormat.string(result.freedBytes ?? 0)) of purgeable app files, measured on the volume.",
                          details: ["macOS reported \(ByteFormat.string(result.purgedBytes ?? 0)) removed in \(String(format: "%.1f", result.elapsedSeconds ?? 0)) s."])
    }
}
