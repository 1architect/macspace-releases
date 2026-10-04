import Foundation
import MacSpacePlatform

public enum DebloatEngineError: Error, Equatable, CustomStringConvertible {
    case unknownControl(String)

    public var description: String {
        switch self {
        case .unknownControl(let id): return "Unknown control \(id)."
        }
    }
}

public struct DebloatPlanOptions: Sendable {
    /// On revert, restore the catalog fallback for settings MacSpace never changed. By default MacSpace only
    /// undoes its own changes.
    public var restoreFallbacks: Bool
    /// Also stop (apply) or load (revert) the affected launchd services now, instead of waiting for the
    /// logout or reboot that rebuilds their domain.
    public var immediate: Bool
    /// Plan only the steps that need this privilege. The app plans `.user` steps itself and sends `.root` ones to
    /// the privileged helper.
    public var privilegeFilter: DebloatPrivilege?

    public init(restoreFallbacks: Bool = false, immediate: Bool = false, privilegeFilter: DebloatPrivilege? = nil) {
        self.restoreFallbacks = restoreFallbacks
        self.immediate = immediate
        self.privilegeFilter = privilegeFilter
    }
}

/// Probes, plans, applies and reverts catalog controls. Every change is journaled before it is made.
public final class DebloatEngine {
    public let controls: [DebloatControl]
    public let system: any DebloatSystem
    public let journal: any DebloatJournalStoring

    /// How long diagnostics must stay silent after a change before the change counts as effective.
    public static let submissionObservationWindow: TimeInterval = 24 * 3600

    public init(controls: [DebloatControl] = DebloatCatalog.controls, system: any DebloatSystem, journal: any DebloatJournalStoring) {
        self.controls = controls
        self.system = system
        self.journal = journal
    }

    public func control(_ id: String) throws -> DebloatControl {
        guard let control = controls.first(where: { $0.id == id }) else { throw DebloatEngineError.unknownControl(id) }
        return control
    }

    // MARK: Overrides launchd ignores

    public enum LaunchdIgnoreReason: String, Sendable {
        /// SIP is enabled and the Apple service is not in `RemovableServices` of launchd's rootless policy: the
        /// override is dropped at every boot and login.
        case sipCleared
        /// launchd marks the job `force-enabled` (e.g. ReportCrash): the override is kept but ignored.
        case forceEnabled

        public var explanation: String {
            switch self {
            case .sipCleared: return "dropped by launchd at boot and login while SIP is enabled (not in RemovableServices)"
            case .forceEnabled: return "launchd force-enables this service and ignores the override"
            }
        }
    }

    /// launchd settings of the control whose overrides launchd will not honor, by setting id.
    public func ignoredLaunchdSettings(_ control: DebloatControl) -> [String: LaunchdIgnoreReason] {
        var ignored: [String: LaunchdIgnoreReason] = [:]
        let removable = system.environment().sip == .enabled ? system.sipRemovableServices() : nil
        let jobs = system.launchdJobs()
        for setting in control.settings {
            guard let service = setting.launchd else { continue }
            if let removable, !removable.contains(service.label),
               jobs.job(service.domain, service.label)?.plistPath.hasPrefix("/System/") == true {
                ignored[setting.id] = .sipCleared
            } else if system.launchdForceEnabled(service) {
                ignored[setting.id] = .forceEnabled
            }
        }
        return ignored
    }

    /// Whether the control cannot take effect here: measured to have no effect with SIP enabled, or launchd ignores every one of its
    /// overrides.
    public func cannotTakeEffect(_ control: DebloatControl) -> Bool {
        if control.measuredIneffective(in: system.environment()) { return true }
        let services = control.settings.filter { $0.kind == .launchdService }
        return !services.isEmpty && services.count == control.settings.count && ignoredLaunchdSettings(control).count == services.count
    }

    static func ignoreSummary(_ reasons: some Collection<LaunchdIgnoreReason>) -> String {
        Set(reasons).map(\.explanation).sorted().joined(separator: "; ")
    }

