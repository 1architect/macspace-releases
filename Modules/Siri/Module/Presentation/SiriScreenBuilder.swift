import Foundation
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceSiriPrivileged

enum SiriScreenBuilder {
    /// The switch is "on" while Apple Intelligence is available to this account.
    static func isAvailable(_ status: AppleIntelligenceGuardStatus) -> Bool? {
        switch status.state {
        case .atRisk: return true
        case .protected, .releasing: return false
        case .unknown: return status.languagesMatch
        }
    }

    /// What the state means, for the switch's subtitle.
    static func stateLine(_ snapshot: SiriSnapshot) -> String {
        switch snapshot.status.state {
        case .protected: return "Off. Its model is not installed."
        case .releasing: return "Off. macOS is removing its model, which usually takes a few minutes."
        case .atRisk: return "On. macOS may download its model (about 12 GB)."
        case .unknown: return "MacSpace cannot read the state without Full Disk Access."
        }
    }

    /// A banner only when the user has something to do.
    static func statusBanner(_ snapshot: SiriSnapshot) -> Banner? {
        let elsewhere = snapshot.accounts?.enabledElsewhere ?? []
        switch snapshot.status.state {
        case .protected where !elsewhere.isEmpty:
            return Banner(id: "status", severity: .warning, title: "Still installed for another account",
                          message: "Apple Intelligence is on in \(elsewhere.map(\.label).joined(separator: ", ")). Its models are shared, so they stay on this Mac.")
        case .unknown:
            return Banner(id: "status", severity: .info, title: "Allow Full Disk Access",
                          message: "MacSpace needs it to read and verify the switch.",
                          action: Action(id: "openFullDiskAccess", title: "Allow", role: .prominent))
        default:
            return nil
        }
    }

    /// macOS does not offer Apple Intelligence in a virtual machine, so there is nothing to switch off or release there.
    static func virtualMachineBanner() -> Banner {
        Banner(id: "status", severity: .info, title: "This is a virtual machine",
               message: "macOS does not offer Apple Intelligence in a virtual machine, so there is nothing to switch off or release here. Use MacSpace on the real Mac.")
    }

    /// The tile shows the switch itself: off and quiet while Apple Intelligence stays off, glowing while it is on. What can be purged
    /// is the meter, against the ~12 GB the on-device model takes.
    static func tile(_ snapshot: SiriSnapshot) -> Tile {
        if snapshot.isVirtualMachine {
            return Tile(title: "siri & AI", status: "not in a virtual machine", graphic: .state(on: false, alarming: false, detail: "not available here", meter: nil, meterIsActionable: false))
        }
        let elsewhere = !(snapshot.accounts?.enabledElsewhere ?? []).isEmpty
        let purge = snapshot.purgeableAssetsBytes.flatMap { $0 >= purgeThreshold ? $0 : nil }
        let on = snapshot.status.state == .atRisk
        let detail: String
        if let purge { detail = "\(ByteFormat.string(purge)) of models can be purged" }
        else if on { detail = "macOS may download its model (about 12 GB)" }
        else if snapshot.status.state == .unknown { detail = "needs Full Disk Access to read" }
        else { detail = "no models left on disk" }
        let graphic = TileGraphic.state(on: on, alarming: on, detail: detail, meter: purge.map { min(Double($0) / 12_000_000_000, 1) },
                                        meterIsActionable: purge != nil)
        if let purge { return Tile(title: "siri & AI", status: "\(ByteFormat.string(purge)) to purge", graphic: graphic) }
        switch snapshot.status.state {
        case .protected: return Tile(title: "siri & AI", status: elsewhere ? "on in another account" : "AI is off", needsAttention: elsewhere, graphic: graphic)
        case .releasing: return Tile(title: "siri & AI", status: "removing the model", graphic: graphic)
        case .atRisk: return Tile(title: "siri & AI", status: "AI is on", needsAttention: true, graphic: graphic)
        case .unknown: return Tile(title: "siri & AI", status: "state unknown", graphic: graphic)
        }
    }

    static let purgeThreshold: UInt64 = 50_000_000

    static func disableConfirmation(_ snapshot: SiriSnapshot) -> Confirmation {
        var message = "Siri's language will differ from your system language, which makes Apple Intelligence unavailable. macOS then removes its model."
        if case let .success(plan) = snapshot.disablePlan {
            message = "Siri's language changes from \(plan.currentSiriLanguage ?? "?") to \(plan.targetSiriLanguage), which makes Apple Intelligence unavailable. "
                + plan.warnings.filter { !$0.hasPrefix("Whether this preference syncs") && !$0.hasPrefix("Apple Intelligence becomes unavailable") }.joined(separator: " ")
        }
        return Confirmation(title: "Switch Apple Intelligence off?", message: message, confirmTitle: "Switch off")
    }

