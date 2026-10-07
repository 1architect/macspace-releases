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
    /// The models are changing (downloading while on, being released or deleted): the app reads again every few seconds so the size
    /// follows what macOS does.
    static func refreshAfter(_ snapshot: SiriSnapshot) -> Double? {
        let changing = snapshot.status.state == .atRisk || snapshot.status.state == .releasing || snapshot.downloadingModelBytes > 0
            || snapshot.purgingModels || snapshot.releasingAutomatically || snapshot.assetsRetrying
        return changing ? 5 : nil
    }

    static func tile(_ snapshot: SiriSnapshot) -> Tile {
        var tile = baseTile(snapshot)
        tile.refreshAfter = refreshAfter(snapshot)
        // The tile's switch flips what the page's does, whenever the page's can be flipped.
        if !snapshot.isVirtualMachine, switchList(snapshot).rows.first?.isEnabled == true { tile.switchAction = switchAction }
        return tile
    }

    private static func baseTile(_ snapshot: SiriSnapshot) -> Tile {
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
        if let purge { detail = snapshot.assetsRetrying ? "freeing \(ByteFormat.string(purge)) of models" : "free up to \(ByteFormat.string(purge)) of models" }
        else if on, snapshot.downloadingModelBytes >= purgeThreshold { detail = "downloading models: \(ByteFormat.string(onDisk)) so far" }
        else if let installed { detail = "\(ByteFormat.string(installed)) of models; switch it off to free them" }
        else if on { detail = snapshot.installedModelBytes == nil ? "models not measured" : "no model downloaded yet" }
        // Off, models still on disk: released ones MacSpace is deleting, or a few macOS keeps for other features; their size, never
        // "none".
        // The state cannot be read: the size, without saying what happens to it.
        else if onDisk >= purgeThreshold, snapshot.status.state == .unknown { detail = "\(ByteFormat.string(onDisk)) of models on disk" }
        else if onDisk >= purgeThreshold {
            // What a purge deletes is what MobileAsset's records hold, less what is locked; the folders can hold more.
            let recorded = (snapshot.recordedModelBytes ?? 0) + snapshot.downloadingModelBytes
            let released = recorded > snapshot.lockedModelBytes ? recorded - snapshot.lockedModelBytes : 0
            if released >= purgeThreshold { detail = "deleting \(ByteFormat.string(released)) of models" }
            else { detail = "\(ByteFormat.string(onDisk)) of models kept by macOS" }
        }
        else if snapshot.status.state == .unknown { detail = "needs Full Disk Access to read" }
        else if snapshot.installedModelBytes == nil { detail = "models not measured" }
        else { detail = "no models left on disk" }
        // No meter: what is left to purge is said in the detail line.
        let graphic = TileGraphic.state(on: on, alarming: false, detail: detail, meter: nil, meterIsActionable: false)
        if let freeable = purge ?? installed {
            return Tile(title: "siri & AI", status: "free up to \(ByteFormat.string(freeable))", needsAttention: installed != nil, graphic: graphic,
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

    static func screen(_ snapshot: SiriSnapshot) -> Screen {
        if snapshot.isVirtualMachine {
            return Screen(title: "Siri & Apple Intelligence", widgets: [.banner(virtualMachineBanner())])
        }
        var widgets: [ScreenWidget] = []
        if let banner = statusBanner(snapshot) { widgets.append(.banner(banner)) }
        widgets.append(.toggles(switchList(snapshot)))
        widgets.append(.list(ListWidget(id: "icloud", rows: [cloudSyncRow(enabled: snapshot.cloudSyncEnabled)])))
        if let accounts = accountsSection(snapshot) { widgets.append(accounts) }
        if let models = modelsSection(snapshot) { widgets.append(models) }
        return Screen(title: "Siri & Apple Intelligence", primary: purge(snapshot), widgets: widgets)
    }

    static func purge(_ snapshot: SiriSnapshot) -> Action? {
        // No button while MacSpace is already asking macOS again in the background.
        guard let bytes = snapshot.purgeableAssetsBytes, bytes >= purgeThreshold, !snapshot.assetsRetrying else { return nil }
        return Action(id: "purgeAssets", title: "Free up to \(ByteFormat.string(bytes))", symbol: "sparkles", role: .prominent,
                      confirmation: Confirmation(title: "Free up to \(ByteFormat.string(bytes))?", message: "Deletes Apple Intelligence models and other downloads macOS no longer needs.", confirmTitle: "Free"))
    }

    static func switchList(_ snapshot: SiriSnapshot) -> ToggleList {
        let available = isAvailable(snapshot.status) ?? false
        var subtitle = "Switching it off sets Siri to a different language than your Mac."
        var enabled = true
        if snapshot.status.state == .protected || snapshot.status.state == .releasing {
            if case let .failure(failure) = snapshot.disablePlan, available { subtitle = failure.message; enabled = false }
        } else if snapshot.status.state == .atRisk, case let .failure(failure) = snapshot.disablePlan {
            subtitle = failure.message
            enabled = false
        }
        let detail = subtitle + (snapshot.cloudSyncEnabled == false ? "" : " With Siri's iCloud sync on, this also changes Siri on your iPhone and iPad.")
        // No confirmation: the switch moves at once and the change follows; if it fails, the switch goes back and says why.
        let rows = [ToggleRow(id: "ai", title: "Apple Intelligence", isOn: available, isEnabled: enabled,
                              detail: detail,
                              action: switchAction)]
        return ToggleList(id: "switch", rows: rows)
    }

    /// Switches Apple Intelligence, from the page's switch row and the tile's switch alike.
    static let switchAction = Action(id: "toggle", title: "Apple Intelligence", parameters: ["id": "ai"], requires: [.fullDiskAccess])

    /// Siri's iCloud sync, which only the user can turn off: whether it is on now, in the title (when it can be read), what it does,
    /// the steps while it is on, and a button to the page that has it.
    static func cloudSyncRow(enabled: Bool?) -> Row {
        let title: String
        switch enabled {
        case true?: title = "Siri's iCloud sync is currently on"
        case false?: title = "Siri's iCloud sync is currently off"
        case nil: title = "Siri's iCloud sync"
        }
        return Row(id: "icloud-sync", title: title,
                   symbol: enabled == false ? "checkmark.icloud" : "icloud",
                   detail: enabled == false ? nil : "Turn it off to keep Siri's language change on this Mac.", steps: enabled == false ? [] : SiriCloudSync.steps,
                   actions: [Action(id: "openICloudSettings", title: "Open")])
    }

    static func accountsSection(_ snapshot: SiriSnapshot) -> ScreenWidget? {
        guard let elsewhere = snapshot.accounts?.enabledElsewhere, !elsewhere.isEmpty else { return nil }
        let rows = elsewhere.map { account -> Row in
            let steps: [String] = account.name.map { name in
                ["Log in as \(name) and turn Apple Intelligence off there.",
                 "Or delete the account in System Settings > Users & Groups."]
            } ?? ["This account was deleted, but macOS still keeps its models. In Terminal, run:",
                  "sudo \"\(snapshot.cliPath)\" orphan-subscriptions --execute",
                  "Restart. MacSpace then deletes the models."]
            return Row(id: "account:\(account.guid)", title: account.label, subtitle: account.useCases.count == 1 ? "1 feature" : "\(account.useCases.count) features",
                       badge: Badge("Keeps the models", tone: .caution), symbol: "person.crop.circle.badge.exclamationmark", steps: steps)
        }
        return .section(SectionWidget(id: "accounts", title: "Other accounts",
                                      subtitle: "One account with Apple Intelligence on keeps the models on this Mac.",
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
                    detail: "Takes about a minute."),
            ]))
        } else if !snapshot.releaseBlockers.isEmpty {
            widget = .steps(StepsWidget(id: "blockers", title: "Before MacSpace can release them", steps: snapshot.releaseBlockers))
        } else {
            let minutes = Int(ModelAutoRelease.settleTime / 60)
            widget = .list(ListWidget(id: "models-list", rows: [
                Row(id: "releasing", title: "macOS is removing the model", symbol: "arrow.triangle.2.circlepath",
                    detail: "Usually takes a few minutes. If it doesn't, MacSpace does it after \(minutes) minutes."),
            ]))
        }
        return .section(SectionWidget(id: "models", title: "Leftover models", widgets: [widget]))
    }
}