    // MARK: Status

    public func status() -> [ControlStatus] {
        let entries = journal.allEntries
        let processes = system.processes()
        return controls.map { status(of: $0, entries: entries, processes: processes) }
    }

    public func status(of control: DebloatControl) -> ControlStatus {
        status(of: control, entries: journal.allEntries, processes: system.processes())
    }

    func settingStatus(_ setting: ControlSetting) -> SettingStatus {
        let desired = setting.desiredValue
        switch system.read(setting) {
        case .value(let current):
            var detail: String?
            if let flag = setting.featureFlag, let live = system.liveFeatureFlag(domain: flag.domain, feature: flag.feature) {
                let overridden: Bool? = { if case .value(.bool(let value)) = current { return value } else { return nil } }()
                detail = "live: \(live ? "enabled" : "disabled")"
                if let overridden, overridden != live { detail! += "; the override applies after a reboot" }
            }
            return SettingStatus(setting: setting, availability: .available, current: current, desired: desired,
                                 matchesDesired: current.matches(desired), detail: detail)
        case .unavailable(let detail):
            return SettingStatus(setting: setting, availability: .unavailable, current: nil, desired: desired, matchesDesired: nil, detail: detail)
        case .unreadable(let detail):
            return SettingStatus(setting: setting, availability: .unreadable, current: nil, desired: desired, matchesDesired: nil, detail: detail)
        }
    }

    func status(of control: DebloatControl, entries: [JournalEntry], processes: [RunningProcess]?) -> ControlStatus {
        let outstanding = entries.filter { $0.controlID == control.id && $0.action == .apply && $0.revertedAt == nil }
        let appliedAt = outstanding.map(\.at).max()
        let ignored = ignoredLaunchdSettings(control)
        let settings = control.settings.map(settingStatus).map { status -> SettingStatus in
            guard let note = ignored[status.setting.id]?.explanation else { return status }
            return SettingStatus(setting: status.setting, availability: status.availability, current: status.current, desired: status.desired,
                                 matchesDesired: status.matchesDesired, detail: [status.detail, note].compactMap { $0 }.joined(separator: "; "))
        }
        let state: ControlState
        if control.settings.isEmpty {
            state = .unknown
        } else {
            let available = settings.filter { $0.availability == .available }
            let unreadable = settings.filter { $0.availability == .unreadable }
            let mismatched = available.filter { $0.matchesDesired == false }
            let journaled = Set(outstanding.map(\.settingID))
            if available.isEmpty {
                state = unreadable.isEmpty ? .unavailable : .unknown
            } else if mismatched.isEmpty, unreadable.isEmpty, revertPending(control, available: available, entries: entries) {
                state = .awaitingRemoval
            } else if mismatched.isEmpty {
                state = unreadable.isEmpty ? .debloated : .unknown
            } else if case let pending = mismatched.filter({ journaled.contains($0.setting.id) }), !pending.isEmpty {
                // A generated profile that is not (or no longer) installed is waiting for the user, not drift.
                state = pending.allSatisfy { $0.setting.kind == .managedPreference } ? .awaitingApproval : .drifted
            } else if mismatched.count == available.count {
                state = .stock
            } else {
                state = .partial
            }
        }

        let effect = control.effect.map { evaluate($0, control: control, state: state, appliedAt: appliedAt, processes: processes) }
        return ControlStatus(controlID: control.id, state: state, effect: effect, settings: settings,
                             tested: control.tested, appliedAt: appliedAt)
    }

    /// A policy switched back on whose value the installed profile still enforces: the latest journal entry for one of its managed
    /// settings is a revert.
    func revertPending(_ control: DebloatControl, available: [SettingStatus], entries: [JournalEntry]) -> Bool {
        available.contains { status in
            guard status.setting.kind == .managedPreference else { return false }
            // The last written of the latest entries: an apply and a revert can carry the same time.
            let latest = entries.filter { $0.controlID == control.id && $0.settingID == status.setting.id }
                .reduce(nil as JournalEntry?) { latest, entry in (latest?.at ?? .distantPast) <= entry.at ? entry : latest }
            return latest?.action == .revert
        }
    }

