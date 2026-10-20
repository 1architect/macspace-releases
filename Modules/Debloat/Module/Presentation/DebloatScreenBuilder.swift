import Foundation
import MacSpaceDebloatPrivileged
import MacSpaceSdk

enum DebloatScreenBuilder {
    static let categoryOrder: [ControlCategory] = [.telemetry, .advertising, .siri, .appleIntelligence, .suggestions, .appServices, .diagnostics]

    static func title(_ category: ControlCategory) -> String {
        switch category {
        case .telemetry: return loc("Analytics and telemetry")
        case .advertising: return loc("Advertising")
        case .siri: return loc("Siri")
        case .appleIntelligence: return loc("Apple Intelligence features")
        case .suggestions: return loc("Suggestions and search")
        case .experiments: return loc("Experiments")
        case .backgroundAnalysis: return loc("Background analysis")
        case .appServices: return loc("Apps")
        case .diagnostics: return loc("Diagnostics")
        }
    }

    // MARK: Per-control

    static func isOn(_ status: ControlStatus?) -> Bool {
        status.map { $0.state == .debloated || $0.state == .awaitingApproval } ?? false
    }

    static func needsHelper(_ control: DebloatControl) -> Bool {
        control.settings.contains { $0.privilege == .root }
    }

    /// Only what is unusual gets a badge; a switch that is simply on or off says enough by itself.
    static func badge(_ control: DebloatControl, _ status: ControlStatus?, cannotTakeEffect: Bool, environment: DebloatEnvironment? = nil) -> Badge? {
        guard let status else { return nil }
        // What the state means now is the pill's hover tag: the (i) says only what the switch does (`InfoText`).
        let why = effectExplanation(control, status)
        if cannotTakeEffect { return Badge(loc("Cannot take effect here"), .info, help: why) }
        // Changed since the Mac last started, and only a restart applies it: the app's one restart pill (`Badge.restartRequired`).
        if let environment, restartPending(control, status, environment) { return .restartRequired() }
        // A retired switch says why it is still shown.
        if control.retired != nil { return Badge(retired[control.id] ?? loc("No longer works"), .info) }
        // Screen Time or an organization's profile enforces it, not MacSpace (`DebloatEngine.status`).
        if status.managedElsewhere == true, status.state != .debloated { return Badge(loc("Set by another profile"), .info) }
        switch status.state {
        case .debloated:
            switch status.effect?.state {
            case .ineffective?: return Badge(loc("Not working"), .info, help: why)
            case .pending?:
                if control.effect?.kind == .diagnosticSubmission { return Badge(loc("Verifying"), .info, help: why) }
                return control.restart == .reboot ? .restartRequired(help: why) : Badge(loc("After restart"), .action, help: why)
            // No badge when macOS logged no decision to read: SubmitDiagInfo can go more than a day without one, and its log entries
            // expire, so "Not verified" stood on a switch whose settings were written and read back and which macOS then honored
            // (optIn: OUT, 2026-10-18). Only a decision against it is worth a pill.
            case .notControllable?: return Badge(loc("Cannot take effect here"), .info, help: why)
            default: return nil
            }
        case .awaitingApproval, .awaitingRemoval: return Badge(loc("Waiting for approval"), .action)
        case .drifted: return Badge(loc("Undone by macOS"), .action)
        case .partial: return Badge(loc("Partly off"), .info)
        case .unavailable: return Badge(loc("Not on this macOS"), .info)
        case .unknown: return Badge(loc("Cannot read"), .info)
        case .stock: return nil
        }
    }

    /// A switch only a restart applies (`RestartRequirement.reboot`), switched off since the Mac last started.
    static func restartPending(_ control: DebloatControl, _ status: ControlStatus, _ environment: DebloatEnvironment) -> Bool {
        guard control.restart == .reboot, status.state == .debloated || status.state == .partial,
              let applied = status.appliedAt, let booted = environment.lastRestart(for: .reboot) else { return false }
        return applied > booted
    }

    /// The pill of a retired switch: why to switch it off.
    static let retired: [String: String] = [
        "ai.generative-indexing": loc("Breaks Mail search"),
        "ai.features-policy": loc("No longer works"),
    ]

    static func restartText(_ restart: RestartRequirement) -> String? {
        switch restart {
        case .none: return nil
        case .appRelaunch: return loc("Reopen apps to apply.")
        case .logout: return loc("Log out to apply.")
        case .reboot: return loc("Restart to apply.")
        }
    }

