import Foundation
import MacSpaceDebloatPrivileged
import MacSpaceSdk

enum DebloatScreenBuilder {
    static let categoryOrder: [ControlCategory] = [.telemetry, .advertising, .siri, .appleIntelligence, .suggestions, .appServices, .diagnostics]

    static func title(_ category: ControlCategory) -> String {
        switch category {
        case .telemetry: return "Analytics and telemetry"
        case .advertising: return "Advertising"
        case .siri: return "Siri"
        case .appleIntelligence: return "Apple Intelligence features"
        case .suggestions: return "Suggestions and search"
        case .experiments: return "Experiments"
        case .backgroundAnalysis: return "Background analysis"
        case .appServices: return "Apps"
        case .diagnostics: return "Diagnostics"
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
        if cannotTakeEffect { return Badge("Cannot take effect here", tone: .critical) }
        switch status.state {
        case .debloated:
            switch status.effect?.state {
            case .ineffective?: return Badge("Not working", tone: .critical)
            case .pending?: return Badge("After restart", tone: .caution)
            case .notControllable?: return Badge("Cannot take effect here", tone: .critical)
            // Switched off but never tested: says so, so it gets tested, also once it is off.
            default: return control.tested ? nil : Badge("Not tested", tone: .caution)
            }
        case .awaitingApproval: return Badge("Waiting for approval", tone: .caution)
        case .awaitingRemoval: return Badge("Profile still installed", tone: .caution)
        case .drifted: return Badge("Undone by macOS", tone: .critical)
        case .partial: return Badge("Partly off", tone: .caution)
        case .unavailable: return Badge("Not on this macOS")
        case .unknown: return Badge("Cannot read")
        case .stock: return status.tested ? nil : Badge("Not tested", tone: .caution)
        }
    }

    static func restartText(_ restart: RestartRequirement) -> String? {
        switch restart {
        case .none: return nil
        case .appRelaunch: return "Apps need to be reopened for this to take effect."
        case .logout: return "Log out and back in for this to take effect."
        case .reboot: return "Restart the Mac for this to take effect."
        }
    }

    static func detail(_ control: DebloatControl, _ status: ControlStatus?) -> String {
        var lines: [String] = [control.summary]
        if status?.effect?.state == .effective { lines.append("Measured off on this Mac.") }
        if !control.tested { lines.append("Not tested yet: after switching it off, check that it took effect.") }
        if !control.breaks.isEmpty { lines.append("Stops working while this is off: " + control.breaks.joined(separator: "; ") + ".") }
        if let restart = restartText(control.restart) { lines.append(restart) }
        if let effect = status?.effect?.detail, !effect.isEmpty { lines.append(effect) }
        lines.append(contentsOf: control.notes)
        return lines.joined(separator: "\n")
    }

    static func row(_ control: DebloatControl, _ snapshot: DebloatSnapshot) -> ToggleRow {
        let status = snapshot.status(control.id)
        let blocked = snapshot.cannotTakeEffect.contains(control.id) || status?.state == .unavailable
        let on = isOn(status)
        // No confirmation: the switch moves at once and the change follows; if it fails, the switch goes back and says why. What a
        // switch changes and breaks is in its tooltip.
        var action = Action(id: "toggle", title: control.title, parameters: ["id": control.id])
        if needsHelper(control) { action.requires = [.privilegedHelper] }
        // The switch shows the feature, as in the other modules: on = the feature runs, off = MacSpace switched it off.
        return ToggleRow(id: control.id, title: control.title, isOn: !on, isEnabled: !blocked,
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
        if !counts.drifted.isEmpty { return Tile(title: "debloat", status: "\(counts.drifted.count) undone by macOS", needsAttention: true, graphic: graphic) }
        if !counts.awaiting.isEmpty { return Tile(title: "debloat", status: "\(counts.awaiting.count) awaiting approval", needsAttention: true, graphic: graphic) }
        return Tile(title: "debloat", status: "\(counts.on)/\(counts.total) switched off", graphic: graphic)
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
        switchOffRecommended(snapshot) ?? turnAllBackOn(snapshot)
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
        return Action(id: "restoreAll", title: "Turn all back on", symbol: "arrow.uturn.backward", role: .prominent,
                      parameters: ["ids": controls.map(\.id).joined(separator: ",")],
                      confirmation: Confirmation(title: "Turn all \(controls.count) features back on?",
                                                 message: controls.map { "• \($0.title)" }.joined(separator: "\n") + "\n\nMacSpace restores the values it saved before it changed them.",
                                                 confirmTitle: "Turn on"),
                      requires: controls.contains(where: needsHelper) ? [.privilegedHelper] : [])
    }

    /// Switches off every feature that is still on. nil when there is none.
    static func switchOffRecommended(_ snapshot: DebloatSnapshot) -> Action? {
        let recommended = recommended(snapshot)
        guard !recommended.isEmpty else { return nil }
        let untested = recommended.filter { !$0.tested }
        let policies = recommended.filter(isPolicy)
        var message = recommended.map { "• \($0.title)\($0.tested ? "" : " (not tested yet)")" }.joined(separator: "\n")
        if !policies.isEmpty {
            message += "\n\nmacOS asks you to approve the profile of each policy (\(policies.map(\.title).joined(separator: ", "))) once, in System Settings > General > Device Management."
        }
        if !untested.isEmpty { message += "\n\nCheck afterwards that the ones not tested yet took effect." }
        message += "\n\nEverything is written to an undo journal, so you can turn any of it back on."
        return Action(id: "applyRecommended", title: "Switch all off", symbol: "checkmark.shield", role: .prominent,
                      parameters: ["ids": recommended.map(\.id).joined(separator: ",")],
                      confirmation: Confirmation(title: "Switch off \(recommended.count) features?", message: message, confirmTitle: "Switch off"),
                      requires: [.privilegedHelper])
    }

    static func screen(_ snapshot: DebloatSnapshot) -> Screen {
        let counts = counts(snapshot)
        var widgets: [ScreenWidget] = []
        // Waiting for approval: one profile holds them all, opened again on demand (macOS drops a downloaded profile after a while,
        // and keeps only the latest one).
        let approving = counts.awaiting.filter { snapshot.status($0.id)?.state == .awaitingApproval }
        if !approving.isEmpty {
            widgets.append(.banner(Banner(id: "approval", severity: .warning, title: "Approve the MacSpace profile",
                                          message: "\(approving.map(\.title).joined(separator: ", ")) switch off once you approve one profile in System Settings > General > Device Management.",
                                          action: Action(id: "approvePending", title: "Show the profile", role: .prominent))))
        }
        // Switched back on while macOS still enforces their profile: the helper removes it, with nothing to approve.
        let removing = counts.awaiting.filter { snapshot.status($0.id)?.state == .awaitingRemoval }
        if !removing.isEmpty {
            widgets.append(.banner(Banner(id: "removal", severity: .warning, title: "Finish switching back on",
                                          message: "macOS still enforces the profile of \(removing.map(\.title).joined(separator: ", ")). MacSpace removes it; there is nothing to approve.",
                                          action: Action(id: "removePending", title: "Remove the profile", role: .prominent,
                                                         parameters: ["ids": removing.map(\.id).joined(separator: ",")], requires: [.privilegedHelper]))))
        }
        if !counts.drifted.isEmpty {
            widgets.append(.banner(Banner(id: "drifted", severity: .warning, title: "\(counts.drifted.count) feature(s) switched back on by macOS",
                                          message: "macOS or an update turned them back on: \(counts.drifted.map(\.title).joined(separator: ", ")).",
                                          action: Action(id: "reapply", title: "Re-apply", role: .prominent, parameters: ["ids": counts.drifted.map(\.id).joined(separator: ",")],
                                                         requires: [.privilegedHelper]))))
        }
        for category in categoryOrder {
            let controls = snapshot.controls.filter { $0.category == category && !isPolicy($0) }
            guard !controls.isEmpty else { continue }
            widgets.append(.toggles(ToggleList(id: "cat:\(category.rawValue)", title: title(category),
                                               footnote: "A switch shows whether the feature runs. Hover a row for what it changes.",
                                               rows: controls.map { row($0, snapshot) })))
        }
        // Apart, and last: these need a profile, which macOS asks the user to approve.
        let policies = categoryOrder.flatMap { category in snapshot.controls.filter { $0.category == category && isPolicy($0) } }
        if !policies.isEmpty {
            widgets.append(.toggles(ToggleList(id: "policies", title: "Policies (need your approval)",
                                               footnote: "macOS only applies these through a configuration profile. Switching one off asks you to approve its profile once in System Settings > General > Device Management; switching it back on asks nothing.",
                                               rows: policies.map { row($0, snapshot) })))
        }
        return Screen(title: "Debloat", primary: primary(snapshot), widgets: widgets)
    }
}