    func evaluate(_ check: EffectCheck, control: DebloatControl, state: ControlState, appliedAt: Date?,
                  processes: [RunningProcess]?) -> EffectStatus {
        // Effects are judged only for fully applied controls; a partial control legitimately leaves some targeted
        // behavior running, and a drifted one is no longer applied.
        if cannotTakeEffect(control) {
            let reasons = control.measuredIneffective(in: system.environment())
                ? "measured to have no effect while SIP is enabled" : Self.ignoreSummary(ignoredLaunchdSettings(control).values)
            return EffectStatus(state: .notControllable, detail: "Cannot take effect on this Mac: \(reasons).")
        }
        let applied = state == .debloated
        let notApplied = state == .partial ? "Partially applied" : (state == .drifted ? "Undone" : "Not applied")
        switch check.kind {
        case .diagnosticSubmission:
            guard let history = system.diagnosticHistory() else {
                return EffectStatus(state: .notMeasured, detail: "DiagnosticMessagesHistory.plist could not be read.")
            }
            let last = history.lastFullSubmissionSuccess
            let lastText = last.map { "last successful submission \($0.ISO8601Format())" } ?? "no successful submission recorded"
            if control.mechanism == .systemPreference, system.environment().isPrerelease == true, history.seedAutoSubmit == true {
                return EffectStatus(state: .notControllable,
                                    detail: "Prerelease build with SeedAutoSubmit set: diagnostics are submitted regardless of this setting (\(lastText)).")
            }
            guard applied else { return EffectStatus(state: .notMeasured, detail: "\(notApplied) (\(lastText)).") }
            guard let appliedAt else {
                return EffectStatus(state: .notMeasured, detail: "Applied outside MacSpace, so there is no reference time (\(lastText)).")
            }
            // SubmitDiagInfo logs its opt-in decision on every run. That is the authoritative signal:
            // LastFullSubmissionSuccess also advances on opt-out runs that upload nothing but a ~480-byte check-in
            // (measured on 26B5091g, 2026-09-29).
            // The latest decision is what counts: a policy is applied when its profile is approved, which can be a while after MacSpace
            // staged it (`appliedAt`), and SubmitDiagInfo kept deciding IN until then.
            if let decisions = system.submissionDecisions(since: appliedAt)?.filter({ $0.at >= appliedAt }).sorted(by: { $0.at < $1.at }),
               let latest = decisions.last {
                if latest.optedIn {
                    return EffectStatus(state: .ineffective, detail: "SubmitDiagInfo decided optIn: IN at \(latest.at.ISO8601Format()), after the change (\(lastText)).")
                }
                let outs = decisions.reversed().prefix { !$0.optedIn }.count
                return EffectStatus(state: .effective, detail: "SubmitDiagInfo decided optIn: OUT \(outs) time(s) in a row, most recently at \(latest.at.ISO8601Format()) (\(lastText); opt-out runs still record a success).")
            }
            if let last, last > appliedAt {
                return EffectStatus(state: .ineffective, detail: "Diagnostics were submitted after the change at \(appliedAt.ISO8601Format()) (\(lastText)).")
            }
            // Submissions were observed every ~11–24 h, so silence only counts after a full window.
            let observed = system.now().timeIntervalSince(appliedAt)
            if observed < Self.submissionObservationWindow {
                return EffectStatus(state: .pending, detail: "No submission since the change at \(appliedAt.ISO8601Format()), but only \(Int(observed / 3600)) h of the \(Int(Self.submissionObservationWindow / 3600)) h observation window have passed (\(lastText)).")
            }
            return EffectStatus(state: .effective, detail: "No successful submission in the \(Int(observed / 3600)) h since the change at \(appliedAt.ISO8601Format()) (\(lastText)).")

        case .processesAbsent:
            guard let processes else { return EffectStatus(state: .notMeasured, detail: "The process list could not be read.") }
            let executables = Set(check.executables ?? [])
            let running = processes.filter { executables.contains($0.executable) }
            let names = running.map(\.name).sorted().joined(separator: ", ")
            guard applied else {
                return EffectStatus(state: .notMeasured, detail: running.isEmpty ? "\(notApplied); none running." : "\(notApplied); running: \(names).")
            }
            if running.isEmpty { return EffectStatus(state: .effective, detail: "None of the targeted processes are running.") }
            let now = system.now()
            // A disabled launchd job stays loaded (and KeepAlive relaunches it) until its domain is rebuilt, so
            // processes are expected until the required logout or reboot has happened after the change.
            if let appliedAt, let restart = system.environment().lastRestart(for: control.restart), restart < appliedAt {
                let hint = control.mechanism == .launchdOverride ? " or apply it immediately" : ""
                return EffectStatus(state: .pending, detail: "Running (\(names)) until the next \(control.restart.rawValue)\(hint).")
            }
            if let appliedAt, running.allSatisfy({ ($0.startedAt(now: now) ?? now) < appliedAt }) {
                return EffectStatus(state: .pending, detail: "Still running from before the change (\(names)); takes effect after \(control.restart.rawValue).")
            }
            return EffectStatus(state: .ineffective, detail: "Running although the control is applied: \(names).")
        }
    }

