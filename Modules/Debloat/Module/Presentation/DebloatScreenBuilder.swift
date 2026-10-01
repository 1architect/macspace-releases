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

    static func badge(_ control: DebloatControl, _ status: ControlStatus?, cannotTakeEffect: Bool) -> Badge? {
        guard let status else { return nil }
        if cannotTakeEffect { return Badge("Cannot take effect here", tone: .critical) }
        switch status.state {
        case .debloated:
            switch status.effect?.state {
            case .effective?: return Badge("Verified working", tone: .positive)
            case .ineffective?: return Badge("Not working", tone: .critical)
            case .pending?: return Badge("After restart", tone: .caution)
            case .notControllable?: return Badge("Cannot take effect here", tone: .critical)
            default: return Badge("On", tone: .positive)
            }
        case .awaitingApproval: return Badge("Waiting for approval", tone: .caution)
        case .drifted: return Badge("Undone by macOS", tone: .critical)
        case .partial: return Badge("Partly on", tone: .caution)
        case .unavailable: return Badge("Not on this macOS")
        case .unknown: return Badge("Cannot read")
        case .stock: return status.validatedOnThisBuild ? Badge("Recommended", tone: .accent) : Badge("Not verified on this macOS")
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
        var lines: [String] = []
        if !control.breaks.isEmpty { lines.append("Stops working while this is on: " + control.breaks.joined(separator: "; ") + ".") }
        if let restart = restartText(control.restart) { lines.append(restart) }
        if let effect = status?.effect?.detail, !effect.isEmpty { lines.append(effect) }
        lines.append(contentsOf: control.notes)
        return lines.joined(separator: "\n")
    }

    static func confirmation(_ control: DebloatControl, turningOn: Bool, verified: Bool) -> Confirmation {
        if !turningOn {
            return Confirmation(title: "Turn off \(control.title)?", message: "MACSPACE restores the values it saved before it changed them.", confirmTitle: "Turn off")
        }
        var message = control.summary
        if !control.breaks.isEmpty { message += "\n\nStops working: " + control.breaks.joined(separator: "; ") + "." }
        if let restart = restartText(control.restart) { message += "\n\n" + restart }
        if control.mechanism == .configurationProfile { message += "\n\nmacOS asks you to approve the MACSPACE profile in System Settings before this takes effect." }
        if !verified { message += "\n\nThis was not verified on your macOS version; it may have no effect." }
        return Confirmation(title: "Turn on \(control.title)?", message: message, confirmTitle: "Turn on")
    }

    static func row(_ control: DebloatControl, _ snapshot: DebloatSnapshot) -> ToggleRow {
        let status = snapshot.status(control.id)
        let blocked = snapshot.cannotTakeEffect.contains(control.id) || status?.state == .unavailable
        let on = isOn(status)
        let verified = status?.validatedOnThisBuild ?? false
        var action = Action(id: "toggle", title: control.title, parameters: ["id": control.id, "unverified": verified ? "false" : "true"],
                            confirmation: confirmation(control, turningOn: !on, verified: verified))
        if needsHelper(control) { action.requires = [.privilegedHelper] }
        return ToggleRow(id: control.id, title: control.title, subtitle: control.summary, isOn: on, isEnabled: !blocked,
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

    static func summary(_ snapshot: DebloatSnapshot) -> ScreenWidget {
        let counts = counts(snapshot)
        if !counts.drifted.isEmpty {
            return .banner(Banner(id: "summary", severity: .warning, title: "\(counts.drifted.count) protection(s) were undone",
                                  message: counts.drifted.map(\.title).joined(separator: ", ")))
        }
        if !counts.awaiting.isEmpty {
            return .banner(Banner(id: "summary", severity: .warning, title: "\(counts.awaiting.count) waiting for your approval",
                                  message: "Approve the MACSPACE profile in System Settings > General > Device Management."))
        }
        return .banner(Banner(id: "summary", severity: counts.on > 0 ? .success : .info, title: "\(counts.on) of \(counts.total) protections are on",
                              message: counts.on == counts.total ? "Everything available is on." : "\(recommended(snapshot).count) more are verified on your macOS."))
    }

    static func screen(_ snapshot: DebloatSnapshot) -> Screen {
        let counts = counts(snapshot)
        var widgets: [ScreenWidget] = []
        if !counts.awaiting.isEmpty {
            widgets.append(.banner(Banner(id: "approval", severity: .warning, title: "Approve the MACSPACE profile",
                                          message: "\(counts.awaiting.map(\.title).joined(separator: ", ")) take effect once you approve it in System Settings > General > Device Management.",
                                          action: Action(id: "openProfiles", title: "Open System Settings", role: .prominent))))
        }
        if !counts.drifted.isEmpty {
            widgets.append(.banner(Banner(id: "drifted", severity: .warning, title: "\(counts.drifted.count) protection(s) were undone",
                                          message: "macOS or an update changed them back: \(counts.drifted.map(\.title).joined(separator: ", ")).",
                                          action: Action(id: "reapply", title: "Re-apply", role: .prominent, parameters: ["ids": counts.drifted.map(\.id).joined(separator: ",")],
                                                         requires: [.privilegedHelper]))))
        }
        let recommended = recommended(snapshot)
        if !recommended.isEmpty {
            widgets.append(.button(ButtonWidget(id: "recommended", action: Action(
                id: "applyRecommended", title: "Turn on the \(recommended.count) verified protections", symbol: "checkmark.shield", role: .prominent,
                parameters: ["ids": recommended.map(\.id).joined(separator: ",")],
                confirmation: Confirmation(title: "Turn on the verified protections?",
                                           message: recommended.map { "• \($0.title)" }.joined(separator: "\n") + "\n\nEach one was measured to work on this macOS version. Some features they switch off are listed on each row.",
                                           confirmTitle: "Turn on"),
                requires: [.privilegedHelper]),
                footnote: "Everything MACSPACE changes is written to an undo journal, so you can turn any of it off again.")))
        }
        for category in categoryOrder {
            let controls = snapshot.controls.filter { $0.category == category }
            guard !controls.isEmpty else { continue }
            widgets.append(.toggles(ToggleList(id: "cat:\(category.rawValue)", title: title(category), rows: controls.map { row($0, snapshot) })))
        }
        let env = snapshot.environment
        widgets.append(.text(TextWidget(id: "env", text: "macOS \(env.productVersion ?? "?") (\(env.build ?? "?")). Protections marked verified were measured on this build; others follow Apple's documented settings but their effect is not measured here.", style: .caption)))
        return Screen(title: "Debloat", subtitle: "Turn off analytics, ads and background data collection macOS lets you control.", widgets: widgets)
    }
}
