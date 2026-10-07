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
    static func badge(_ control: DebloatControl, _ status: ControlStatus?, cannotTakeEffect: Bool) -> Badge? {
        guard let status else { return nil }
        if cannotTakeEffect { return Badge(loc("Cannot take effect here"), tone: .critical) }
        switch status.state {
        case .debloated:
            switch status.effect?.state {
            case .ineffective?: return Badge(loc("Not working"), tone: .critical)
            case .pending?: return Badge(loc("After restart"), tone: .caution)
            case .notControllable?: return Badge(loc("Cannot take effect here"), tone: .critical)
            default: return nil
            }
        case .awaitingApproval, .awaitingRemoval: return Badge(loc("Waiting for approval"), tone: .caution)
        case .drifted: return Badge(loc("Undone by macOS"), tone: .critical)
        case .partial: return Badge(loc("Partly off"), tone: .caution)
        case .unavailable: return Badge(loc("Not on this macOS"))
        case .unknown: return Badge(loc("Cannot read"))
        case .stock: return nil
        }
    }

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
        "siri.siri-ai-flag": loc("Turns off Siri AI. Spotlight goes back to classic search."),
        "ai.visual-intelligence": loc("Turns off Visual Intelligence. Visual Look Up may stop working too."),
        "ai.generative-indexing": loc("Stops Apple Intelligence from indexing your Mail and personal data."),
        "ai.features-policy": loc("Turns off Writing Tools, Genmoji, Image Playground, summaries, smart replies and ChatGPT."),
        "suggestions.spotlight-internet-policy": loc("Spotlight stops sending your searches to Apple. No more web results in Spotlight."),
        "diagnostics.tailspin": loc("Stops macOS from constantly recording activity for hang reports. Frees about 100 MB of memory."),
        "diagnostics.crash-reporter": loc("No more \"quit unexpectedly\" dialogs."),
        "apps.game-center-policy": loc("Turns off Game Center."),
        "apps.news-policy": loc("Hides Apple News and its widgets."),
    ]

    /// What the switch does, when to expect it, and why it is not working when it is not.
    static func detail(_ control: DebloatControl, _ status: ControlStatus?) -> String {
        var lines: [String] = [plain[control.id] ?? control.summary]
        if let restart = restartText(control.restart) { lines.append(restart) }
        let problem: Set<EffectState> = [.ineffective, .notControllable]
        if let effect = status?.effect, problem.contains(effect.state), !effect.detail.isEmpty { lines.append(effect.detail) }
        return lines.joined(separator: " ")
    }

    /// What a switch is called: what switching it on does.
    static func title(_ control: DebloatControl) -> String { loc("Disable \(name(control))") }

    /// A control's name in the user's language. The catalog is shared with the helper, which has no translations, so its English is
    /// looked up here.
    static func name(_ control: DebloatControl) -> String { locKey(control.title) }

    static func row(_ control: DebloatControl, _ snapshot: DebloatSnapshot) -> ToggleRow {
        let status = snapshot.status(control.id)
        let blocked = snapshot.cannotTakeEffect.contains(control.id) || status?.state == .unavailable
        let on = isOn(status)
        // No confirmation: the switch moves at once and the change follows; if it fails, the switch goes back and says why. What a
        // switch changes and breaks is behind its (i).
        var action = Action(id: "toggle", title: title(control), parameters: ["id": control.id])
        if needsHelper(control) { action.requires = [.privilegedHelper] }
        // The switch shows the protection, named as such: "Disable <feature>" on = MacSpace switched the feature off.
        return ToggleRow(id: control.id, title: title(control), isOn: on, isEnabled: !blocked,
                         badge: badge(control, status, cannotTakeEffect: snapshot.cannotTakeEffect.contains(control.id)),
                         detail: detail(control, status), action: action)
    }

    // MARK: Screens

    static func counts(_ snapshot: DebloatSnapshot) -> (on: Int, total: Int, awaiting: [DebloatControl], drifted: [DebloatControl]) {
        let usable = snapshot.controls.filter { snapshot.status($0.id)?.state != .unavailable && !snapshot.cannotTakeEffect.contains($0.id) }
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
            guard let status = snapshot.status(control.id), !snapshot.cannotTakeEffect.contains(control.id) else { return false }
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
            .filter { snapshot.status($0.id)?.state != .unavailable && !snapshot.cannotTakeEffect.contains($0.id) }
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
        fix(snapshot) ?? switchOffRecommended(snapshot) ?? turnAllBackOn(snapshot)
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