    // MARK: Plans

    public func plan(_ action: ChangeAction, controlIDs: [String], options: DebloatPlanOptions = DebloatPlanOptions()) throws -> [ControlChangePlan] {
        let entries = journal.allEntries
        return try controlIDs.map { try plan(action, control: control($0), entries: entries, options: options) }
    }

    func plan(_ action: ChangeAction, control: DebloatControl, entries: [JournalEntry], options: DebloatPlanOptions) -> ControlChangePlan {
        let environment = system.environment()
        var blockers: [String] = []
        var warnings: [String] = []

        if control.mechanism == .privateSurface {
            let command = action == .apply ? control.applyCommand : control.applyCommand?.replacingOccurrences(of: " disable", with: " enable")
            blockers.append("\(control.title) is \(action == .apply ? "applied" : "reverted") with `\(command ?? "its dedicated command")`, not by the catalog engine.")
        }
        let ignored = action == .apply ? ignoredLaunchdSettings(control) : [:]
        if action == .apply, control.measuredIneffective(in: environment) {
            blockers.append("Measured to have no effect while SIP is enabled: the change does not take effect.")
        } else if action == .apply, cannotTakeEffect(control) {
            blockers.append("Cannot take effect: \(Self.ignoreSummary(ignored.values)).")
        } else if !ignored.isEmpty {
            let labels = control.settings.filter { ignored[$0.id] != nil }.compactMap { $0.launchd?.label }
            warnings.append("launchd will not honor these overrides (\(Self.ignoreSummary(ignored.values))): \(labels.joined(separator: ", ")).")
        }
        if action == .apply {
            if !control.tested { warnings.append("Not tested yet: check that it takes effect after applying.") }
            if !control.breaks.isEmpty { warnings.append("Breaks: " + control.breaks.joined(separator: "; ")) }
        }
        if options.immediate, control.settings.contains(where: { $0.kind == .launchdService }) {
            if environment.sip == .enabled {
                warnings.append("SIP is enabled, so launchd is expected to refuse stopping or loading Apple services now (error 150); the change applies at the next \(control.restart.rawValue).")
            } else {
                warnings.append(action == .apply ? "Stops the services now (launchctl bootout) instead of at the next \(control.restart.rawValue)."
                                                 : "Loads re-enabled services now (launchctl bootstrap).")
            }
        }

        // On revert, also undo journaled settings the control no longer contains (the catalog changed since).
        var settingsToPlan = control.settings
        if action == .revert {
            let known = Set(control.settings.map(\.id))
            for entry in entries where entry.controlID == control.id && entry.action == .apply && entry.revertedAt == nil
                && !known.contains(entry.settingID) && !settingsToPlan.contains(where: { $0.id == entry.settingID }) {
                settingsToPlan.append(entry.setting)
            }
        }
        if let filter = options.privilegeFilter { settingsToPlan = settingsToPlan.filter { $0.privilege == filter } }
        let steps = settingsToPlan.map { setting -> ChangeStep in
            let privilege = setting.privilege
            var warning: String?
            let current: SettingValue?
            var blocker: String?
            switch system.read(setting) {
            case .value(let value): current = value
            case .unavailable(let detail): current = nil; blocker = detail
            case .unreadable(let detail): current = nil; blocker = "Current value unreadable, so it cannot be journaled: \(detail)"
            }

            let target: SettingValue
            var leaveAsIs = false
            switch action {
            case .apply:
                target = setting.desiredValue
            case .revert:
                let original = entries
                    .filter { $0.controlID == control.id && $0.settingID == setting.id && $0.action == .apply && $0.revertedAt == nil }
                    .min { $0.at < $1.at }?.before
                if let original {
                    target = original
                } else if options.restoreFallbacks, let fallback = setting.fallbackValue {
                    target = fallback
                } else if options.restoreFallbacks {
                    target = current ?? .absent
                    if blocker == nil {
                        blocker = "The original value is unknown (not changed by MacSpace and no known macOS default); restore it in System Settings."
                    }
                } else {
                    target = current ?? .absent
                    leaveAsIs = true
                    warning = "Not changed by MacSpace; left as is (pass --restore-defaults to reset it)."
                }
            }
            if leaveAsIs {
                return ChangeStep(setting: setting, privilege: privilege, from: current, to: target, alreadySatisfied: true,
                                  command: [], blocker: blocker, warning: warning)
            }
            // Already back to "no override" (e.g. launchd cleared it): nothing to write.
            if current == .absent, target == .absent {
                return ChangeStep(setting: setting, privilege: privilege, from: current, to: target, alreadySatisfied: true,
                                  command: [], blocker: blocker, warning: nil)
            }
            // launchd cannot remove an override; the closest restorable state is an explicit enable.
            var resolved = target
            if setting.kind == .launchdService, target == .absent {
                resolved = .launchdOverride(disabled: false)
                warning = "launchd has no command that removes an override; this sets an explicit enable."
            }
            let satisfied = current.map { $0.matches(resolved) } ?? false
            return ChangeStep(setting: setting, privilege: privilege, from: current, to: resolved, alreadySatisfied: satisfied,
                              command: system.command(for: setting, value: resolved), blocker: blocker, warning: satisfied ? nil : warning)
        }

        let needsOther = steps.filter { $0.blocker == nil && !$0.alreadySatisfied && $0.privilege != environment.privilege }
        if !needsOther.isEmpty, options.privilegeFilter == nil {
            warnings.append(environment.runningAsRoot
                ? "\(needsOther.count) user-scoped step(s) are skipped under sudo; run the same command without sudo for them."
                : "\(needsOther.count) step(s) need root; run the same command with sudo for them.")
        }
        return ControlChangePlan(controlID: control.id, action: action, steps: steps, blockers: blockers,
                                 warnings: warnings, restart: control.restart, immediate: options.immediate)
    }

