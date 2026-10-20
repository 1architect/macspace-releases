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
            return Banner(id: "status", severity: .warning, title: loc("Still installed for another account"),
                          message: loc("Apple Intelligence is on in \(elsewhere.map(\.label).joined(separator: ", ")). Its models are shared, so they stay on this Mac."))
        case .unknown:
            return Banner(id: "status", severity: .info, title: loc("Allow Full Disk Access"),
                          message: loc("MacSpace needs it to read and verify the switch."),
                          action: .allowFullDiskAccess(title: loc("Allow")))
        default:
            return nil
        }
    }

    /// macOS does not offer Apple Intelligence in a virtual machine, so there is nothing to switch off or release there.
    static func virtualMachineBanner() -> Banner {
        Banner(id: "status", severity: .info, title: loc("This is a virtual machine"),
               message: loc("macOS does not offer Apple Intelligence in a virtual machine. Use MacSpace on a real Mac."))
    }

    /// The tile shows the switch itself, with no glow. What can be freed is said in the line under it, without a meter: the models
    /// macOS released and can purge, or, while Apple Intelligence is on, the models it has downloaded (freed by switching it off).
    /// The models are changing (downloading while on, being released or deleted): the app reads again every few seconds so the size
    /// follows what macOS does.
    static func refreshAfter(_ snapshot: SiriSnapshot) -> Double? {
        // Not for `assetsRetrying`: those requests are minutes apart (`PurgeRetrier.delays`), and each 5-second reading of the page
        // started several processes, for as long as an hour, while nothing could change.
        let changing = snapshot.status.state == .releasing || snapshot.downloadingModelBytes > 0 || !snapshot.featureDownloading.isEmpty
            || snapshot.purgingModels || snapshot.releasingAutomatically || snapshot.cleaningFeatures
        // macOS deleting a switched-off feature's models: their size follows it down. Not once the cleanup has stalled (only a
        // restart changes anything then): the size waited for the usual minute while macOS freed hundreds of MB (2026-10-19).
            || !snapshot.featureCleanupWaiting.subtracting(snapshot.featureCleanupStalled).isEmpty
        return changing ? 5 : nil
    }

    static func tile(_ snapshot: SiriSnapshot) -> Tile {
        var tile = baseTile(snapshot)
        tile.refreshAfter = refreshAfter(snapshot)
        // One switch for them all: on while any of the page's switches is on; flipped, it switches every one that can be flipped to
        // its position (`tileSwitch`).
        if !snapshot.isVirtualMachine, let action = tileSwitch(snapshot) {
            tile.switchAction = action
            if case let .state(_, alarming, detail, meter, actionable) = tile.graphic {
                tile.graphic = .state(on: anySwitchOn(snapshot), alarming: alarming, detail: detail, meter: meter, meterIsActionable: actionable)
            }
        }
        return tile
    }

    private static func baseTile(_ snapshot: SiriSnapshot) -> Tile {
        if snapshot.isVirtualMachine {
            return Tile(title: loc("siri & AI"), status: loc("not in a virtual machine"), graphic: .state(on: false, alarming: false, detail: loc("not available here"), meter: nil, meterIsActionable: false))
        }
        let elsewhere = !(snapshot.accounts?.enabledElsewhere ?? []).isEmpty
        let on = snapshot.status.state == .atRisk
        let purge = snapshot.purgeableAssetsBytes.flatMap { $0 >= purgeThreshold ? $0 : nil }
        // Downloads count too: they take the space as they arrive and are freed the same way.
        let onDisk = (snapshot.installedModelBytes ?? 0) + snapshot.downloadingModelBytes
        let installed = on && onDisk >= purgeThreshold ? onDisk : nil
        // The Siri, Spatial Photos and Phone models count as the Apple Intelligence models do: on disk while their feature is on, freed
        // by switching it off.
        let features = featuresWithModels(snapshot, on: true)
        let featureBytes = features.map(\.bytes).reduce(0, +)
        let leftover = featuresWithModels(snapshot, on: false).map(\.bytes).reduce(0, +)
        var detail: String
        if let purge { detail = snapshot.assetsRetrying ? loc("freeing \(ByteFormat.string(purge)) of models") : loc("free up to \(ByteFormat.string(purge)) of models") }
        else if on, snapshot.downloadingModelBytes >= purgeThreshold { detail = loc("downloading models: \(ByteFormat.string(onDisk)) so far") }
        else if let installed { detail = loc("\(ByteFormat.string(installed)) of models; switch it off to free them") }
        else if let first = features.first {
            let size = ByteFormat.string(featureBytes)
            detail = features.count == 1 ? loc("\(size) of models for \(featureTitle(first.feature)); switch it off to free them")
                                         : loc("\(size) of models for Siri features; switch them off to free them")
        }
        else if on { detail = snapshot.installedModelBytes == nil ? loc("models not measured") : loc("no model downloaded yet") }
        // Off, models still on disk: released ones MacSpace is deleting, or a few macOS keeps for other features; their size, never
        // "none".
        // The state cannot be read: the size, without saying what happens to it.
        // The models of features switched off count with them: they were said clean while 2.4 GB of Siri's stayed on disk (2026-10-18).
        else if onDisk + leftover >= purgeThreshold, snapshot.status.state == .unknown { detail = loc("\(ByteFormat.string(onDisk + leftover)) of models on disk") }
        else if onDisk + leftover >= purgeThreshold {
            // What a purge deletes is what MobileAsset's records hold, less what is locked; the folders can hold more.
            let recorded = (snapshot.recordedModelBytes ?? 0) + snapshot.downloadingModelBytes
            let released = recorded > snapshot.lockedModelBytes ? recorded - snapshot.lockedModelBytes : 0
            let featuresDeleting = snapshot.cleaningFeatures || !snapshot.featureCleanupWaiting.isEmpty ? leftover : 0
            let deleting = (released >= purgeThreshold ? released : 0) + featuresDeleting
            // Models only a restart frees are not said to be deleting: the page asks for the restart (`restart`).
            let held = ModelFeatureSettings.Feature.allCases.filter { needsRestart($0, snapshot) }.compactMap { snapshot.featureModelBytes[$0] }.reduce(0, +)
            if held >= purgeThreshold { detail = loc("restart to free \(ByteFormat.string(held)) of models") }
            else if deleting >= purgeThreshold { detail = loc("deleting \(ByteFormat.string(deleting)) of models") }
            else { detail = loc("\(ByteFormat.string(onDisk + leftover)) of models kept by macOS") }
        }
        else if snapshot.status.state == .unknown { detail = loc("needs Full Disk Access to read") }
        else if snapshot.installedModelBytes == nil { detail = loc("models not measured") }
        else { detail = loc("no models left on disk") }
        if snapshot.cleaningFeatures { detail = loc("Freeing space") }
        // No meter: what is left to purge is said in the detail line.
        let graphic = TileGraphic.state(on: on, alarming: false, detail: detail, meter: nil, meterIsActionable: false)
        // With "Flag models on the Home page" off, models only a switch frees neither flag the tile nor make it the large one.
        let switchable = snapshot.flagsModels ? (installed ?? 0) + featureBytes : 0
        if let freeable = purge.map({ $0 + (snapshot.flagsModels ? featureBytes : 0) }) ?? (switchable > 0 ? switchable : nil) {
            return Tile(title: loc("siri & AI"), status: loc("free up to \(ByteFormat.string(freeable))"), needsAttention: switchable > 0, graphic: graphic,
                        reclaimableBytes: freeable, purgeableByService: [CacheDeleteService.mobileAsset: snapshot.purgeableAssetsBytes ?? 0])
        }
        switch snapshot.status.state {
        case .protected: return Tile(title: loc("siri & AI"), status: elsewhere ? loc("on in another account") : loc("AI is off"),
                                     needsAttention: elsewhere && snapshot.flagsModels, graphic: graphic)
        case .releasing: return Tile(title: loc("siri & AI"), status: loc("removing the model"), graphic: graphic)
        case .atRisk: return Tile(title: loc("siri & AI"), status: loc("AI is on"), needsAttention: snapshot.flagsModels, graphic: graphic)
        case .unknown: return Tile(title: loc("siri & AI"), status: loc("state unknown"), graphic: graphic)
        }
    }

    static let purgeThreshold: UInt64 = 50_000_000

    /// Whether a feature's switch is on, as its row shows it.
    static func featureIsOn(_ feature: ModelFeatureSettings.Feature, _ snapshot: SiriSnapshot) -> Bool? {
        if feature == .phone { return phoneStatus(snapshot).map { phoneFeatureRow($0).isOn } }
        return snapshot.featureSettings[feature].map { featureRow(feature, status: $0).isOn }
    }

    /// The features whose switch is `on` (or off) with models on disk worth freeing, largest first.
    static func featuresWithModels(_ snapshot: SiriSnapshot, on: Bool) -> [(feature: ModelFeatureSettings.Feature, bytes: UInt64)] {
        ModelFeatureSettings.Feature.allCases.compactMap { feature in
            guard featureIsOn(feature, snapshot) == on, let bytes = snapshot.featureModelBytes[feature], bytes >= purgeThreshold else { return nil }
            return (feature, bytes)
        }.sorted { $0.bytes > $1.bytes }
    }

    static func featureTitle(_ feature: ModelFeatureSettings.Feature) -> String {
        switch feature {
        case .siri: return loc("Siri")
        case .spatialPhotos: return loc("Spatial Photos")
        case .phone: return loc("Call transcription")
        }
    }

    /// A feature's models on disk, beside its switch, as a list row's size: while on, what switching it off frees; while off, what is
    /// still there. The badge says what happens to it.
    static func modelsSize(_ feature: ModelFeatureSettings.Feature, _ snapshot: SiriSnapshot) -> String? {
        guard let bytes = snapshot.featureModelBytes[feature], bytes >= purgeThreshold else { return nil }
        return ByteFormat.string(bytes)
    }

    /// Off with models still on disk, and MacSpace is not deleting them now: macOS keeps them. Switched off by MacSpace, it checks
    /// again every five minutes; switched off elsewhere, the models are not MacSpace's to delete.
    static func keptBadge(_ feature: ModelFeatureSettings.Feature, _ snapshot: SiriSnapshot, isOn: Bool, managedOff: Bool) -> Badge? {
        guard !isOn, modelsSize(feature, snapshot) != nil else { return nil }
        return Badge(loc("Kept by macOS"), .info, help: managedOff ? loc("MacSpace asks macOS again every five minutes.") : nil)
    }

    /// The Phone gates, with the native settings folded in.
    static func phoneStatus(_ snapshot: SiriSnapshot) -> PhoneFeatureFlags.Status? {
        guard var status = snapshot.phoneFeatures else { return nil }
        if let native = snapshot.featureSettings[.phone] { status.managedOff = status.managedOff && native.managedOff }
        if let native = snapshot.featureSettings[.phone], status.state == .off, native.state != .off {
            switch native.state {
            case .on: status.state = .on
            case .off: break
            case .changedElsewhere: status.state = .changedElsewhere
            case .unknown: status.state = .unknown
            case .unsupported: status.state = .unsupported
            }
            status.managedOff = false
        }
        return status
    }

    static func screen(_ snapshot: SiriSnapshot) -> Screen {
        if snapshot.isVirtualMachine {
            return Screen(title: loc("Siri & Apple Intelligence"), widgets: [.banner(virtualMachineBanner())])
        }
        var widgets: [ScreenWidget] = []
        if let banner = statusBanner(snapshot) { widgets.append(.banner(banner)) }
        widgets.append(.toggles(switchList(snapshot)))
        widgets.append(.list(ListWidget(id: "icloud", title: loc("Sync to other devices"), rows: [cloudSyncRow(enabled: snapshot.cloudSyncEnabled)])))
        if let accounts = accountsSection(snapshot) { widgets.append(accounts) }
        return Screen(title: loc("Siri & Apple Intelligence"), primary: primary(snapshot), widgets: widgets)
    }

    /// The page's main button, as Debloat's: free the models of the features switched off when they are still on disk, else the
    /// assets macOS no longer needs, else switch off every switch still on, else switch them all back on.
    static func primary(_ snapshot: SiriSnapshot) -> Action? {
        if freeingFeatures(snapshot) { return restart(snapshot) ?? disableAll(snapshot) ?? enableAll(snapshot) }
        return freeFeatures(snapshot) ?? purge(snapshot) ?? restart(snapshot) ?? disableAll(snapshot) ?? enableAll(snapshot)
    }

    /// The features MacSpace switched off whose models are still on disk and whose cleanup has stopped with them there (Kept by
    /// macOS): not one still being freed, not one waiting on a restart or being downloaded again.
    static func featuresToFree(_ snapshot: SiriSnapshot) -> [ModelFeatureSettings.Feature] {
        ModelFeatureSettings.Feature.allCases.filter { feature in
            let managedOff = feature == .phone ? phoneStatus(snapshot)?.managedOff == true : snapshot.featureSettings[feature]?.managedOff == true
            return managedOff && featureIsOn(feature, snapshot) == false && modelsSize(feature, snapshot) != nil
                && !needsRestart(feature, snapshot) && !snapshot.featureDownloading.contains(feature)
                && !snapshot.featureCleanupWaiting.contains(feature)
        }
    }

    /// A feature's models are being freed now (its switch says Freeing space): MacSpace deletes them as soon as macOS lets go, which
    /// no button can hurry.
    static func freeingFeatures(_ snapshot: SiriSnapshot) -> Bool {
        ModelFeatureSettings.Feature.allCases.contains { feature in
            modelsSize(feature, snapshot) != nil && (snapshot.cleaningFeatures || snapshot.featureCleanupWaiting.contains(feature))
                && !needsRestart(feature, snapshot)
        }
    }

    /// Frees the models of the features whose cleanup stopped with them on disk, tried again now, with the figure their rows show.
    /// While a feature is still being freed there is no Free at all: the purge of every unused asset showed macOS's estimate for
    /// all of them (182.8 MB beside a 371.4 MB row), and pressed before macOS had let go of Spatial Photos' models it freed nothing
    /// and said All done, while the models went by themselves minutes later (2026-10-19).
    static func freeFeatures(_ snapshot: SiriSnapshot) -> Action? {
        let features = featuresToFree(snapshot)
        guard !features.isEmpty else { return nil }
        let size = ByteFormat.string(features.compactMap { snapshot.featureModelBytes[$0] }.reduce(0, +))
        return Action(id: "freeFeatureModels", title: loc("Free \(size)"), symbol: "sparkles", role: .prominent,
                      confirmation: Confirmation(title: loc("Free \(size)?"),
                                                 message: loc("Deletes the models of the features you switched off. They download again if you switch one back on."),
                                                 confirmTitle: loc("Free")),
                      workingTitle: loc("Freeing space"))
    }

    /// Features switched off whose models only a restart lets macOS delete: the cleanup waited about ten minutes with none of them
    /// going (`SiriSnapshot.featureCleanupStalled`), or a Call transcription change macOS reads at startup. A lock alone is not one:
    /// macOS's services usually let go within minutes, and asking for a restart then sent users to restart for nothing.
    static func needsRestart(_ feature: ModelFeatureSettings.Feature, _ snapshot: SiriSnapshot) -> Bool {
        if feature == .phone, phoneStatus(snapshot)?.state == .restartRequired { return true }
        // Only for a feature switched off: one that is on keeps its models, and a restart frees nothing.
        guard featureIsOn(feature, snapshot) == false else { return false }
        // macOS is downloading its models again: a restart does not stop that, and the cleanup waits for the download to end.
        guard !snapshot.featureDownloading.contains(feature) else { return false }
        return snapshot.featureCleanupStalled.contains(feature) && snapshot.featureCleanupWaiting.contains(feature)
            && modelsSize(feature, snapshot) != nil
    }

    /// Restart to finish, through macOS's own Restart dialog (`SystemRestart`): what it frees, when that is known.
    static func restart(_ snapshot: SiriSnapshot) -> Action? {
        let features = ModelFeatureSettings.Feature.allCases.filter { needsRestart($0, snapshot) }
        guard !features.isEmpty else { return nil }
        let bytes = features.compactMap { snapshot.featureModelBytes[$0] }.filter { $0 >= purgeThreshold }.reduce(0, +)
        return .restart(title: bytes > 0 ? loc("Restart to free \(ByteFormat.string(bytes))") : nil)
    }

    static func anySwitchOn(_ snapshot: SiriSnapshot) -> Bool { switchList(snapshot).rows.contains(where: \.isOn) }

    /// The tile's switch: `value` false switches off every switch on, true switches on every one off. nil when none can be flipped.
    static func tileSwitch(_ snapshot: SiriSnapshot) -> Action? {
        let on = switchable(snapshot, on: true), off = switchable(snapshot, on: false)
        guard !on.isEmpty || !off.isEmpty else { return nil }
        return Action(id: "setAll", title: loc("Apple Intelligence"),
                      parameters: ["on": on.map(\.id).joined(separator: ","), "off": off.map(\.id).joined(separator: ",")],
                      requires: (on + off).flatMap(\.action.requires).reduce(into: []) { if !$0.contains($1) { $0.append($1) } })
    }

    /// The switch rows that can be flipped `on` (or off) now.
    static func switchable(_ snapshot: SiriSnapshot, on: Bool) -> [ToggleRow] {
        switchList(snapshot).rows.filter { $0.isEnabled && $0.isOn == on }
    }

    /// One switch left is named; more are counted.
    static func setAll(_ rows: [ToggleRow], on: Bool) -> Action {
        let one = rows.count == 1 ? rows[0].title : nil
        let title = on ? one.map { loc("Enable \($0)") } ?? loc("Enable all") : one.map { loc("Disable \($0)") } ?? loc("Disable all")
        let question = on ? one.map { loc("Enable \($0) again?") } ?? loc("Enable all \(rows.count) features again?")
                          : one.map { loc("Disable \($0)?") } ?? loc("Disable \(rows.count) features?")
        return Action(id: on ? "enableAll" : "disableAll", title: title,
               symbol: on ? "arrow.uturn.backward" : "checkmark.shield", role: .prominent,
               parameters: ["ids": rows.map(\.id).joined(separator: ",")],
               confirmation: on
                ? Confirmation(title: question, message: loc("macOS downloads their models again."), confirmTitle: loc("Enable"))
                : Confirmation(title: question, message: loc("Each one can be enabled again. MacSpace frees their models."), confirmTitle: loc("Disable")),
               requires: rows.flatMap(\.action.requires).reduce(into: []) { if !$0.contains($1) { $0.append($1) } })
    }

    static func disableAll(_ snapshot: SiriSnapshot) -> Action? {
        let rows = switchable(snapshot, on: true)
        return rows.isEmpty ? nil : setAll(rows, on: false)
    }

    static func enableAll(_ snapshot: SiriSnapshot) -> Action? {
        let rows = switchable(snapshot, on: false)
        return rows.isEmpty ? nil : setAll(rows, on: true)
    }

    static func purge(_ snapshot: SiriSnapshot) -> Action? {
        // No button while MacSpace is already asking macOS again in the background.
        guard let bytes = snapshot.purgeableAssetsBytes, bytes >= purgeThreshold, !snapshot.assetsRetrying else { return nil }
        return Action(id: "purgeAssets", title: loc("Free up to \(ByteFormat.string(bytes))"), symbol: "sparkles", role: .prominent,
                      confirmation: Confirmation(title: loc("Free up to \(ByteFormat.string(bytes))?"), message: loc("Deletes Apple Intelligence models and other downloads macOS no longer needs."), confirmTitle: loc("Free")), workingTitle: loc("Freeing space"))
    }

    static func switchList(_ snapshot: SiriSnapshot) -> ToggleList {
        let available = isAvailable(snapshot.status) ?? false
        // Why it cannot be switched now is the badge's help; the (i) says only what the switch does (`InfoText`).
        var blocked: SiriPlanFailure?
        if case let .failure(failure) = snapshot.disablePlan,
           snapshot.status.state == .atRisk || (snapshot.status.state == .protected || snapshot.status.state == .releasing) && available {
            blocked = failure
        }
        // No confirmation: the switch moves at once and the change follows; if it fails, the switch goes back and says why.
        var ai = ToggleRow(id: "ai", title: loc("Apple Intelligence"), isOn: available, isEnabled: blocked == nil,
                           badge: blocked.map { Badge(loc("Can't change now"), .info, help: $0.message) },
                           detail: loc("Switching it off sets Siri to a different language than your Mac.") + " "
                             + loc("With Siri's iCloud sync on, this also changes Siri on your iPhone and iPad."),
                           action: switchAction)
        // Its models beside the switch and where their cleanup stands, as the feature rows below have theirs.
        if ai.badge == nil { ai.badge = aiModelsBadge(snapshot, isOn: available) }
        ai.trailing = aiModelsSize(snapshot)
        var rows = [ai]
        // Keep the existing AI language control first, then the feature controls, with the restart-requiring Phone group last.
        for feature in [ModelFeatureSettings.Feature.siri, .spatialPhotos] {
            if let status = snapshot.featureSettings[feature] {
                var row = featureRow(feature, status: status)
                if row.badge == nil {
                    row.badge = (status.managedOff ? cleanupBadge(feature, snapshot) : nil) ?? keptBadge(feature, snapshot, isOn: row.isOn, managedOff: status.managedOff)
                }
                if snapshot.featureDownloading.contains(feature) { row.badge = Badge(loc("Downloading"), .info) }
                row.trailing = modelsSize(feature, snapshot)
                rows.append(row)
            }
        }
        if let status = phoneStatus(snapshot) {
            var row = phoneFeatureRow(status)
            if row.badge == nil {
                row.badge = (status.managedOff ? cleanupBadge(.phone, snapshot) : nil) ?? keptBadge(.phone, snapshot, isOn: row.isOn, managedOff: status.managedOff)
            }
            if snapshot.featureDownloading.contains(.phone) { row.badge = Badge(loc("Downloading"), .info) }
            row.trailing = modelsSize(.phone, snapshot)
            rows.append(row)
        }
        return ToggleList(id: "switch", title: loc("Models"), rows: rows)
    }

    /// The Apple Intelligence models on disk, downloads included, as a list row's size: while on, what switching it off frees; while
    /// off, what is still there.
    static func aiModelsSize(_ snapshot: SiriSnapshot) -> String? {
        let bytes = (snapshot.installedModelBytes ?? 0) + snapshot.downloadingModelBytes
        return bytes >= purgeThreshold ? ByteFormat.string(bytes) : nil
    }

    /// Where the Apple Intelligence models stand, in the feature rows' pills: downloading while on; once off, being freed (macOS
    /// removing them, MacSpace releasing or deleting them), waiting for macOS to let them go, or kept. What the user must do first
    /// (another account keeps them) is the pill's hover tag.
    static func aiModelsBadge(_ snapshot: SiriSnapshot, isOn: Bool) -> Badge? {
        if isOn { return snapshot.downloadingModelBytes > 0 ? Badge(loc("Downloading"), .info) : nil }
        guard aiModelsSize(snapshot) != nil else { return nil }
        if snapshot.releasingAutomatically || snapshot.purgingModels { return Badge(loc("Freeing space"), .info) }
        if snapshot.status.state == .releasing {
            if !snapshot.releaseBlockers.isEmpty {
                return Badge(loc("Kept by macOS"), .action, help: snapshot.releaseBlockers.joined(separator: " "))
            }
            let minutes = Int(ModelAutoRelease.settleTime / 60)
            return Badge(loc("macOS is freeing the model"), .info,
                         help: loc("Usually takes a few instants. If it doesn't, MacSpace does it after \(minutes) minutes."))
        }
        return Badge(loc("Kept by macOS"), .info)
    }

    /// Where a feature MacSpace switched off stands with its models.
    static func cleanupBadge(_ feature: ModelFeatureSettings.Feature, _ snapshot: SiriSnapshot) -> Badge? {
        // Nothing worth a size is left (`modelsSize`): the switch says no more, whatever macOS keeps of its catalog. Checked first:
        // the run in view said Freeing space on every switch it covered, models or not (2026-10-19).
        guard modelsSize(feature, snapshot) != nil else { return nil }
        if snapshot.cleaningFeatures { return Badge(loc("Freeing space"), .info) }
        if needsRestart(feature, snapshot) {
            return .restartRequired(help: loc("macOS kept these models for ten minutes. After a restart, MacSpace deletes them."))
        }
        // MacSpace is deleting them, again and again until they are gone (`ManagedModelCleanup`): the standard freeing pill. What
        // holds them up, when something does, is its hover tag.
        if snapshot.featureCleanupWaiting.contains(feature) {
            let help = snapshot.featureLocked.contains(feature)
                ? loc("macOS's own services still have these models open. They usually let go within minutes, and MacSpace then deletes them.")
                : nil
            return Badge(loc("Freeing space"), .info, help: help)
        }
        return nil
    }

    static func featureRow(_ feature: ModelFeatureSettings.Feature, status: ModelFeatureSettings.Status) -> ToggleRow {
        let siri = feature == .siri
        let title = siri ? loc("Siri") : loc("Spatial Photos")
        let detail = siri
            ? loc("Turns Siri off and frees its unused models. MacSpace checks again while it stays off. Your Siri language is kept.")
            : loc("Turns off spatial photo effects and frees their downloaded models.")
        let badge: Badge?
        switch status.state {
        case .changedElsewhere: badge = Badge(loc("Changed outside MacSpace"), .info)
        case .unknown: badge = Badge(loc("State unknown"), .info)
        case .unsupported: badge = Badge(loc("Not verified on this macOS version"), .info)
        case .on, .off: badge = nil
        }
        return ToggleRow(id: feature.rawValue, title: title,
                         isOn: status.requestedOff.map { !$0 } ?? (status.state != .off),
                         isEnabled: status.state == .on || status.state == .off || status.requestedOff == true,
                         badge: badge, detail: detail,
                         action: Action(id: "toggleModelFeature", title: title, parameters: ["feature": feature.rawValue]))
    }

    static func phoneFeatureRow(_ status: PhoneFeatureFlags.Status) -> ToggleRow {
        let on: Bool
        switch status.state {
        case .off: on = false
        case .on: on = true
        default: on = status.requestedOff.map { !$0 } ?? true
        }
        // The state is the badge, and what it means its help; the (i) is the same in every state (`InfoText`).
        let badge: Badge?
        switch status.state {
        case .restartRequired:
            badge = .restartRequired()
        case .changedElsewhere:
            badge = Badge(loc("Changed outside MacSpace"), .info,
                          help: loc("Another change affects these settings. MacSpace keeps it and does not free the call transcription models by itself."))
        case .unknown:
            badge = Badge(loc("State unknown"), .info, help: loc("MacSpace could not read every Call transcription setting."))
        case .unsupported:
            badge = Badge(loc("Not verified on this macOS version"), .info)
        case .on, .off:
            badge = nil
        }
        return ToggleRow(id: "phone", title: loc("Call transcription"), isOn: on,
                         isEnabled: status.state != .unknown && status.state != .changedElsewhere
                            && (status.state != .unsupported || status.requestedOff == true),
                         badge: badge,
                         detail: loc("Turns off call recording, transcription, captions and translation, Live Voicemail and Call Screening. Needs a restart."),
                         action: Action(id: "togglePhoneFeatures", title: loc("Call transcription"), requires: [.privilegedHelper]))
    }

    /// Switches Apple Intelligence, from the page's switch row and the tile's switch alike.
    static let switchAction = Action(id: "toggle", title: loc("Apple Intelligence"), parameters: ["id": "ai"], requires: [.fullDiskAccess])

    /// Siri's iCloud sync, which only the user can turn off: whether it is on now, in the title (when it can be read), what it does,
    /// the steps while it is on, and a button to the page that has it.
    static func cloudSyncRow(enabled: Bool?) -> Row {
        let title: String
        switch enabled {
        case true?: title = loc("Siri's iCloud sync is currently on")
        case false?: title = loc("Siri's iCloud sync is currently off")
        case nil: title = loc("Siri's iCloud sync")
        }
        return Row(id: "icloud-sync", title: title,
                   symbol: enabled == false ? "checkmark.icloud" : "icloud",
                   detail: loc("While it is on, Siri's language change reaches your iPhone and iPad too. Turn it off to keep the change on this Mac."),
                   steps: enabled == false ? [] : SiriCloudSync.steps,
                   actions: [.openSettings(title: loc("Open"), url: SiriCloudSync.settingsURL)])
    }

    static func accountsSection(_ snapshot: SiriSnapshot) -> ScreenWidget? {
        guard let elsewhere = snapshot.accounts?.enabledElsewhere, !elsewhere.isEmpty else { return nil }
        let rows = elsewhere.map { account -> Row in
            let steps: [String] = account.name.map { name in
                [loc("Log in as \(name) and turn Apple Intelligence off there."),
                 loc("Or delete the account in System Settings > Users & Groups.")]
            } ?? [loc("This account was deleted, but macOS still keeps its models. In Terminal, run:"),
                  "sudo \"\(snapshot.cliPath)\" orphan-subscriptions --execute",
                  loc("Restart. MacSpace then deletes the models.")]
            return Row(id: "account:\(account.guid)", title: account.label, subtitle: account.useCases.count == 1 ? loc("1 feature") : loc("\(account.useCases.count) features"),
                       badge: Badge(loc("Keeps the models"), .action), symbol: "person.crop.circle.badge.exclamationmark", steps: steps)
        }
        return .section(SectionWidget(id: "accounts", title: loc("Other accounts"),
                                      subtitle: loc("One account with Apple Intelligence on keeps the models on this Mac."),
                                      widgets: [.list(ListWidget(id: "accounts-list", rows: rows))]))
    }
}
