import AppKit
import Foundation
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceSiriPrivileged

@objc(MacSpaceSiriEntry)
public final class SiriEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { SiriModule() }
}

/// Apple Intelligence: the off-switch, a watcher for when macOS turns it back on, and removal of the models it leaves behind.
public struct SiriModule: MacSpaceModule {
    private let store = SiriStore()

    public init() {}

    public func invalidate() async { await store.invalidate() }

    public func tile(context: ModuleContext) async -> Tile {
        SiriScreenBuilder.tile(await snapshot())
    }

    public func screen(context: ModuleContext) async -> Screen {
        SiriScreenBuilder.screen(await snapshot())
    }

    /// The state, after starting the release of leftover models if they are due one: MacSpace does it by itself. `waits` holds the
    /// caller until the release is over.
    private func snapshot(waits: Bool = false) async -> SiriSnapshot {
        var snapshot = await store.snapshot()
        let store = self.store
        let running = await ModelAutoReleaser.shared.check(snapshot, release: { _ = Self.release(progress: { _ in }) },
                                                           finished: { await store.invalidate() })
        if waits, let running { await running.value }
        snapshot.releasingAutomatically = await ModelAutoReleaser.shared.isRunning
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
        if Machine.isVirtualMachine { return .failed("Apple Intelligence does not exist in a virtual machine; nothing was changed.") }
        switch request.actionID {
        case "toggle":
            let available = request.parameters["value"] == "true"
            let result = Self.setAvailability(available: available)
            guard !available, result.outcome == .succeeded else { return result }
            // Switching off is the transition that unlocks the models; macOS then deletes them only under disk pressure. MacSpace
            // deletes them right away instead of offering a purge.
            progress(ActionProgress(message: "Removing the models macOS no longer needs…"))
            return await Task.detached(priority: .userInitiated) { Self.purgeAfterSwitchingOff(result) }.value
        case "purgeAssets":
            progress(ActionProgress(message: "Asking macOS to remove unused system assets…"))
            return Self.purge()
        case "openFullDiskAccess":
            NSWorkspace.shared.open(LivePermissionChecker.fullDiskAccessSettingsURL)
            return ActionResult(outcome: .succeeded, message: "Opened System Settings. Allow MacSpace, then come back.", refresh: false)
        case "releaseModels":
            return await Task.detached(priority: .userInitiated) { Self.release(progress: progress) }.value
        default:
            return .failed("Unknown action \(request.actionID).")
        }
    }

    public func runBackgroundTask(_ id: String, context: ModuleContext) async {
        guard id == "watch" else { return }
        // Waited for: the background run may end with this call, and the release must get to restore the Siri language.
        _ = await snapshot(waits: true)
        let store = AppleIntelligenceWatchStore()
        let status = AppleIntelligenceLanguageGuard().status()
        let outcome = AppleIntelligenceWatcher().transition(previous: store.load(), status: status)
        try? store.save(outcome.record)
        if outcome.transitioned || outcome.alert != nil { try? store.append(outcome, status: status) }
        if let alert = outcome.alert, context.options.bool("notify") { AppleIntelligenceWatchStore.notify(alert) }
    }

    // MARK: Actions

    static func setAvailability(available: Bool) -> ActionResult {
        let guardian = AppleIntelligenceLanguageGuard()
        let environment = LiveSiriLanguageEnvironment()
        do {
            let plan = try guardian.plan(available ? .enable : .disable, context: environment.context(), scope: .thisMacOnly, saved: environment.loadSavedSettings())
            let result = try guardian.apply(plan, environment: environment)
            if plan.noChangeNeeded { return .succeeded(available ? "Apple Intelligence was already on." : "Apple Intelligence was already off.") }
            let state = guardian.status().state
            if available { return .succeeded("Apple Intelligence is available again.", details: plan.warnings) }
            let tail = state == .releasing ? "macOS is removing its model; this usually takes a few minutes." : "Verified: eligibility reads unavailable."
            return .succeeded("Apple Intelligence is off.", details: [tail] + (result.executed ? [] : []))
        } catch {
            return .failed("\(error)")
        }
    }

    static func purge() -> ActionResult {
        let result: CacheDeletePurgeResult
        if let cli = ToolLocator.cli() { result = CacheDeleteClient.purgeInSubprocess(executable: cli) }
        else { result = CacheDeleteClient().purge(services: [CacheDeleteService.mobileAsset]) }
        if let error = result.error { return .failed(error) }
        return .succeeded("Freed \(ByteFormat.string(result.freedBytes ?? 0)), measured on the volume.",
                          details: ["macOS reported \(ByteFormat.string(result.purgedBytes ?? 0)) removed."])
    }

    /// The purge that follows switching off, after the few seconds mobileassetd takes to unlock the models (5 s observed).
    static func purgeAfterSwitchingOff(_ switched: ActionResult) -> ActionResult {
        Thread.sleep(forTimeInterval: ModelReleaseTiming().releaseWait)
        let purged = purge()
        guard purged.outcome == .succeeded else { return switched }
        return ActionResult(outcome: .succeeded, message: switched.message, details: switched.details + [purged.message], refresh: true)
    }

    static func release(progress: @escaping ProgressSink) -> ActionResult {
        var count = 0
        let result = AppleIntelligenceModelRelease(purge: {
            if let cli = ToolLocator.cli() { return CacheDeleteClient.purgeInSubprocess(executable: cli) }
            return CacheDeleteClient().purge(services: [CacheDeleteService.mobileAsset])
        }).run { step in
            count += 1
            progress(ActionProgress(fraction: min(0.9, Double(count) * 0.2), message: step.detail))
        }
        if !result.blockers.isEmpty { return ActionResult(outcome: .needsAttention, message: "The release cannot run yet.", details: result.blockers, refresh: true) }
        if let error = result.error { return .failed(error, details: result.steps.map(\.detail)) }
        return .succeeded("Freed \(ByteFormat.string(result.purge?.freedBytes ?? 0)), measured on the volume.",
                          details: result.steps.map { "\($0.name): \($0.detail)" } + ["Siri language is back to \(result.siriLanguageAfter ?? "?")."])
    }
}