    // MARK: Execution

    /// Runs the plans. Each change is journaled first (write-ahead) and verified by reading it back. Policies switched back on have
    /// their profiles removed first; then every policy switched off, and every one still waiting for approval, goes in one profile,
    /// opened once for approval (macOS keeps only one downloaded profile waiting, so one per policy left all but the last behind).
    public func execute(_ plans: [ControlChangePlan]) -> [ControlChangeResult] {
        let privilege = system.environment().privilege
        var runs = plans.map(executeSteps)
        var restage: Set<String> = []
        for index in runs.indices where runs[index].profileTouched && runs[index].plan.action == .revert {
            let (results, sharing) = removeProfiles(runs[index], privilege: privilege)
            runs[index].results = results
            restage.formUnion(sharing)
        }
        restage.subtract(runs.filter { $0.plan.action == .revert }.compactMap { $0.control?.id })
        let applying = runs.indices.filter { runs[$0].profileTouched && runs[$0].plan.action == .apply }
        if !applying.isEmpty || !restage.isEmpty {
            let ids = restage.union(applying.compactMap { runs[$0].control?.id })
            switch stageTogether(ids, privilege: privilege) {
            case .success(let staged):
                for index in applying { runs[index].results = Self.settle(runs[index].results, .pendingApproval, staged.message) }
            case .failure(let error):
                var log = journal.load(privilege)
                let undone = Set(applying.flatMap { runs[$0].stagedEntries })
                log.entries.removeAll { undone.contains($0.id) }
                try? journal.save(log, privilege)
                for index in applying { runs[index].results = Self.settle(runs[index].results, .failed, "\(error)") }
            }
        }
        return runs.map { run in
            guard let control = run.control else {
                return ControlChangeResult(plan: run.plan, executed: false, steps: run.results, statusAfter: nil)
            }
            let executed = run.results.contains { $0.outcome == .changed || $0.outcome == .pendingApproval }
            return ControlChangeResult(plan: run.plan, executed: executed, steps: run.results, statusAfter: status(of: control))
        }
    }