    /// What each switch does for the user, and what stops working. The catalog's summaries and notes are for developers.
    static let plain: [String: String] = [
        "telemetry.diagnostics": loc("Stops sending usage and crash data to Apple and app developers."),
        "telemetry.diagnostics-policy": loc("Stops sending usage and crash data to Apple, also on beta versions of macOS, which ignore the setting above."),
        "telemetry.siri-improvement": loc("Stops sharing Siri and Dictation recordings with Apple."),
        "telemetry.on-device-speech-policy": loc("Dictation and translation stay on this Mac. Languages without an on-device model stop working."),
        "ads.personalized-ads": loc("Apple stops picking ads based on what you do."),
        "ads.advertising-identifier-policy": loc("Apps can't track you with the advertising identifier or ask to."),
        "siri.siri-ai-flag": loc("Stops the Siri AI search app; Spotlight goes back to classic search. To turn off Siri itself, use the Siri & Apple Intelligence page."),
        "ai.visual-intelligence": loc("Turns off Visual Intelligence. Visual Look Up may stop working too."),
        // Retired, and switched back on by MacSpace where it can (`DebloatModule.undoRetired`); shown only where that could not happen.
        "ai.generative-indexing": loc("Switch it off, then restart your Mac."),
        // Retired, and removed by MacSpace where it can (`DebloatModule.undoRetired`); shown only where that could not happen.
        "ai.features-policy": loc("Switch it off. To turn off Apple Intelligence, use the Siri page."),
        "suggestions.spotlight-internet-policy": loc("Spotlight stops sending your searches to Apple. No more web results in Spotlight."),
        "diagnostics.tailspin": loc("Stops macOS from constantly recording activity for hang reports. Frees about 100 MB of memory."),
        "diagnostics.crash-reporter": loc("No more \"quit unexpectedly\" dialogs."),
        "apps.game-center-policy": loc("Turns off Game Center."),
        "apps.news-policy": loc("Hides Apple News and its widgets."),
    ]

    /// What the switch does and when it applies, the same whatever its state (`InfoText`). Why it is not working is its badge's help.
    static func detail(_ control: DebloatControl) -> String {
        var lines: [String] = [plain[control.id] ?? control.summary]
        if let restart = restartText(control.restart) { lines.append(restart) }
        return lines.joined(separator: " ")
    }

    /// Helper/CLI diagnostics are technical English. The interface describes their structured state in the module's language.
    static func effectExplanation(_ control: DebloatControl, _ status: ControlStatus?) -> String? {
        guard let effect = status?.effect else { return nil }
        if effect.state == .notControllable {
            if control.effect?.kind == .diagnosticSubmission, control.mechanism == .systemPreference {
                return loc("This beta version of macOS ignores the regular analytics setting. Use the profile option instead.")
            }
            return loc("macOS prevents this change from taking effect on this Mac.")
        }
        guard status?.state == .debloated else { return nil }
        if control.effect?.kind == .diagnosticSubmission {
            switch effect.state {
            case .ineffective: return loc("macOS still chose to send diagnostics after this change.")
            case .pending: return loc("Waiting for macOS's next diagnostics decision. A recorded success can also be a check-in without diagnostics.")
            default: return nil
            }
        }
        return effect.state == .ineffective ? loc("A process covered by this setting is still running after the change.") : nil
    }

    /// What a switch is called: what switching it on does.
    static func title(_ control: DebloatControl) -> String { loc("Disable \(name(control))") }

    /// A control's name in the user's language. The catalog is shared with the helper, which has no translations, so its English is
    /// looked up here.
    static func name(_ control: DebloatControl) -> String { locKey(control.title) }

    static func row(_ control: DebloatControl, _ snapshot: DebloatSnapshot) -> ToggleRow {
        let status = snapshot.status(control.id)
        let on = isOn(status)
        // A retired switch can only be switched off, which removes what it applied.
        // Set by Screen Time or another profile: switching it on here would change nothing.
        let elsewhere = status?.managedElsewhere == true && !on
        let blocked = snapshot.cannotTakeEffect.contains(control.id) || status?.state == .unavailable || control.retired != nil && !on || elsewhere
        // No confirmation: the switch moves at once and the change follows; if it fails, the switch goes back and says why. What a
        // switch changes and breaks is behind its (i).
        var action = Action(id: "toggle", title: title(control), parameters: ["id": control.id])
        if needsHelper(control) { action.requires = [.privilegedHelper] }
        // The switch shows the protection, named as such: "Disable <feature>" on = MacSpace switched the feature off.
        return ToggleRow(id: control.id, title: title(control), isOn: on, isEnabled: !blocked,
                         badge: badge(control, status, cannotTakeEffect: snapshot.cannotTakeEffect.contains(control.id), environment: snapshot.environment),
                         detail: detail(control), action: action)
    }

    // MARK: Screens

