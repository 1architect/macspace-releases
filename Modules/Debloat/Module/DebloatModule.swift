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
        DebloatScreenBuilder.tile(await store.snapshot())
    }

    public func screen(context: ModuleContext) async -> Screen {
        DebloatScreenBuilder.screen(await store.snapshot())
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
        case "openProfiles":
            if let url = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") { NSWorkspace.shared.open(url) }
            return ActionResult(outcome: .succeeded, message: "Opened System Settings.", refresh: false)
        default:
            return .failed("Unknown action \(request.actionID).")
        }
    }

    /// The switch shows the feature: switching it off applies the protection, switching it on restores the original.
    static func appliesProtection(switchValue: String?) -> Bool { switchValue == "false" }

    static func change(_ action: ChangeAction, _ ids: [String], context: ModuleContext,
                       progress: @escaping ProgressSink) async -> ActionResult {
        guard !ids.isEmpty else { return .failed("No controls were selected.") }
        progress(ActionProgress(message: action == .apply ? "Switching off…" : "Switching back on…"))
        let coordinator = DebloatCoordinator(engine: DebloatStore.liveEngine(), channel: context.privileged)
        do {
            // Switching a feature back on restores macOS's default where MacSpace has no saved value (a policy applied by an earlier
            // build, say); without this the switch did nothing and stayed off.
            var results = try await coordinator.execute(action, controlIDs: ids, options: DebloatPlanOptions(restoreFallbacks: action == .revert))
            results = await removeProfileIfEmpty(results, channel: context.privileged)
            return summarize(action, results)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// When the last policy goes, the profile has to be removed, which only root can do: the helper removes it. Until then macOS
    /// keeps enforcing every policy in it.
    static func removeProfileIfEmpty(_ results: [ControlChangeResult], channel: (any PrivilegedChannel)?) async -> [ControlChangeResult] {
        let needed = results.contains { $0.steps.contains { $0.detail == ConfigurationProfileBuilder.removalNeeded } }
        guard needed, let channel else { return results }
        let outcome: (StepOutcome, String)
        do {
            let data = try await channel.perform(operation: DebloatPrivilegedOperations.removeProfile, arguments: [:])
            outcome = (.changed, String(decoding: data, as: UTF8.self))
        } catch {
            outcome = (.failed, "The helper could not remove the \"\(ConfigurationProfileBuilder.displayName)\" profile (\(error.localizedDescription)); remove it in System Settings > General > Device Management.")
        }
        return results.map { result in
            let steps = result.steps.map { $0.detail == ConfigurationProfileBuilder.removalNeeded ? StepResult(settingID: $0.settingID, outcome: outcome.0, detail: outcome.1) : $0 }
            return ControlChangeResult(plan: result.plan, executed: result.executed || outcome.0 == .changed, steps: steps, statusAfter: result.statusAfter)
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
        let verb = action == .apply ? "on" : "off"
        if changed == 0 && !details.isEmpty { return ActionResult(outcome: .failed, message: "Nothing was changed.", details: details, refresh: true) }
        if changed == 0 { return .succeeded(action == .apply ? "Already switched off." : "Already back on.") }
        if approval {
            return ActionResult(outcome: .needsAttention, message: action == .apply ? "Approve the MacSpace profile to finish." : "Approve the updated MacSpace profile to finish turning it back on.",
                                details: ["Open System Settings > General > Device Management and approve it."] + details, restartRequired: restart)
        }
        return ActionResult(outcome: .succeeded, message: "Turned \(changed) protection(s) \(verb).", details: details, restartRequired: restart)
    }
}
