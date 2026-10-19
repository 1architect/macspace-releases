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

    public func prepareForUninstall(context: ModuleContext) async -> ActionResult {
        guard await ManagedModelCleanup.shared.beginChange() else { return .failed(loc("A feature change is still running.")) }
        let result = await restoreForUninstall(context: context)
        await ManagedModelCleanup.shared.endChange()
        return result
    }

    private func restoreForUninstall(context: ModuleContext) async -> ActionResult {
        await ModelAutoReleaser.shared.waitForCurrentRelease()
        await ModelPurger.shared.stopAndWait()
        for scope in AssetModelCleanup.Scope.allCases where AssetModelCleanup.hasSavedOwners(scope) {
            let restored = await Task.detached(priority: .userInitiated) { AssetModelCleanup.restoreOwners(scope) }.value
            if let error = restored.error { return .failed(loc("Couldn't restore model requests."), details: [error]) }
        }
        let features = ModelFeatureSettings()
        for feature in ModelFeatureSettings.Feature.allCases where features.hasSavedSettings(feature) {
            do { try features.setOff(false, feature: feature) }
            catch { return .failed(loc("Couldn't restore feature settings."), details: [error.localizedDescription]) }
        }
        if PhoneFeatureFlags().hasSavedSettings {
            guard let channel = context.privileged else { return .failed(loc("MacSpace needs its helper to restore Call transcription.")) }
            do { _ = try await channel.perform(operation: SiriPrivilegedOperations.setPhoneFeatures, arguments: ["off": "false"]) }
            catch { return .failed(loc("Couldn't restore Call transcription."), details: [error.localizedDescription]) }
        }
        let environment = LiveSiriLanguageEnvironment()
        guard let saved = environment.loadSavedSettings() else { return .succeeded("") }
        do {
            try environment.write(siriLanguage: saved.siriLanguage, outputVoice: saved.outputVoice)
            guard environment.context().siriLanguage.map(AppleIntelligenceLanguageGuard.normalize)
                    == AppleIntelligenceLanguageGuard.normalize(saved.siriLanguage) else {
                return .failed(loc("Writing the Siri language preference failed."))
            }
            try environment.saveSettings(nil)
            return .succeeded("")
        } catch { return .failed(error.localizedDescription) }
    }

    public func invalidate() async { await store.invalidate() }

    public func tile(context: ModuleContext) async -> Tile {
        SiriScreenBuilder.tile(Self.presented(await snapshot(), context))
    }

    public func tile(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Tile {
        SiriScreenBuilder.tile(Self.presented(await snapshot(progress: progress), context))
    }

    public func screen(context: ModuleContext) async -> Screen {
        SiriScreenBuilder.screen(Self.presented(await snapshot(), context))
    }

    public func screen(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen {
        SiriScreenBuilder.screen(Self.presented(await snapshot(progress: progress), context))
    }

    /// The reading with the module's settings that change how it is shown.
    static func presented(_ snapshot: SiriSnapshot, _ context: ModuleContext) -> SiriSnapshot {
        var snapshot = snapshot
        snapshot.flagsModels = context.options.bool("flagModels")
        return snapshot
    }

    /// The state, after starting the release of leftover models if they are due one: MacSpace does it by itself. `waits` holds the
    /// caller until the release is over.
    private func snapshot(waits: Bool = false, progress: LoadProgressSink? = nil) async -> SiriSnapshot {
        var snapshot = await store.snapshot(progress: progress)
        let store = self.store
        let cleaningFeatures = await ManagedModelCleanup.shared.isRunning
        let running = cleaningFeatures ? nil : await ModelAutoReleaser.shared.check(snapshot, release: {
            Self.recordBackground(Self.release(progress: { _ in }).freedBytes ?? 0, summary: loc("Leftover Apple Intelligence models"))
        },
                                                           finished: { await store.invalidate() })
        if waits, let running { await running.value }
        snapshot.releasingAutomatically = await ModelAutoReleaser.shared.isRunning
        // Apple Intelligence is off, the models are released, but still on disk: they are deleted without the user asking.
        if !cleaningFeatures, Self.releasedModelsOnDisk(snapshot) {
            await ModelPurger.shared.purge(after: 0, force: false) { await store.invalidate() }
        }
        snapshot.purgingModels = await ModelPurger.shared.isRunning
        if !snapshot.releasingAutomatically, !snapshot.purgingModels { await checkFeatureModels() }
        snapshot.cleaningFeatures = await ManagedModelCleanup.shared.isFreeingVisibly
        snapshot.featureCleanupWaiting = await ManagedModelCleanup.shared.waiting
        return snapshot
    }

    private func checkFeatureModels(force: Bool = false) async {
        let store = self.store
        await ManagedModelCleanup.shared.check(force: force) { result in
            if result.freedBytes > 0 { Self.recordBackground(result.freedBytes, summary: loc("Unused system models")) }
            _ = await store.reconcileAssets()
            _ = await store.reconcilePhoneFeatures()
        }
    }

    static let moduleID = "com.macspace.siri"

    /// A cleanup MacSpace finished by itself, for the history in Settings.
    static func recordBackground(_ freed: UInt64, summary: String) {
        CleanupHistory.shared.record(moduleID: moduleID, moduleName: "Siri & Apple Intelligence", freedBytes: freed, trigger: .background, summary: summary)
    }

    /// Automatic cleanup: released Apple Intelligence models and other system assets macOS no longer needs.
    public func autoClean(context: ModuleContext) async -> CleanupReport? {
        let snapshot = await store.snapshot()
        let offerable = (snapshot.purgeableAssetsBytes ?? 0) >= SiriScreenBuilder.purgeThreshold && !snapshot.assetsRetrying
        guard !snapshot.isVirtualMachine, offerable || Self.releasedModelsOnDisk(snapshot), !(await ModelPurger.shared.isRunning) else { return nil }
        let store = self.store
        let outcome = PurgeRun(service: CacheDeleteService.mobileAsset).run { freed in
            Self.recordBackground(freed, summary: loc("Released Apple Intelligence models"))
            await store.invalidate()
        }
        await store.invalidate()
        guard outcome.error == nil else { return nil }
        return CleanupReport(freedBytes: outcome.freed, summary: loc("Released Apple Intelligence models and unused system assets"), details: PurgeRun.details(outcome))
    }

    /// Off and not being released by `ModelAutoReleaser` (which purges itself), with models still on disk.
    static func releasedModelsOnDisk(_ snapshot: SiriSnapshot) -> Bool {
        guard !snapshot.isVirtualMachine, !snapshot.releasingAutomatically, snapshot.status.state == .protected || snapshot.status.state == .releasing,
              snapshot.accounts?.enabledElsewhere.isEmpty ?? true else { return false }
        let recorded = snapshot.recordedModelBytes ?? 0
        let released = recorded > snapshot.lockedModelBytes ? recorded - snapshot.lockedModelBytes : 0
        return released >= SiriScreenBuilder.purgeThreshold
    }

    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        let changesFeature = ["toggle", "togglePhoneFeatures", "toggleModelFeature", "disableAll", "enableAll", "setAll"].contains(request.actionID)
        if changesFeature {
            guard await ManagedModelCleanup.shared.beginChange() else { return .failed(loc("A feature change is still running.")) }
            PurgeRetrier.shared.cancel(CacheDeleteService.mobileAsset)
            await ModelAutoReleaser.shared.waitForCurrentRelease()
            await ModelPurger.shared.stopAndWait()
        }
        if request.actionID == "purgeAssets" { _ = await store.snapshot(maxAge: .infinity) }
        var result = await handle(request, context: context, progress: progress)
        if result.refresh {
            // Feature actions reconcile only feature state and a purge only the assets, keeping the page's other measurements.
            var updated: SiriSnapshot?
            switch request.actionID {
            case "togglePhoneFeatures", "toggleModelFeature": updated = await store.reconcilePhoneFeatures()
            case "purgeAssets": updated = await store.reconcileAssets()
            default: break
            }
            if var updated {
                updated.releasingAutomatically = await ModelAutoReleaser.shared.isRunning
                updated.purgingModels = await ModelPurger.shared.isRunning
                updated = Self.presented(updated, context)
                result.presentation = ModulePresentation(tile: SiriScreenBuilder.tile(updated), screen: SiriScreenBuilder.screen(updated))
            } else { await store.invalidate() }
        }
        if changesFeature {
            await ManagedModelCleanup.shared.endChange()
            let off = request.parameters["value"] == "false" || request.actionID == "disableAll"
            if off, result.outcome == .succeeded { await checkFeatureModels(force: true) }
        }
        return result
    }

    private func handle(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        if Machine.isVirtualMachine { return .failed(loc("Not available in a virtual machine")) }
        switch request.actionID {
        case "disableAll", "enableAll", "setAll":
            // Each switch in turn, as if flipped on the page; the first that fails stops the rest and says why. The tile's switch
            // (`setAll`) switches off those on, or on those off, as its `value` says.
            let enabling = request.actionID == "setAll" ? request.parameters["value"] == "true" : request.actionID == "enableAll"
            let value = String(enabling)
            var details: [String] = []
            var restart = false
            let list = request.actionID == "setAll" ? request.parameters[enabling ? "off" : "on"] : request.parameters["ids"]
            let ids = (list ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
            for (index, id) in ids.enumerated() {
                progress(ActionProgress(fraction: Double(index) / Double(max(ids.count, 1)), message: loc("Changing settings")))
                let step: ActionRequest
                switch id {
                case "ai": step = ActionRequest(actionID: "toggle", parameters: ["id": "ai", "value": value])
                case "phone": step = ActionRequest(actionID: "togglePhoneFeatures", parameters: ["value": value])
                default: step = ActionRequest(actionID: "toggleModelFeature", parameters: ["feature": id, "value": value])
                }
                let result = await handle(step, context: context, progress: { _ in })
                details += result.details
                restart = restart || result.restartRequired
                guard result.outcome == .succeeded else { return ActionResult(outcome: result.outcome, message: result.message, details: details) }
            }
            if restart { return .succeeded(loc("Restart your Mac to apply this change."), details: details, restartRequired: true) }
            return .succeeded(loc("Feature settings updated."), details: details)
        case "toggleModelFeature":
            guard let name = request.parameters["feature"], let feature = ModelFeatureSettings.Feature(rawValue: name), feature != .phone,
                  let value = request.parameters["value"], ["true", "false"].contains(value) else { return .failed(loc("Unknown feature.")) }
            do {
                if value == "true", let scope = AssetModelCleanup.Scope(rawValue: feature.rawValue) {
                    let restored = await Task.detached(priority: .userInitiated) { AssetModelCleanup.restoreOwners(scope) }.value
                    if let error = restored.error { return .failed(loc("Couldn't restore model requests."), details: [error]) }
                }
                try ModelFeatureSettings().setOff(value == "false", feature: feature)
                return .succeeded(loc("Feature settings updated."))
            } catch {
                return ActionResult(outcome: .failed, message: loc("Couldn't change feature settings."), details: [error.localizedDescription])
            }
        case "togglePhoneFeatures":
            guard let value = request.parameters["value"], ["true", "false"].contains(value), let channel = context.privileged else {
                return .failed(loc("MacSpace needs its helper to change Call transcription."))
            }
            do {
                if value == "true" {
                    let restored = await Task.detached(priority: .userInitiated) { AssetModelCleanup.restoreOwners(.phone) }.value
                    if let error = restored.error { return .failed(loc("Couldn't restore model requests."), details: [error]) }
                }
                let data = try await channel.perform(operation: SiriPrivilegedOperations.setPhoneFeatures, arguments: ["off": String(value == "false")])
                let state = try JSONDecoder().decode(PhoneFeatureFlags.Status.self, from: data)
                try ModelFeatureSettings().setOff(value == "false", feature: .phone)
                if state.state == .restartRequired || value == "true" && state.state == .unsupported {
                    return .succeeded(loc("Restart your Mac to apply this change."), restartRequired: true)
                }
                guard state.state == .off || state.state == .on else {
                    return ActionResult(outcome: .needsAttention, message: loc("Couldn't verify the Call transcription change."),
                                        details: state.detail.map { [$0] } ?? [])
                }
                return .succeeded(loc("Feature settings updated."))
            } catch {
                // A durable intent may have been saved before a later write failed. Read its actual state back into the existing
                // page instead of leaving an optimistic switch showing the pre-action state.
                return ActionResult(outcome: .failed, message: loc("Couldn't change Call transcription."), details: [error.localizedDescription])
            }
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
        case "restartMac":
            // macOS's own dialog asks; the Mac restarts only if the user confirms there.
            guard SystemRestart.showDialog() else { return .failed(loc("Restart your Mac from the Apple menu.")) }
            return ActionResult(outcome: .succeeded, message: "", refresh: false)
        case "openICloudSettings":
            NSWorkspace.shared.open(SiriCloudSync.settingsURL)
            return ActionResult(outcome: .succeeded, message: "", refresh: false)
        case "purgeAssets":
            progress(ActionProgress(message: loc("Freeing space")))
            let store = self.store
            return Self.purge { freed in
                Self.recordBackground(freed, summary: loc("Unused system assets"))
                await store.invalidate()
            }
        case "openFullDiskAccess":
            NSWorkspace.shared.open(LivePermissionChecker.fullDiskAccessSettingsURL)
            return ActionResult(outcome: .succeeded, message: "", refresh: false)
        case "releaseModels":
            return await Task.detached(priority: .userInitiated) { Self.release(progress: progress) }.value
        default:
            return .failed(loc("Unknown action \(request.actionID)."))
        }
    }

    public func runBackgroundTask(_ id: String, context: ModuleContext) async {
        if id == "featureModels" {
            guard !(await ModelAutoReleaser.shared.isRunning), !(await ModelPurger.shared.isRunning) else { return }
            await checkFeatureModels(force: true)
            await ManagedModelCleanup.shared.waitForCurrent()
            return
        }
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
            _ = try guardian.apply(plan, environment: environment)
            if plan.noChangeNeeded { return .succeeded(available ? loc("Already on") : loc("Already off")) }
            let state = guardian.status().state
            if available { return .succeeded(loc("Apple Intelligence is on"), details: plan.warnings) }
            let tail = state == .releasing ? "macOS is removing its model; this usually takes a few minutes." : "Verified: eligibility reads unavailable."
            return .succeeded(loc("Apple Intelligence is off"), details: [tail])
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
        let result = AppleIntelligenceModelRelease().run { step in
            count += 1
            progress(ActionProgress(fraction: min(0.9, Double(count) * 0.2), message: step.detail))
        }
        if !result.blockers.isEmpty { return ActionResult(outcome: .needsAttention, message: loc("Can't free it yet"), details: result.blockers, refresh: true) }
        if let error = result.error { return .failed(PurgeRun.failedMessage, details: [error] + result.steps.map(\.detail)) }
        return .succeeded(PurgeRun.freedMessage(result.purge?.freedBytes ?? 0),
                          details: result.steps.map { "\($0.name): \($0.detail)" } + ["Siri language is back to \(result.siriLanguageAfter ?? "?")."],
                          freedBytes: result.purge?.freedBytes)
    }
}
