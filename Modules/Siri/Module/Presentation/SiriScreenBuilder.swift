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
        case .atRisk: return "On. " + modelLine(snapshot)
        case .unknown: return "MacSpace cannot read the state without Full Disk Access."
        }
    }

    /// What the models take while Apple Intelligence is on, downloads included. Never "none" when the folders could not be read.
    static func modelLine(_ snapshot: SiriSnapshot) -> String {
        let downloading = snapshot.downloadingModelBytes >= purgeThreshold ? snapshot.downloadingModelBytes : nil
        switch (snapshot.installedModelBytes, downloading) {
        case let (installed?, downloading?) where installed >= purgeThreshold:
            return "Its models take \(ByteFormat.string(installed)), and macOS is downloading \(ByteFormat.string(downloading)) more."
        case let (_, downloading?):
            return "macOS is downloading its models (\(ByteFormat.string(downloading)) so far)."
        case let (installed?, nil) where installed >= purgeThreshold:
            return "Its models take \(ByteFormat.string(installed)); switch it off to free them."
        case (nil, nil):
            return "Its models could not be measured (allow Full Disk Access)."
        default:
            return "No model is downloaded yet."
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

    /// The tile shows the switch itself, with no glow. What can be freed is said in the line under it, without a meter: the models
    /// macOS released and can purge, or, while Apple Intelligence is on, the models it has downloaded (freed by switching it off).
    static func tile(_ snapshot: SiriSnapshot) -> Tile {
        if snapshot.isVirtualMachine {
            return Tile(title: "siri & AI", status: "not in a virtual machine", graphic: .state(on: false, alarming: false, detail: "not available here", meter: nil, meterIsActionable: false))
        }
        let elsewhere = !(snapshot.accounts?.enabledElsewhere ?? []).isEmpty
        let on = snapshot.status.state == .atRisk
        let purge = snapshot.purgeableAssetsBytes.flatMap { $0 >= purgeThreshold ? $0 : nil }
        // Downloads count too: they take the space as they arrive and are freed the same way.
        let onDisk = (snapshot.installedModelBytes ?? 0) + snapshot.downloadingModelBytes
        let installed = on && onDisk >= purgeThreshold ? onDisk : nil
        let detail: String
        if let purge { detail = snapshot.assetsRetrying ? "freeing \(ByteFormat.string(purge)) of models" : "up to \(ByteFormat.string(purge)) of models can be freed" }
        else if on, snapshot.downloadingModelBytes >= purgeThreshold { detail = "downloading models: \(ByteFormat.string(onDisk)) so far" }
        else if let installed { detail = "\(ByteFormat.string(installed)) of models; switch it off to free them" }
        else if on { detail = snapshot.installedModelBytes == nil ? "models not measured" : "no model downloaded yet" }
        else if snapshot.status.state == .unknown { detail = "needs Full Disk Access to read" }
        else { detail = "no models left on disk" }
        // No meter: what is left to purge is said in the detail line.
        let graphic = TileGraphic.state(on: on, alarming: false, detail: detail, meter: nil, meterIsActionable: false)
        if let freeable = purge ?? installed {
            return Tile(title: "siri & AI", status: "up to \(ByteFormat.string(freeable)) can be freed", needsAttention: installed != nil, graphic: graphic,
                        reclaimableBytes: freeable, purgeableByService: [CacheDeleteService.mobileAsset: snapshot.purgeableAssetsBytes ?? 0])
        }
        switch snapshot.status.state {
        case .protected: return Tile(title: "siri & AI", status: elsewhere ? "on in another account" : "AI is off", needsAttention: elsewhere, graphic: graphic)
        case .releasing: return Tile(title: "siri & AI", status: "removing the model", graphic: graphic)
        case .atRisk: return Tile(title: "siri & AI", status: "AI is on", needsAttention: true, graphic: graphic)
        case .unknown: return Tile(title: "siri & AI", status: "state unknown", graphic: graphic)
        }
    }

    static let purgeThreshold: UInt64 = 50_000_000

    /// Where the Siri language goes: only this Mac while Siri's iCloud sync is off (MacSpace turns it off before changing the
    /// language), also iPhone and iPad while the user keeps it on.
    static func languageReach(_ snapshot: SiriSnapshot) -> String {
        snapshot.keepsCloudSync
            ? AppleIntelligenceLanguageGuard.iCloudSyncWarning
            : "MacSpace turns Siri's iCloud sync off before it changes the Siri language, so iPhone and iPad keep theirs."
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
        // No button while MacSpace is already asking macOS again in the background.
        guard let bytes = snapshot.purgeableAssetsBytes, bytes >= purgeThreshold, !snapshot.assetsRetrying else { return nil }
        return Action(id: "purgeAssets", title: "Free up to \(ByteFormat.string(bytes))", symbol: "sparkles", role: .prominent,
                      confirmation: Confirmation(title: "Free up to \(ByteFormat.string(bytes))?", message: "macOS deletes the downloads it no longer needs, including Apple Intelligence models it has released. \(ByteFormat.string(bytes)) is macOS's estimate: MacSpace asks it again just before and reports what the disk actually gained. Anything needed again is downloaded again.", confirmTitle: "Free"))
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
        let state = snapshot.status.state
        let detail = ([subtitle, "Applies to this account.", languageReach(snapshot)] + snapshot.status.reasons).joined(separator: " ")
        // No confirmation: the switch moves at once and the change follows; if it fails, the switch goes back and says why.
        var rows = [ToggleRow(id: "ai", title: "Apple Intelligence", subtitle: enabled ? stateLine(snapshot) : subtitle, isOn: available, isEnabled: enabled,
                              badge: state == .atRisk ? Badge("On", tone: .caution) : nil,
                              detail: detail,
                              action: Action(id: "toggle", title: "Apple Intelligence", parameters: ["id": "ai"], requires: [.fullDiskAccess]))]
        if let sync = snapshot.cloudSyncOn {
            rows.append(ToggleRow(id: "icloud-sync", title: "Sync Siri with iCloud", subtitle: sync ? "On: iPhone and iPad get the same Siri settings." : "Off: Siri's settings stay on this Mac.",
                                  isOn: sync, badge: SiriCloudSync.tested ? nil : Badge("Not tested", tone: .caution),
                                  detail: "The Siri switch under System Settings > Apple Account > iCloud > Saved to iCloud. MacSpace switches it off before it changes the Siri language, so iPhone and iPad keep theirs; switch it on here to keep Siri in sync, and MacSpace leaves it on.",
                                  action: Action(id: "cloudSync", title: "Sync Siri with iCloud", parameters: ["id": "icloud-sync"])))
        }
        return ToggleList(id: "switch", rows: rows)
    }

    static func accountsSection(_ snapshot: SiriSnapshot) -> ScreenWidget? {
        guard let elsewhere = snapshot.accounts?.enabledElsewhere, !elsewhere.isEmpty else { return nil }
        let rows = elsewhere.map { account -> Row in
            let steps: [String] = account.name.map { name in
                ["Log in as \(name) and switch Apple Intelligence off there (this page, or System Settings > Apple Intelligence & Siri).",
                 "If \(name) is not needed, delete the account in System Settings > Users & Groups."]
            } ?? ["The account no longer exists, but macOS keeps its subscriptions and a restart does not clear them.",
                  "Remove them as an administrator (Terminal): sudo \"\(snapshot.cliPath)\" orphan-subscriptions --execute",
                  "Restart the Mac; MacSpace then releases and deletes the leftover models by itself."]
            return Row(id: "account:\(account.guid)", title: account.label, subtitle: "\(account.useCases.count) Apple Intelligence feature(s) subscribed",
                       badge: Badge("Keeps the models", tone: .caution), symbol: "person.crop.circle.badge.exclamationmark", steps: steps)
        }
        return .section(SectionWidget(id: "accounts", title: "Other accounts",
                                      subtitle: "The models are stored once for the whole Mac. One account with Apple Intelligence on keeps them installed for everyone.",
                                      widgets: [.list(ListWidget(id: "accounts-list", rows: rows))]))
    }

    /// While macOS is still removing the model after the switch went off. MacSpace releases models that stay by itself
    /// (`ModelAutoRelease`); this only says so, or what keeps it from doing it.
    static func modelsSection(_ snapshot: SiriSnapshot) -> ScreenWidget? {
        guard snapshot.status.state == .releasing || snapshot.releasingAutomatically else { return nil }
        let widget: ScreenWidget
        if snapshot.releasingAutomatically {
            widget = .list(ListWidget(id: "models-list", rows: [
                Row(id: "releasing", title: "Releasing the leftover models", symbol: "arrow.triangle.2.circlepath",
                    detail: "For about a minute Apple Intelligence is available and Siri's language changes; both are restored afterwards. Then the models are deleted. " + languageReach(snapshot)),
            ]))
        } else if !snapshot.releaseBlockers.isEmpty {
            widget = .steps(StepsWidget(id: "blockers", title: "Before MacSpace can release them", steps: snapshot.releaseBlockers))
        } else {
            let minutes = Int(ModelAutoRelease.settleTime / 60)
            widget = .list(ListWidget(id: "models-list", rows: [
                Row(id: "releasing", title: "macOS is removing the model", symbol: "arrow.triangle.2.circlepath",
                    detail: "This usually takes a few minutes. If the models are still here after \(minutes) minutes, MacSpace releases and deletes them by itself."),
            ]))
        }
        return .section(SectionWidget(id: "models", title: "Leftover models", widgets: [widget]))
    }
}
