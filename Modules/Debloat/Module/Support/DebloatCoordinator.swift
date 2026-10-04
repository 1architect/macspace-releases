import Foundation
import MacSpacePlatform
import MacSpaceDebloatPrivileged
import MacSpaceSdk

/// Runs a change the way the app should: steps that need only the user run in the app, steps that need root go through the
/// helper. Each side journals what it changed, so every change can be undone.
struct DebloatCoordinator {
    let engine: DebloatEngine
    let channel: (any PrivilegedChannel)?

    func execute(_ action: ChangeAction, controlIDs: [String], options: DebloatPlanOptions) async throws -> [ControlChangeResult] {
        var userOptions = options
        userOptions.privilegeFilter = .user
        let userResults = engine.execute(try engine.plan(action, controlIDs: controlIDs, options: userOptions))

        // Only call the helper when some root step would change something.
        var rootOptions = options
        rootOptions.privilegeFilter = .root
        let rootPlans = try engine.plan(action, controlIDs: controlIDs, options: rootOptions)
        let needsRoot = rootPlans.contains { plan in plan.runnable && plan.steps.contains { !$0.alreadySatisfied && $0.blocker == nil } }
        var rootResults: [String: ControlChangeResult] = [:]
        // The user's own steps are done by now: a helper that fails must not hide them, or the page said nothing was changed while
        // half of it was. Its root steps are reported as failed, control by control, with the reason.
        var rootFailure: String?
        if needsRoot {
            if let channel {
                let operation = action == .apply ? DebloatPrivilegedOperations.apply : DebloatPrivilegedOperations.revert
                do {
                    let results = try await channel.perform([ControlChangeResult].self, operation: operation,
                                                            arguments: DebloatPrivilegedOperations.arguments(controlIDs: controlIDs, options: options))
                    for result in results { rootResults[result.plan.controlID] = result }
                } catch {
                    rootFailure = "The helper could not make the change: \(error.localizedDescription)"
                }
            } else {
                rootFailure = "This needs the helper, which is not installed. Turn it on in Settings."
            }
        }

        let fullPlans = try engine.plan(action, controlIDs: controlIDs, options: options)
        let rootPending = Dictionary(uniqueKeysWithValues: rootPlans.map { plan in
            (plan.controlID, plan.steps.filter { !$0.alreadySatisfied && $0.blocker == nil })
        })
        return zip(userResults, fullPlans).map { user, full in
            let control = engine.controls.first { $0.id == user.plan.controlID }
            var rootSteps = rootResults[user.plan.controlID]?.steps ?? []
            if let rootFailure, rootSteps.isEmpty {
                rootSteps = (rootPending[user.plan.controlID] ?? []).map { StepResult(settingID: $0.setting.id, outcome: .failed, detail: rootFailure) }
            }
            return ControlChangeResult(plan: full, executed: user.executed || (rootResults[user.plan.controlID]?.executed ?? false),
                                       steps: user.steps + rootSteps, statusAfter: control.map(engine.status(of:)))
        }
    }
}
