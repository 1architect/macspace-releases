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

    static func statusBanner(_ snapshot: SiriSnapshot) -> Banner {
        let elsewhere = snapshot.accounts?.enabledElsewhere ?? []
        switch snapshot.status.state {
        case .protected:
            if !elsewhere.isEmpty {
                return Banner(id: "status", severity: .warning, title: "Off here, but still installed",
                              message: "Apple Intelligence is on in \(elsewhere.map(\.label).joined(separator: ", ")). Its models are shared by every account, so they stay on this Mac.")
            }
            return Banner(id: "status", severity: .success, title: "Apple Intelligence is off", message: "It is unavailable in this account and its model is not installed.")
        case .releasing:
            return Banner(id: "status", severity: .info, title: "Apple Intelligence is off; macOS is removing its model",
                          message: "This usually takes a few minutes. Remove leftovers below if it lingers.")
        case .atRisk:
            return Banner(id: "status", severity: .warning, title: "Apple Intelligence is on",
                          message: "macOS may download its on-device model (about 12 GB). Switch it off below.")
        case .unknown:
            return Banner(id: "status", severity: .info, title: "Cannot read the Apple Intelligence state",
                          message: "Grant Full Disk Access in Settings so MacSpace can verify the switch.")
        }
    }

    /// macOS does not offer Apple Intelligence in a virtual machine, so there is nothing to switch off or release there.
    static func virtualMachineBanner() -> Banner {
        Banner(id: "status", severity: .info, title: "This is a virtual machine",
               message: "macOS does not offer Apple Intelligence in a virtual machine, so there is nothing to switch off or release here. Use MacSpace on the real Mac.")
    }

    static func summary(_ snapshot: SiriSnapshot) -> ScreenWidget {
        if snapshot.isVirtualMachine { return .banner(virtualMachineBanner()) }
        var banner = statusBanner(snapshot)
        if snapshot.status.state == .atRisk {
            banner.action = Action(id: "toggle", title: "Switch off", role: .prominent, parameters: ["id": "ai", "value": "false"],
                                   confirmation: disableConfirmation(snapshot), requires: [.fullDiskAccess])
        }
        return .banner(banner)
    }

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
            return Screen(title: "Siri & Apple Intelligence", subtitle: "Switch Apple Intelligence off and reclaim the space its models take.", widgets: [.banner(virtualMachineBanner())])
        }
        var widgets: [ScreenWidget] = [.banner(statusBanner(snapshot)), .toggles(switchList(snapshot))]
        if let accounts = accountsSection(snapshot) { widgets.append(accounts) }
        widgets.append(modelsSection(snapshot))
        if let watch = snapshot.watch {
            widgets.append(.text(TextWidget(id: "watch", text: "Last background check: \(watch.state.rawValue), \(watch.lastChecked.formatted(date: .abbreviated, time: .shortened)).", style: .caption)))
        }
        return Screen(title: "Siri & Apple Intelligence", subtitle: "Switch Apple Intelligence off and reclaim the space its models take.", widgets: widgets)
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
        return ToggleList(id: "switch", title: "Apple Intelligence", footnote: "Applies to this account on this Mac. Whether the Siri language syncs through iCloud is unverified.", rows: [
            ToggleRow(id: "ai", title: "Apple Intelligence", subtitle: subtitle, isOn: available, isEnabled: enabled,
                      badge: state == .protected ? Badge("Verified off", tone: .positive) : (state == .atRisk ? Badge("On", tone: .caution) : nil),
                      detail: snapshot.status.reasons.joined(separator: " "),
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

    static func modelsSection(_ snapshot: SiriSnapshot) -> ScreenWidget {
        var widgets: [ScreenWidget] = []
        if let bytes = snapshot.purgeableAssetsBytes, bytes >= 50_000_000 {
            widgets.append(.button(ButtonWidget(id: "purge", action: Action(
                id: "purgeAssets", title: "Remove unused assets (\(ByteFormat.string(bytes)))", symbol: "trash", role: .prominent,
                confirmation: Confirmation(title: "Remove unused system assets?", message: "macOS deletes the downloads it no longer needs, about \(ByteFormat.string(bytes)). Anything needed again is downloaded again.", confirmTitle: "Remove")),
                footnote: "Apple Intelligence models that macOS has released show up here.")))
        } else {
            widgets.append(.text(TextWidget(id: "no-purge", text: "No unused system assets are waiting to be deleted.", style: .caption)))
        }
        if snapshot.releaseBlockers.isEmpty {
            widgets.append(.button(ButtonWidget(id: "release", action: Action(
                id: "releaseModels", title: "Release and delete leftover models", symbol: "arrow.triangle.2.circlepath",
                confirmation: Confirmation(title: "Release the models?", message: "For about a minute Apple Intelligence is briefly available and Siri's language changes; both are restored afterwards. Then macOS deletes the models it no longer needs.", confirmTitle: "Release"),
                requires: [.fullDiskAccess]),
                footnote: "Use this when models stay installed although Apple Intelligence is off.")))
        } else {
            widgets.append(.steps(StepsWidget(id: "blockers", title: "Before the models can be released", steps: snapshot.releaseBlockers)))
        }
        return .section(SectionWidget(id: "models", title: "Leftover models", subtitle: "Space macOS keeps after Apple Intelligence is switched off.", widgets: widgets))
    }
}
