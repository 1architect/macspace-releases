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

    public func summary(context: ModuleContext) async -> ScreenWidget {
        DebloatScreenBuilder.summary(await store.snapshot())
    }

    public func screen(context: ModuleContext) async -> Screen {
        DebloatScreenBuilder.screen(await store.snapshot())
    }

    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        defer { Task { await store.invalidate() } }
        switch request.actionID {
        case "toggle":
            guard let id = request.parameters["id"] else { return .failed("No control was named.") }
            let apply = Self.appliesProtection(switchValue: request.parameters["value"])
            return await Self.change(apply ? .apply : .revert, [id], unverified: request.parameters["unverified"] == "true", context: context, progress: progress)
        case "applyRecommended", "reapply":
            let ids = (request.parameters["ids"] ?? "").split(separator: ",").map(String.init)
            return await Self.change(.apply, ids, unverified: false, context: context, progress: progress)
        case "openProfiles":
            if let url = URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension") { NSWorkspace.shared.open(url) }
            return ActionResult(outcome: .succeeded, message: "Opened System Settings.", refresh: false)
        default:
            return .failed("Unknown action \(request.actionID).")
        }
    }

    /// The switch shows the feature: switching it off applies the protection, switching it on restores the original.
    static func appliesProtection(switchValue: String?) -> Bool { switchValue == "false" }

    static func change(_ action: ChangeAction, _ ids: [String], unverified: Bool, context: ModuleContext,
                       progress: @escaping ProgressSink) async -> ActionResult {
        guard !ids.isEmpty else { return .failed("No controls were selected.") }
        progress(ActionProgress(message: action == .apply ? "Switching off…" : "Switching back on…"))
        let coordinator = DebloatCoordinator(engine: DebloatStore.liveEngine(), channel: context.privileged)
        do {
            let results = try await coordinator.execute(action, controlIDs: ids, options: DebloatPlanOptions(allowUnverified: unverified))
            return summarize(action, results)
        } catch {
            return .failed(error.localizedDescription)
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
        if approval {
            return ActionResult(outcome: .needsAttention, message: "Approve the MACSPACE profile to finish.",
                                details: ["Open System Settings > General > Device Management and approve it."] + details, restartRequired: restart)
        }
        return ActionResult(outcome: .succeeded, message: "Turned \(changed) protection(s) \(verb).", details: details, restartRequired: restart)
    }
}