    static func screen(_ snapshot: SiriSnapshot) -> Screen {
        if snapshot.isVirtualMachine {
            return Screen(title: "Siri & Apple Intelligence", widgets: [.banner(virtualMachineBanner())])
        }
        var widgets: [ScreenWidget] = []
        if let banner = statusBanner(snapshot) { widgets.append(.banner(banner)) }
        widgets.append(.toggles(switchList(snapshot)))
        if let accounts = accountsSection(snapshot) { widgets.append(accounts) }
        if let models = modelsSection(snapshot) { widgets.append(models) }
        return Screen(title: "Siri & Apple Intelligence", primary: purge(snapshot), widgets: widgets)
    }

    static func purge(_ snapshot: SiriSnapshot) -> Action? {
        guard let bytes = snapshot.purgeableAssetsBytes, bytes >= purgeThreshold else { return nil }
        return Action(id: "purgeAssets", title: "Purge \(ByteFormat.string(bytes))", symbol: "trash", role: .prominent,
                      confirmation: Confirmation(title: "Remove unused system assets?", message: "macOS deletes the downloads it no longer needs, about \(ByteFormat.string(bytes)), including Apple Intelligence models it has released. Anything needed again is downloaded again.", confirmTitle: "Remove"))
    }

    static func switchList(_ snapshot: SiriSnapshot) -> ToggleList {
        let available = isAvailable(snapshot.status) ?? false
        var subtitle = "Works by giving Siri a language different from your system language; Apple Intelligence then becomes unavailable."
        var enabled = true
        if snapshot.status.state == .protected || snapshot.status.state == .releasing {
            if case let .failure(failure) = snapshot.disablePlan, available { subtitle = failure.message; enabled = false }
        } else if snapshot.status.state == .atRisk, case let .failure(failure) = snapshot.disablePlan {
            subtitle = failure.message
            enabled = false
        }
        let confirmation: Confirmation? = available
            ? disableConfirmation(snapshot)
            : Confirmation(title: "Turn Apple Intelligence back on?", message: "Siri's language returns to your system language. macOS may download the on-device model (about 12 GB).", confirmTitle: "Turn on")
        let state = snapshot.status.state
        let detail = ([subtitle, "Applies to this account on this Mac. Whether the Siri language syncs through iCloud is unverified."] + snapshot.status.reasons).joined(separator: " ")
        return ToggleList(id: "switch", rows: [
            ToggleRow(id: "ai", title: "Apple Intelligence", subtitle: enabled ? stateLine(snapshot) : subtitle, isOn: available, isEnabled: enabled,
                      badge: state == .atRisk ? Badge("On", tone: .caution) : nil,
                      detail: detail,
                      action: Action(id: "toggle", title: "Apple Intelligence", parameters: ["id": "ai"], confirmation: confirmation, requires: [.fullDiskAccess])),
        ])
    }

    static func accountsSection(_ snapshot: SiriSnapshot) -> ScreenWidget? {
        guard let elsewhere = snapshot.accounts?.enabledElsewhere, !elsewhere.isEmpty else { return nil }
        let rows = elsewhere.map { account -> Row in
            let steps: [String] = account.name.map { name in
                ["Log in as \(name) and switch Apple Intelligence off there (this page, or System Settings > Apple Intelligence & Siri).",
                 "If \(name) is not needed, delete the account in System Settings > Users & Groups."]
            } ?? ["The account no longer exists, but macOS keeps its subscriptions and a restart does not clear them.",
                  "Remove them as an administrator (Terminal): sudo \"\(snapshot.cliPath)\" orphan-subscriptions --execute",
                  "Restart the Mac, then use \"Release and delete leftover models\" below."]
            return Row(id: "account:\(account.guid)", title: account.label, subtitle: "\(account.useCases.count) Apple Intelligence feature(s) subscribed",
                       badge: Badge("Keeps the models", tone: .caution), symbol: "person.crop.circle.badge.exclamationmark", steps: steps)
        }
        return .section(SectionWidget(id: "accounts", title: "Other accounts",
                                      subtitle: "The models are stored once for the whole Mac. One account with Apple Intelligence on keeps them installed for everyone.",
                                      widgets: [.list(ListWidget(id: "accounts-list", rows: rows))]))
    }

    /// For models that stay installed although Apple Intelligence is off. Only offered while it is off.
    static func modelsSection(_ snapshot: SiriSnapshot) -> ScreenWidget? {
        guard snapshot.status.state == .protected || snapshot.status.state == .releasing else { return nil }
        let widget: ScreenWidget
        if snapshot.releaseBlockers.isEmpty {
            widget = .button(ButtonWidget(id: "release", action: Action(
                id: "releaseModels", title: "Release leftover models", symbol: "arrow.triangle.2.circlepath",
                confirmation: Confirmation(title: "Release the models?", message: "For about a minute Apple Intelligence is briefly available and Siri's language changes; both are restored afterwards. Then macOS deletes the models it no longer needs.", confirmTitle: "Release"),
                requires: [.fullDiskAccess])))
        } else {
            widget = .steps(StepsWidget(id: "blockers", title: "Before the models can be released", steps: snapshot.releaseBlockers))
        }
        return .section(SectionWidget(id: "models", title: "Models still installed?", subtitle: "If macOS keeps them after the switch is off, release them, then Purge.",
                                      widgets: [widget], isCollapsible: true, startsCollapsed: true))
    }
}
