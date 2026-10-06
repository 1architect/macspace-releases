import AppKit
import Foundation
import MacSpaceDebloatPrivileged
import MacSpacePlatform
import MacSpaceSdk

@objc(MacSpaceDebloatEntry)
public final class DebloatEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { DebloatModule() }
}

/// Analytics, advertising and background-intelligence controls that macOS itself honours, each reversible.
public struct DebloatModule: MacSpaceModule {
    private let store = DebloatStore()

    public init() {}

    public func invalidate() async { await store.invalidate() }

    public func tile(context: ModuleContext) async -> Tile {
        DebloatScreenBuilder.tile(await snapshot(context))
    }

    public func screen(context: ModuleContext) async -> Screen {
        DebloatScreenBuilder.screen(await snapshot(context))
    }

    /// The snapshot, after the helper removed the profiles of earlier versions once the one profile holds everything they did: no
    /// approval, and nothing switched off comes back on. Tried once per set, so a failure does not repeat on every read.
    private func snapshot(_ context: ModuleContext) async -> DebloatSnapshot {
        let snapshot = await store.snapshot()
        guard case let .cleanUp(identifiers) = snapshot.profileWork, context.privileged != nil, await store.firstCleanUp(identifiers) else { return snapshot }
        _ = await Self.removeProfiles(identifiers, context: context)
        await store.invalidate()
        return await store.snapshot()
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
        case "toggle":
            guard let id = request.parameters["id"] else { return .failed("No control was named.") }
            let apply = Self.appliesProtection(switchValue: request.parameters["value"])
            return await Self.change(apply ? .apply : .revert, [id], context: context, progress: progress)
        case "applyRecommended", "reapply":
            let ids = (request.parameters["ids"] ?? "").split(separator: ",").map(String.init)
            return await Self.change(.apply, ids, context: context, progress: progress)
        case "restoreAll":
            let ids = (request.parameters["ids"] ?? "").split(separator: ",").map(String.init)
            return await Self.change(.revert, ids, context: context, progress: progress)
        case "removeOldProfiles", "removePending":
            // MacSpace profiles nothing needs any more (the last policy switched back on, or earlier versions' profiles once the one
            // profile holds everything), removed through the helper: nothing to approve.
            switch DebloatStore.liveEngine().profileWork() {
            case let .remove(identifiers), let .cleanUp(identifiers): return await Self.removeProfiles(identifiers, context: context)
            default: return .succeeded("Nothing to remove")
            }
        case "approvePending":
            // The one profile, with every policy switched off, staged again for approval; System Settings shows it under Device
            // Management.
            do {
                let ids = try DebloatStore.liveEngine().stagePendingProfiles()
                guard !ids.isEmpty else { return .succeeded("Nothing to approve") }
                Self.openDeviceManagement()
                return ActionResult(outcome: .succeeded, message: "", refresh: true)
            } catch {
                return .failed("Couldn't open the profile", details: [error.localizedDescription])
            }
        case "openProfiles":
            Self.openDeviceManagement()
            return ActionResult(outcome: .succeeded, message: "", refresh: false)
        default:
            return .failed("Unknown action \(request.actionID).")
        }
    }

    /// The watch: what macOS switched back on is switched off again, at once, and the user is told. Policies are left alone (a
    /// profile macOS dropped needs the user's approval again); so is what needs the helper while it is not installed. The page keeps
    /// showing those as undone.
    public func runBackgroundTask(_ id: String, context: ModuleContext) async {
        guard id == "watch" else { return }
        await store.invalidate()
        let undone = DebloatScreenBuilder.counts(await store.snapshot()).drifted
            .filter { !DebloatScreenBuilder.isPolicy($0) && (context.privileged != nil || !DebloatScreenBuilder.needsHelper($0)) }
        guard !undone.isEmpty else { return }
        _ = await Self.change(.apply, undone.map(\.id), context: context, progress: { _ in })
        await store.invalidate()
        let after = await store.snapshot()
        let fixed = undone.filter { after.status($0.id)?.state == .debloated }.map(\.title)
        guard !fixed.isEmpty else { return }
        let event = DebloatReapplied(at: Date(), titles: fixed)
        try? DebloatWatchStore().record(event)
        await store.invalidate()
        if context.options.bool("notify") { DebloatWatchStore.notify(event) }
    }

    /// The switch is "Disable <feature>": switching it on applies the protection, switching it off restores the original.
    static func appliesProtection(switchValue: String?) -> Bool { switchValue == "true" }

    static func change(_ action: ChangeAction, _ ids: [String], context: ModuleContext,
                       progress: @escaping ProgressSink) async -> ActionResult {
        guard !ids.isEmpty else { return .failed("No controls were selected.") }
        progress(ActionProgress(message: action == .apply ? "Disabling…" : "Enabling…"))
        let engine = DebloatStore.liveEngine()
        let coordinator = DebloatCoordinator(engine: engine, channel: context.privileged)
        do {
            // Switching a feature back on restores macOS's default where MacSpace has no saved value (a policy applied by an earlier
            // build, say); without this the switch did nothing and stayed off.
            var results = try await coordinator.execute(action, controlIDs: ids, options: DebloatPlanOptions(restoreFallbacks: action == .revert))
            results = await removeProfiles(results, engine: engine, channel: context.privileged)
            var summary = summarize(action, results)
            // Read back: every switch asked to go off must read off (or wait for the profile's approval). One that does not is named,
            // so a "Disable all" that left some on says which.
            if action == .apply {
                let stillOn = ids.compactMap { id in engine.controls.first { $0.id == id } }.filter { control in
                    ![.debloated, .awaitingApproval].contains(engine.status(of: control).state)
                }
                if !stillOn.isEmpty {
                    summary.details.insert("Still on: \(stillOn.map(\.title).joined(separator: ", ")).", at: 0)
                    if summary.outcome == .succeeded { summary.outcome = .needsAttention }
                }
            }
            // The profile was staged for approval: System Settings opens on it, and the page's button stays "Approve in System
            // Settings" until it is approved. No message of its own, or the button showed it first and needed a click to go.
            if results.contains(where: { result in result.steps.contains { $0.outcome == .pendingApproval } }), summary.outcome != .failed {
                openDeviceManagement()
                return ActionResult(outcome: .succeeded, message: "", details: summary.details, refresh: true)
            }
            return summary
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// System Settings > General > Device Management, where the profile is approved.
    static func openDeviceManagement() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// MacSpace profiles removed through the helper, which needs no approval.
    static func removeProfiles(_ identifiers: [String], context: ModuleContext) async -> ActionResult {
        guard let channel = context.privileged else { return .failed("Install the helper in Settings") }
        do {
            let data = try await channel.perform(operation: DebloatPrivilegedOperations.removeProfile, arguments: ["identifiers": identifiers.joined(separator: ",")])
            let outcome = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            let failed = outcome.filter { $0.value != "removed" }
            return failed.isEmpty ? ActionResult(outcome: .succeeded, message: "", refresh: true)
                : .failed("Couldn't remove a profile", details: failed.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })
        } catch {
            return .failed("Couldn't remove the profile", details: [error.localizedDescription])
        }
    }

    /// Switching a policy back on removes its profile, which only root can do: the helper removes it, with no approval to give.
    static func removeProfiles(_ results: [ControlChangeResult], engine: DebloatEngine, channel: (any PrivilegedChannel)?) async -> [ControlChangeResult] {
        let identifiers = Array(Set(results.flatMap { $0.steps.compactMap { ConfigurationProfileBuilder.identifiers(inRemovalNeeded: $0.detail) }.joined() })).sorted()
        guard !identifiers.isEmpty else { return results }
        var helperError: String?
        if let channel {
            do { _ = try await channel.perform(operation: DebloatPrivilegedOperations.removeProfile, arguments: ["identifiers": identifiers.joined(separator: ",")]) }
            catch { helperError = error.localizedDescription }
        } else {
            helperError = "the helper is not installed"
        }
        return results.map { result in
            guard let control = engine.controls.first(where: { $0.id == result.plan.controlID }) else { return result }
            // Judged by what macOS enforces now, not by the helper's answer.
            let after = engine.status(of: control)
            let back = after.state != .debloated && after.state != .awaitingRemoval
            let steps = result.steps.map { step -> StepResult in
                guard ConfigurationProfileBuilder.identifiers(inRemovalNeeded: step.detail) != nil else { return step }
                return back ? StepResult(settingID: step.settingID, outcome: .changed, detail: "Its profile was removed.")
                    : StepResult(settingID: step.settingID, outcome: .failed,
                                 detail: "Its profile could not be removed (\(helperError ?? "macOS still enforces it")); remove \"\(ConfigurationProfileBuilder.displayName(for: ConfigurationProfileBuilder.profileTitle))\" in System Settings > General > Device Management.")
            }
            return ControlChangeResult(plan: result.plan, executed: result.executed || back, steps: steps, statusAfter: after)
        }
    }

    static func summarize(_ action: ChangeAction, _ results: [ControlChangeResult]) -> ActionResult {
        var details: [String] = []
        var restart = false
        var approval = false
        var changed = 0
        for result in results {
            let title = DebloatCatalog.control(result.plan.controlID)?.title ?? result.plan.controlID
            details.append(contentsOf: result.plan.blockers.map { "\(title): \($0)" })
            for step in result.steps {
                switch step.outcome {
                case .failed, .blocked, .skipped: details.append("\(title): \(step.detail ?? step.outcome.rawValue)")
                case .pendingApproval: approval = true
                default: break
                }
            }
            if result.executed { changed += 1; restart = restart || result.plan.restart == .reboot }
        }
        if changed == 0 && !details.isEmpty { return ActionResult(outcome: .failed, message: "Couldn't change it", details: details, refresh: true) }
        if changed == 0 { return .succeeded(action == .apply ? "Already disabled" : "Already enabled") }
        if approval {
            return ActionResult(outcome: .needsAttention, message: "Approve the profile in System Settings",
                                details: ["Open System Settings > General > Device Management and approve the MacSpace profile there, once: it holds every policy switched off. Switching a policy back on later needs no approval."] + details, restartRequired: restart)
        }
        return ActionResult(outcome: .succeeded, message: action == .apply ? "Disabled" : "Enabled", details: details, restartRequired: restart)
    }
}
