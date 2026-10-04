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
        case "removeOldProfiles":
            // The profiles of earlier versions, removed through the helper (nothing to approve).
            guard let channel = context.privileged else { return .failed("The helper is not installed.") }
            do {
                let data = try await channel.perform(operation: DebloatPrivilegedOperations.removeProfile,
                                                     arguments: ["identifiers": ConfigurationProfileBuilder.retiredIdentifiers.joined(separator: ",")])
                let outcome = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
                let removed = outcome.filter { $0.value == "removed" }.keys.sorted()
                return .succeeded(removed.isEmpty ? "No profile of an earlier version was installed." : "Removed \(removed.count) profile(s) of an earlier version.",
                                  details: outcome.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })
            } catch {
                return .failed("The helper could not remove them: \(error.localizedDescription)")
            }
        case "approvePending":
            // One profile with every policy waiting for approval, opened again; System Settings shows it under Device Management.
            do {
                let ids = try DebloatStore.liveEngine().stagePendingProfiles()
                guard !ids.isEmpty else { return .succeeded("Nothing is waiting for approval.") }
                if let url = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") { NSWorkspace.shared.open(url) }
                let titles = ids.compactMap { DebloatCatalog.control($0)?.title }
                return ActionResult(outcome: .needsAttention, message: "Approve the MacSpace profile in System Settings.",
                                    details: ["It holds: \(titles.joined(separator: ", ")). Double-click it under Device Management, then Install."])
            } catch {
                return .failed("The profile could not be opened: \(error.localizedDescription)")
            }
        case "removePending":
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
        let engine = DebloatStore.liveEngine()
        let coordinator = DebloatCoordinator(engine: engine, channel: context.privileged)
        // The policies in force before switching back on: the single profile of earlier versions may hold some of them, and it goes.
        let enforcedBefore = action == .revert ? enforcedPolicies(engine) : []
        do {
            // Switching a feature back on restores macOS's default where MacSpace has no saved value (a policy applied by an earlier
            // build, say); without this the switch did nothing and stayed off.
            var results = try await coordinator.execute(action, controlIDs: ids, options: DebloatPlanOptions(restoreFallbacks: action == .revert))
            results = await removeProfiles(results, engine: engine, channel: context.privileged)
            var summary = summarize(action, results)
            // Policies that shared a profile with one switched back on lost it with it, and are in a new profile to approve.
            if action == .revert {
                let restaged = engine.controls.filter { !ids.contains($0.id) && engine.status(of: $0).state == .awaitingApproval }.map(\.title)
                if !restaged.isEmpty {
                    summary.details.append("\(restaged.joined(separator: ", ")) shared its profile and stay switched off once you approve their new profile in System Settings > General > Device Management.")
                    if summary.outcome == .succeeded { summary.outcome = .needsAttention }
                }
            }
            // Policies that only the earlier single profile enforced came back on with it: each gets a profile of its own, once.
            let moved = enforcedBefore.subtracting(ids).subtracting(enforcedPolicies(engine)).sorted()
            if !moved.isEmpty {
                let staged = try await coordinator.execute(.apply, controlIDs: moved, options: DebloatPlanOptions())
                let titles = moved.compactMap { DebloatCatalog.control($0)?.title }
                summary.details.append("The profile of an earlier version is gone; these stay switched off once you approve their new profile in System Settings > General > Device Management: \(titles.joined(separator: ", ")).")
                summary.details += staged.flatMap { result in result.steps.filter { $0.outcome == .failed }.map { $0.detail ?? "" } }
                if summary.outcome == .succeeded { summary.outcome = .needsAttention }
            }
            return summary
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Policy controls whose profile is in force now.
    static func enforcedPolicies(_ engine: DebloatEngine) -> Set<String> {
        Set(engine.controls.filter { $0.mechanism == .configurationProfile && engine.status(of: $0).state == .debloated }.map(\.id))
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
            // Judged by what macOS enforces now, not by the helper's answer: the earlier single profile may not have been installed.
            let after = engine.status(of: control)
            let back = after.state != .debloated && after.state != .awaitingRemoval
            let steps = result.steps.map { step -> StepResult in
                guard ConfigurationProfileBuilder.identifiers(inRemovalNeeded: step.detail) != nil else { return step }
                return back ? StepResult(settingID: step.settingID, outcome: .changed, detail: "Its profile was removed.")
                    : StepResult(settingID: step.settingID, outcome: .failed,
                                 detail: "Its profile could not be removed (\(helperError ?? "macOS still enforces it")); remove \"\(ConfigurationProfileBuilder.displayName(for: control.title))\" in System Settings > General > Device Management.")
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
        let verb = action == .apply ? "on" : "off"
        if changed == 0 && !details.isEmpty { return ActionResult(outcome: .failed, message: "Nothing was changed.", details: details, refresh: true) }
        if changed == 0 { return .succeeded(action == .apply ? "Already switched off." : "Already back on.") }
        if approval {
            return ActionResult(outcome: .needsAttention, message: "Approve the MacSpace profile to finish.",
                                details: ["Open System Settings > General > Device Management and approve the MacSpace profile there, once: it holds every policy switched off. Switching a policy back on later needs no approval."] + details, restartRequired: restart)
        }
        return ActionResult(outcome: .succeeded, message: "Turned \(changed) protection(s) \(verb).", details: details, restartRequired: restart)
    }
}