    /// Opens the profile of every policy waiting for approval again, in one: for a profile that was replaced, expired, or dismissed.
    /// Returns the policies it holds (none: nothing to approve).
    public func stagePendingProfiles() throws -> [String] {
        switch stageTogether([], privilege: system.environment().privilege) {
        case .success(let staged): return staged.controlIDs
        case .failure(let error): throw error
        }
    }

    private static func settle(_ results: [StepResult], _ outcome: StepOutcome, _ detail: String) -> [StepResult] {
        results.map { $0.outcome == .pendingApproval ? StepResult(settingID: $0.settingID, outcome: outcome, detail: detail) : $0 }
    }

    private struct PlanRun {
        let plan: ControlChangePlan
        let control: DebloatControl?
        var results: [StepResult]
        var profileTouched = false
        var stagedEntries: [UUID] = []
    }

    private func executeSteps(_ plan: ControlChangePlan) -> PlanRun {
        guard plan.runnable, let control = controls.first(where: { $0.id == plan.controlID }) else {
            let steps = plan.steps.map { StepResult(settingID: $0.setting.id, outcome: .blocked, detail: plan.blockers.first) }
            return PlanRun(plan: plan, control: nil, results: steps)
        }
        let privilege = system.environment().privilege
        let build = system.environment().build
        var results: [StepResult] = []
        var profileTouched = false
        var stagedEntries: [UUID] = []

        for step in plan.steps {
            let id = step.setting.id
            if let blocker = step.blocker {
                results.append(StepResult(settingID: id, outcome: .blocked, detail: blocker))
                continue
            }
            if step.privilege != privilege {
                if step.alreadySatisfied {
                    results.append(StepResult(settingID: id, outcome: .alreadySatisfied, detail: nil))
                } else {
                    results.append(StepResult(settingID: id, outcome: .skipped,
                                              detail: step.privilege == .root ? "Needs root; rerun with sudo." : "User setting; rerun without sudo."))
                }
                continue
            }
            if step.alreadySatisfied {
                if plan.action == .revert { try? markReverted(controlID: control.id, settingID: id, privilege: privilege) }
                if step.setting.kind == .managedPreference, plan.action == .revert { profileTouched = true }
                // An already-disabled service may still be loaded from before; an immediate change stops it as well.
                let session = plan.immediate && plan.action == .apply ? sessionChange(step, action: .apply) : nil
                results.append(StepResult(settingID: id, outcome: .alreadySatisfied, detail: session ?? step.warning))
                continue
            }
            if step.setting.kind == .managedPreference {
                let (result, entry) = journalManaged(step, control: control, action: plan.action, privilege: privilege, build: build)
                results.append(result)
                if let entry { stagedEntries.append(entry); profileTouched = true }
                continue
            }
            var result = perform(step, control: control, action: plan.action, privilege: privilege, build: build)
            if plan.immediate, result.outcome == .changed, let session = sessionChange(step, action: plan.action) {
                result = StepResult(settingID: id, outcome: .changed, detail: [result.detail, session].compactMap { $0 }.joined(separator: "; "))
            }
            results.append(result)
        }
        return PlanRun(plan: plan, control: control, results: results, profileTouched: profileTouched, stagedEntries: stagedEntries)
    }

