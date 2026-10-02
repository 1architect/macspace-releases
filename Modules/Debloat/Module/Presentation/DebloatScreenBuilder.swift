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
            default: return nil
            }
        case .awaitingApproval: return Badge("Waiting for approval", tone: .caution)
        case .drifted: return Badge("Undone by macOS", tone: .critical)
        case .partial: return Badge("Partly off", tone: .caution)
        case .unavailable: return Badge("Not on this macOS")
        case .unknown: return Badge("Cannot read")
        case .stock: return status.validatedOnThisBuild ? nil : Badge("Unverified")
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
        if status?.state == .stock && status?.validatedOnThisBuild == false { lines.append("Not verified on this macOS version; it may have no effect.") }
        if !control.breaks.isEmpty { lines.append("Stops working while this is off: " + control.breaks.joined(separator: "; ") + ".") }
        if let restart = restartText(control.restart) { lines.append(restart) }
        if let effect = status?.effect?.detail, !effect.isEmpty { lines.append(effect) }
        lines.append(contentsOf: control.notes)
        return lines.joined(separator: "\n")
    }

    static func confirmation(_ control: DebloatControl, turningOn: Bool, verified: Bool) -> Confirmation {
        if !turningOn {
            return Confirmation(title: "Turn \(control.title) back on?", message: "MacSpace restores the values it saved before it changed them.", confirmTitle: "Turn on")
        }
        var message = control.summary
        if !control.breaks.isEmpty { message += "\n\nStops working while off: " + control.breaks.joined(separator: "; ") + "." }
        if let restart = restartText(control.restart) { message += "\n\n" + restart }
        if control.mechanism == .configurationProfile { message += "\n\nmacOS asks you to approve the MacSpace profile in System Settings before this takes effect." }
        if !verified { message += "\n\nThis was not verified on your macOS version; it may have no effect." }
        return Confirmation(title: "Turn off \(control.title)?", message: message, confirmTitle: "Turn off")
    }

    static func row(_ control: DebloatControl, _ snapshot: DebloatSnapshot) -> ToggleRow {
        let status = snapshot.status(control.id)
        let blocked = snapshot.cannotTakeEffect.contains(control.id) || status?.state == .unavailable
        let on = isOn(status)
        let verified = status?.validatedOnThisBuild ?? false
        var action = Action(id: "toggle", title: control.title, parameters: ["id": control.id, "unverified": verified ? "false" : "true"],
                            confirmation: confirmation(control, turningOn: !on, verified: verified))
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
        let awaiting = usable.filter { snapshot.status($0.id)?.state == .awaitingApproval }
        let drifted = usable.filter { snapshot.status($0.id)?.state == .drifted }
        return (on, usable.count, awaiting, drifted)
    }

    /// Controls verified on this macOS build that are not on yet.
    static func recommended(_ snapshot: DebloatSnapshot) -> [DebloatControl] {
        snapshot.controls.filter { control in
            guard let status = snapshot.status(control.id), status.validatedOnThisBuild, !snapshot.cannotTakeEffect.contains(control.id) else { return false }
            return status.state == .stock || status.state == .partial
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

    /// Switches off every feature verified on this macOS build that is still on. nil when there is none.
    static func switchOffRecommended(_ snapshot: DebloatSnapshot) -> Action? {
        let recommended = recommended(snapshot)
        guard !recommended.isEmpty else { return nil }
        return Action(id: "applyRecommended", title: "Switch off \(recommended.count) verified", symbol: "checkmark.shield", role: .prominent,
                      parameters: ["ids": recommended.map(\.id).joined(separator: ",")],
                      confirmation: Confirmation(title: "Switch off the verified features?",
                                                 message: recommended.map { "• \($0.title)" }.joined(separator: "\n") + "\n\nEach one was measured to work on this macOS version. Everything is written to an undo journal, so you can turn any of it back on.",
                                                 confirmTitle: "Switch off"),
                      requires: [.privilegedHelper])
    }

    static func screen(_ snapshot: DebloatSnapshot) -> Screen {
        let counts = counts(snapshot)
        var widgets: [ScreenWidget] = []
        if !counts.awaiting.isEmpty {
            widgets.append(.banner(Banner(id: "approval", severity: .warning, title: "Approve the MacSpace profile",
                                          message: "\(counts.awaiting.map(\.title).joined(separator: ", ")) take effect once you approve it in System Settings > General > Device Management.",
                                          action: Action(id: "openProfiles", title: "Open System Settings", role: .prominent))))
        }
        if !counts.drifted.isEmpty {
            widgets.append(.banner(Banner(id: "drifted", severity: .warning, title: "\(counts.drifted.count) feature(s) switched back on by macOS",
                                          message: "macOS or an update turned them back on: \(counts.drifted.map(\.title).joined(separator: ", ")).",
                                          action: Action(id: "reapply", title: "Re-apply", role: .prominent, parameters: ["ids": counts.drifted.map(\.id).joined(separator: ",")],
                                                         requires: [.privilegedHelper]))))
        }
        for category in categoryOrder {
            let controls = snapshot.controls.filter { $0.category == category }
            guard !controls.isEmpty else { continue }
            widgets.append(.toggles(ToggleList(id: "cat:\(category.rawValue)", title: title(category),
                                               footnote: "A switch shows whether the feature runs. Hover a row for what it changes.",
                                               rows: controls.map { row($0, snapshot) })))
        }
        return Screen(title: "Debloat", primary: switchOffRecommended(snapshot), widgets: widgets)
    }
}
