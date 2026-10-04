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
        // Apple Intelligence is off, the models are released, but still on disk: they are deleted without the user asking.
        if Self.releasedModelsOnDisk(snapshot) {
            await ModelPurger.shared.purge(after: 0, force: false) { await store.invalidate() }
        }
        snapshot.purgingModels = await ModelPurger.shared.isRunning
        return snapshot
    }

    /// Off and not being released by `ModelAutoReleaser` (which purges itself), with models still on disk.
    static func releasedModelsOnDisk(_ snapshot: SiriSnapshot) -> Bool {
        guard !snapshot.isVirtualMachine, !snapshot.releasingAutomatically, snapshot.status.state == .protected || snapshot.status.state == .releasing,
              snapshot.accounts?.enabledElsewhere.isEmpty ?? true else { return false }
        let installed = snapshot.installedModelBytes ?? 0
        let released = installed > snapshot.lockedModelBytes ? installed - snapshot.lockedModelBytes : 0
        return released >= SiriScreenBuilder.purgeThreshold
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
            // deletes them itself, in the background once mobileassetd has dropped its locks, so the switch answers at once.
            let store = self.store
            await ModelPurger.shared.purge(after: ModelReleaseTiming().releaseWait, force: true) { await store.invalidate() }
            return ActionResult(outcome: .succeeded, message: result.message,
                                details: result.details + ["MacSpace deletes the released models in the background."], refresh: true)
        case "openICloudSettings":
            NSWorkspace.shared.open(SiriCloudSync.settingsURL)
            return ActionResult(outcome: .succeeded, message: "Opened iCloud settings: Siri > Sync this Mac.", refresh: false)
        case "purgeAssets":
            progress(ActionProgress(message: "Asking macOS to remove unused system assets…"))
            let store = self.store
            return Self.purge { _ in await store.invalidate() }
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

    /// macOS is asked again right before; if it keeps them, again in the background (`PurgeRun`), and `freedLater` lets the page
    /// read the Mac again once it lets them go.
    static func purge(freedLater: @escaping @Sendable (UInt64) async -> Void = { _ in }) -> ActionResult {
        PurgeRun.result(PurgeRun(service: CacheDeleteService.mobileAsset).run(freedLater: freedLater),
                        what: "unused system assets")
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