    /// Journals a managed-preference change. The control's profile is staged or removed after its steps (`execute`).
    private func journalManaged(_ step: ChangeStep, control: DebloatControl, action: ChangeAction,
                                privilege: DebloatPrivilege, build: String?) -> (StepResult, UUID?) {
        let id = step.setting.id
        guard case .value(let before) = system.read(step.setting) else {
            return (StepResult(settingID: id, outcome: .failed, detail: "The current value could not be read."), nil)
        }
        let entry = JournalEntry(at: system.now(), controlID: control.id, setting: step.setting, action: action,
                                 before: before, after: step.to, build: build)
        var log = journal.load(privilege)
        log.entries.append(entry)
        do {
            try journal.save(log, privilege)
            if action == .revert { try markReverted(controlID: control.id, settingID: id, privilege: privilege, excluding: entry.id) }
        } catch {
            return (StepResult(settingID: id, outcome: .failed, detail: "Journal could not be written, so nothing was changed: \(error)"), nil)
        }
        return (StepResult(settingID: id, outcome: .pendingApproval, detail: nil), entry.id)
    }

    /// The policies in `ids` and every policy waiting for approval, in one profile opened for approval; each one's journal entries
    /// record the profile, so switching one back on knows what to remove.
    private func stageTogether(_ ids: Set<String>, privilege: DebloatPrivilege) -> Result<(controlIDs: [String], message: String), any Error> {
        let entries = journal.load(privilege).entries
        let members = controls.filter { control in
            guard control.settings.contains(where: { $0.kind == .managedPreference }) else { return false }
            return ids.contains(control.id) || status(of: control, entries: entries, processes: nil).state == .awaitingApproval
        }
        guard !members.isEmpty else { return .success((controlIDs: [], message: "")) }
        let identifier = ConfigurationProfileBuilder.identifier(forSet: members.map(\.id))
        do {
            let profile = try ConfigurationProfileBuilder.build(members.flatMap { $0.settings.compactMap(\.managed) }, identifier: identifier,
                                                                title: members.map(\.title).joined(separator: ", "))
            let message = try system.stageProfile(profile, fileName: ConfigurationProfileBuilder.fileName(forIdentifier: identifier))
            let memberIDs = Set(members.map(\.id))
            var log = journal.load(privilege)
            for index in log.entries.indices where memberIDs.contains(log.entries[index].controlID) && log.entries[index].action == .apply
                && log.entries[index].revertedAt == nil && log.entries[index].setting.kind == .managedPreference {
                log.entries[index].profile = identifier
            }
            try? journal.save(log, privilege)
            return .success((controlIDs: members.map(\.id), message: message))
        } catch {
            return .failure(error)
        }
    }

