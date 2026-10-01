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
        if needsRoot {
            guard let channel else { throw PrivilegedHelperError.connection("root steps are needed but the helper is not available") }
            let operation = action == .apply ? DebloatPrivilegedOperations.apply : DebloatPrivilegedOperations.revert
            let results = try await channel.perform([ControlChangeResult].self, operation: operation,
                                                    arguments: DebloatPrivilegedOperations.arguments(controlIDs: controlIDs, options: options))
            for result in results { rootResults[result.plan.controlID] = result }
        }

        let fullPlans = try engine.plan(action, controlIDs: controlIDs, options: options)
        return zip(userResults, fullPlans).map { user, full in
            let root = rootResults[user.plan.controlID]
            let control = engine.controls.first { $0.id == user.plan.controlID }
            return ControlChangeResult(plan: full, executed: user.executed || (root?.executed ?? false), steps: user.steps + (root?.steps ?? []),
                                       statusAfter: control.map(engine.status(of:)))
        }
    }
}