    static func counts(_ snapshot: DebloatSnapshot) -> (on: Int, total: Int, awaiting: [DebloatControl], drifted: [DebloatControl]) {
        let usable = snapshot.controls.filter { $0.retired == nil && snapshot.status($0.id)?.state != .unavailable && !snapshot.cannotTakeEffect.contains($0.id) }
        let on = usable.filter { snapshot.status($0.id)?.state == .debloated }.count
        let awaiting = usable.filter { control in snapshot.status(control.id).map { [.awaitingApproval, .awaitingRemoval].contains($0.state) } ?? false }
        let drifted = usable.filter { snapshot.status($0.id)?.state == .drifted }
        return (on, usable.count, awaiting, drifted)
    }

    /// Policies: controls that only a configuration profile can apply, which macOS asks the user to approve. They are listed apart.
    static func isPolicy(_ control: DebloatControl) -> Bool { control.mechanism == .configurationProfile }

    /// Every control that can take effect here and is not off yet, policies, untested ones and those macOS switched back on included:
    /// "Switch all off" switches all of them off. Only what cannot be changed here (not on this macOS, ignored by launchd) and what is
    /// already off or waiting for approval is left out.
    static func recommended(_ snapshot: DebloatSnapshot) -> [DebloatControl] {
        snapshot.controls.filter { control in
            guard control.retired == nil, let status = snapshot.status(control.id), !snapshot.cannotTakeEffect.contains(control.id),
                  status.managedElsewhere != true else { return false }
            switch status.state {
            case .stock, .partial, .drifted, .unknown, .awaitingRemoval: return true
            case .debloated, .awaitingApproval, .unavailable: return false
            }
        }
    }

    static func tile(_ snapshot: DebloatSnapshot) -> Tile {
        let counts = counts(snapshot)
        let graphic = TileGraphic.dots(dots(snapshot))
        if !counts.drifted.isEmpty { return Tile(title: loc("debloat"), status: loc("\(counts.drifted.count) undone by macOS"), needsAttention: true, graphic: graphic) }
        if !counts.awaiting.isEmpty { return Tile(title: loc("debloat"), status: loc("\(counts.awaiting.count) awaiting approval"), needsAttention: true, graphic: graphic) }
        return Tile(title: loc("debloat"), status: loc("\(counts.on)/\(counts.total) disabled"), graphic: graphic)
    }

    /// One dot per control that can take effect here, in page order: done when switched off, attention when macOS undid it.
    static func dots(_ snapshot: DebloatSnapshot) -> [TileDot] {
        categoryOrder.flatMap { category in snapshot.controls.filter { $0.category == category } }
            .filter { $0.retired == nil && snapshot.status($0.id)?.state != .unavailable && !snapshot.cannotTakeEffect.contains($0.id) }
            .map { control in
                switch snapshot.status(control.id)?.state {
                case .debloated?: return .done
                case .drifted?: return .attention
                default: return .open
                }
            }
    }

    /// The page's main button, which does what the switches most need: while a feature still runs, it switches them all off;
    /// once they are all off, it turns back on everything MacSpace switched off. nil when neither applies.
    static func primary(_ snapshot: DebloatSnapshot) -> Action? {
        fix(snapshot) ?? restart(snapshot) ?? switchOffRecommended(snapshot) ?? turnAllBackOn(snapshot)
    }

    /// A switch is waiting for a restart (its row says Restart required): the page's button is the app's restart.
    static func restart(_ snapshot: DebloatSnapshot) -> Action? {
        let pending = snapshot.controls.contains { control in
            snapshot.status(control.id).map { restartPending(control, $0, snapshot.environment) } ?? false
        }
        return pending ? .restart() : nil
    }

    /// When something is not right, the main button becomes what fixes it, before anything else: features macOS enabled again,
    /// a profile waiting for approval, a profile left to remove. No banner of its own: the button changes into the fix.
    static func fix(_ snapshot: DebloatSnapshot) -> Action? {
        let counts = counts(snapshot)
        if !counts.drifted.isEmpty {
            return Action(id: "reapply", title: counts.drifted.count == 1 ? loc("Disable \(name(counts.drifted[0])) again") : loc("Disable \(counts.drifted.count) features again"),
                          role: .prominent, parameters: ["ids": counts.drifted.map(\.id).joined(separator: ",")], requires: [.privilegedHelper])
        }
        // The one MacSpace profile, changed: approving it is what switches policies off or back on. Opened again on demand (macOS
        // drops a downloaded profile after a while).
        switch snapshot.profileWork {
        case .approve:
            return Action(id: "approvePending", title: loc("Approve in System Settings"), role: .prominent)
        case .remove, .cleanUp:
            // Removing needs no approval, only the helper: it happens with the switch (or, for earlier versions' profiles, by itself
            // when the page is read). The button is for when that could not happen, and asks for the helper if it is missing.
            return Action(id: "removePending", title: loc("Finish"), role: .prominent, requires: [.privilegedHelper])
        case .none:
            return nil
        }
    }