    /// Switching a policy back on: its own profile goes, with the profile it shared with others and the single profile of earlier
    /// versions, which may hold it too. Removing needs root, so outside the helper the step says which profiles to remove and the app
    /// asks the helper. Returns the policies that shared its profile: they lose it too and are staged again.
    private func removeProfiles(_ run: PlanRun, privilege: DebloatPrivilege) -> ([StepResult], Set<String>) {
        guard let control = run.control else { return (run.results, []) }
        let entries = journal.load(privilege).entries
        let own = [ConfigurationProfileBuilder.identifier(for: control.id), ConfigurationProfileBuilder.legacyIdentifier]
        let shared = Set(entries.filter { $0.controlID == control.id && $0.action == .apply }.compactMap(\.profile)).subtracting(own)
        let identifiers = own + shared.sorted()
        let sharing = Set(entries.filter { entry in
            entry.controlID != control.id && entry.action == .apply && entry.revertedAt == nil && entry.profile.map { shared.contains($0) } == true
        }.map(\.controlID))
        var removed: [String] = []
        for identifier in identifiers {
            do { removed.append(try system.removeProfile(identifier: identifier)) }
            catch { return (Self.settle(run.results, .pendingApproval, ConfigurationProfileBuilder.removalNeeded(identifiers)), sharing) }
        }
        return (Self.settle(run.results, .changed, removed.joined(separator: " ")), sharing)
    }

    private func perform(_ step: ChangeStep, control: DebloatControl, action: ChangeAction,
                         privilege: DebloatPrivilege, build: String?) -> StepResult {
        let id = step.setting.id
        guard case .value(let before) = system.read(step.setting) else {
            return StepResult(settingID: id, outcome: .failed, detail: "The current value could not be read just before the change.")
        }
        let entry = JournalEntry(at: system.now(), controlID: control.id, setting: step.setting, action: action,
                                 before: before, after: step.to, build: build)
        var log = journal.load(privilege)
        log.entries.append(entry)
        do {
            try journal.save(log, privilege)
        } catch {
            return StepResult(settingID: id, outcome: .failed, detail: "Journal could not be written, so nothing was changed: \(error)")
        }

        do {
            try system.write(step.setting, value: step.to)
        } catch {
            log.entries.removeAll { $0.id == entry.id }
            try? journal.save(log, privilege)
            return StepResult(settingID: id, outcome: .failed, detail: "\(error)")
        }

        guard case .value(let after) = system.read(step.setting), after.matches(step.to) else {
            return StepResult(settingID: id, outcome: .failed,
                              detail: "The command succeeded but the value does not read back as \(step.to); the change is journaled for revert.")
        }
        if action == .revert {
            do { try markReverted(controlID: control.id, settingID: id, privilege: privilege, excluding: entry.id) }
            catch { return StepResult(settingID: id, outcome: .changed, detail: "Reverted, but the journal could not be updated: \(error)") }
        }
        return StepResult(settingID: id, outcome: .changed, detail: "\(before) -> \(after)")
    }

    /// Stops a disabled service or loads a re-enabled one. Failures are reported, not fatal: the override is set
    /// either way and takes effect at the next logout or reboot.
    private func sessionChange(_ step: ChangeStep, action: ChangeAction) -> String? {
        guard let service = step.setting.launchd, case .launchdOverride(let disabled) = step.to else { return nil }
        do {
            if action == .apply && disabled {
                return try system.stopService(service) ? "stopped now" : "was not loaded"
            }
            if action == .revert && !disabled {
                return try system.startService(service) ? "loaded now" : "was already loaded"
            }
            return nil
        } catch {
            return "could not \(disabled ? "stop" : "load") it now (\(error)); takes effect at the next restart"
        }
    }

    private func markReverted(controlID: String, settingID: String, privilege: DebloatPrivilege, excluding: UUID? = nil) throws {
        var log = journal.load(privilege)
        let now = system.now()
        var changed = false
        for index in log.entries.indices where log.entries[index].controlID == controlID && log.entries[index].settingID == settingID
            && log.entries[index].action == .apply && log.entries[index].revertedAt == nil && log.entries[index].id != excluding {
            log.entries[index].revertedAt = now
            changed = true
        }
        if changed { try journal.save(log, privilege) }
    }
}