    /// Controls switched off, policies included, whose values MacSpace can restore (including those macOS partly undid or waiting
    /// for approval).
    static func switchedOff(_ snapshot: DebloatSnapshot) -> [DebloatControl] {
        snapshot.controls.filter { control in
            guard let state = snapshot.status(control.id)?.state else { return false }
            return state == .debloated || state == .awaitingApproval || state == .drifted
        }
    }

    /// Turns back on every feature MacSpace switched off. nil when there is none.
    static func turnAllBackOn(_ snapshot: DebloatSnapshot) -> Action? {
        let controls = switchedOff(snapshot)
        guard !controls.isEmpty else { return nil }
        return Action(id: "restoreAll", title: loc("Enable all"), symbol: "arrow.uturn.backward", role: .prominent,
                      parameters: ["ids": controls.map(\.id).joined(separator: ",")],
                      confirmation: Confirmation(title: loc("Enable all \(controls.count) features again?"),
                                                 message: loc("MacSpace restores the settings it saved before disabling them."),
                                                 confirmTitle: loc("Enable")),
                      requires: controls.contains(where: needsHelper) ? [.privilegedHelper] : [])
    }

    /// Switches off every feature that is still on. nil when there is none.
    static func switchOffRecommended(_ snapshot: DebloatSnapshot) -> Action? {
        let recommended = recommended(snapshot)
        guard !recommended.isEmpty else { return nil }
        // Short: what happens, and only what the user has to do or check.
        var message = loc("Each one can be enabled again.")
        if recommended.contains(where: isPolicy) { message += " " + loc("macOS asks you to approve the policy profile once.") }
        if recommended.contains(where: { !$0.tested }) { message += " " + loc("Some are not tested yet.") }
        return Action(id: "applyRecommended", title: loc("Disable all"), symbol: "checkmark.shield", role: .prominent,
                      parameters: ["ids": recommended.map(\.id).joined(separator: ",")],
                      confirmation: Confirmation(title: loc("Disable \(recommended.count) features?"), message: message, confirmTitle: loc("Disable")),
                      requires: [.privilegedHelper])
    }

    /// Retired controls that do harm and are still applied here: MacSpace switches them back on by itself.
    static func retiredToUndo(_ snapshot: DebloatSnapshot) -> [DebloatControl] {
        snapshot.controls.filter { control in
            control.retired != nil && control.undoesWhenRetired && snapshot.status(control.id).map { DebloatStore.appliedStates.contains($0.state) } == true
        }
    }

    /// What the background watch switched off again lately: macOS switched it back on, MacSpace switched it off.
    static func reappliedNotice(_ snapshot: DebloatSnapshot) -> Banner? {
        guard let latest = snapshot.reapplied.first else { return nil }
        var titles: [String] = []
        for title in snapshot.reapplied.flatMap(\.titles).map(locKey) where !titles.contains(title) { titles.append(title) }
        let when = latest.at.formatted(.relative(presentation: .named))
        return Banner(id: "reapplied", severity: .info,
                      title: titles.count == 1 ? loc("\(titles[0]) was turned back on by macOS") : loc("\(titles.count) features were turned back on by macOS"),
                      message: titles.count == 1 ? loc("MacSpace disabled it again, most recently \(when).") : loc("MacSpace disabled them again, most recently \(when)."))
    }

    static func screen(_ snapshot: DebloatSnapshot) -> Screen {
        let counts = counts(snapshot)
        var widgets: [ScreenWidget] = []
        if let notice = reappliedNotice(snapshot) { widgets.append(.banner(notice)) }
        for category in categoryOrder {
            let controls = snapshot.controls.filter { $0.category == category && !isPolicy($0) }
            guard !controls.isEmpty else { continue }
            widgets.append(.toggles(ToggleList(id: "cat:\(category.rawValue)", title: title(category),
                                               footnote: nil,
                                               rows: controls.map { row($0, snapshot) })))
        }
        // Apart, and last: these need a profile, which macOS asks the user to approve.
        let policies = categoryOrder.flatMap { category in snapshot.controls.filter { $0.category == category && isPolicy($0) } }
        if !policies.isEmpty {
            widgets.append(.toggles(ToggleList(id: "policies", title: loc("Policies"),
                                               footnote: loc("Disabling one asks you to approve a profile in System Settings > General > Device Management."),
                                               rows: policies.map { row($0, snapshot) })))
        }
        return Screen(title: loc("Debloat"), primary: primary(snapshot), widgets: widgets)
    }
}
