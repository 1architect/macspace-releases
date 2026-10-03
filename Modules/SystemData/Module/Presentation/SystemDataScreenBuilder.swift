import Foundation
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceSystemDataPrivileged

/// Turns a snapshot into the widgets the app draws. Pure, so it can be tested without scanning a Mac.
enum SystemDataScreenBuilder {
    /// What the usage bar groups System Data into. Tones are series colors in this order.
    struct Group {
        let id: String
        let title: String
        let kinds: Set<SystemDataKind>
    }

    static let groups: [Group] = [
        Group(id: "versions", title: "Document versions", kinds: [.documentVersions]),
        Group(id: "appdata", title: "Apple app data", kinds: [.appContainer]),
        Group(id: "caches", title: "Caches", kinds: [.appCache, .userSystemCache, .toolCache]),
        Group(id: "support", title: "App support files", kinds: [.appSupport]),
        Group(id: "leftovers", title: "Leftovers", kinds: [.orphanedHome, .trash, .stagedUpdate]),
        Group(id: "developer", title: "Homebrew and packages", kinds: [.packageManager]),
        Group(id: "macos", title: "Managed by macOS",
              kinds: [.logs, .symbolCache, .spotlightIndex, .spotlightMetadata, .systemAssets, .snapshot, .diagnosticReports]),
    ]

    /// Kinds System Settings lists in other categories: the Command Line Tools under Developer (1.42 GB there against 1.31-1.41 GB
    /// measured) and swap, which sits on the VM volume. Counting them here overstated System Data by about 3.5 GB.
    static let countedElsewhere: Set<SystemDataKind> = [.developerTools, .virtualMemory]

    /// Whether System Settings files the item under another category: cloud copies, unfinished downloads, restore images and virtual
    /// machines under Documents, and third-party apps' containers under Applications. Measured on 26B5091g: Documents 6.7 GB ≈
    /// Documents + Desktop + Downloads + cloud copies; Applications 28.48 GB = 19.04 GB of bundles + about 9.4 GB of app data; a 25 GB
    /// restore image in Downloads showed up in System Data until Spotlight indexed it, then moved to Documents (+21.91 GB there, −21.91 GB
    /// in System Data, used space unchanged). Apple's own containers stay in System Data.
    static func countedByAnotherCategory(_ item: SystemDataItem) -> Bool {
        switch item.kind {
        case .cloudStorage, .partialDownload, .restoreImage, .virtualMachine: return true
        case .appContainer: return item.cleanup.kind == .review
        default: return false
        }
    }

    /// Items that count toward the bar. Code-signing clones share storage with their apps, so they are left out.
    static func measured(_ report: SystemDataReport) -> [SystemDataItem] {
        report.items.filter { $0.kind != .codeSignClone && !countedElsewhere.contains($0.kind) && !countedByAnotherCategory($0) && ($0.bytes ?? 0) > 0 }
    }

    static func usage(_ snapshot: SystemDataSnapshot) -> UsageBar {
        let items = measured(snapshot.report)
        var segments: [UsageSegment] = []
        for (index, group) in groups.enumerated() {
            let bytes = items.filter { group.kinds.contains($0.kind) }.compactMap(\.bytes).reduce(0, +)
            if bytes > 0 { segments.append(UsageSegment(id: group.id, label: group.title, bytes: bytes, tone: .series(index))) }
        }
        let clones = snapshot.report.items.filter { $0.kind == .codeSignClone }.compactMap(\.bytes).reduce(0, +)
        var footnote = "Measured on this Mac's Data volume."
        if clones > 0 { footnote += " \(ByteFormat.string(clones)) of code-signing copies share space with their apps and are not counted." }
        let elsewhere = snapshot.report.items.filter { countedElsewhere.contains($0.kind) }.compactMap(\.bytes).reduce(0, +)
        let otherCategory = snapshot.report.items.filter(countedByAnotherCategory).compactMap(\.bytes).reduce(0, +)
        if otherCategory > 0 { footnote += " \(ByteFormat.string(otherCategory)) of cloud copies, downloads, virtual machines and apps' own data are not counted: System Settings lists them under Documents and Applications." }
        if elsewhere > 0 { footnote += " \(ByteFormat.string(elsewhere)) of developer tools and swap are not counted: System Settings lists them under Developer and macOS." }
        let skipped = quietlySkipped(snapshot)
        if skipped > 0 { footnote += skipped == 1 ? " 1 place macOS keeps private was skipped." : " \(skipped) places macOS keeps private were skipped." }
        return UsageBar(id: "usage", title: "What fills System Data", segments: segments, footnote: footnote)
    }

    /// Bytes Clean frees: caches, old reports and unused system assets. Caches of apps that are open are left out: they cannot be
    /// cleaned until the app quits.
    static func cleanBytes(_ snapshot: SystemDataSnapshot) -> UInt64 {
        let caches = snapshot.report.items.filter { $0.cleanup.kind == .deleteWhenNotRunning && !$0.inUse }
            .compactMap(\.expectedReclaimBytes).reduce(0, +)
        return caches + (snapshot.purgeableAssetsBytes ?? 0) + snapshot.reports.totalBytes
    }

    /// Document version history when it is offered under Free now (its own Delete button, not Clean).
    static func versionHistoryBytes(_ snapshot: SystemDataSnapshot) -> UInt64 {
        guard versionsRow(snapshot) != nil else { return 0 }
        return snapshot.report.items.first { $0.id == "versions:documents" }?.bytes ?? 0
    }

    /// Bytes MacSpace can free right now without the user doing anything in another app: what Clean frees and the version history.
    /// This is the tile's figure and its "can be freed" block.
    static func freeableBytes(_ snapshot: SystemDataSnapshot) -> UInt64 {
        cleanBytes(snapshot) + versionHistoryBytes(snapshot)
    }

    /// What a cleanup must reach to be worth a row: smaller amounts are noise.
    static let worthARow: UInt64 = 1_000_000

    static func tile(_ snapshot: SystemDataSnapshot) -> Tile {
        let freeable = freeableBytes(snapshot)
        return Tile(title: "system data", status: freeable >= worthARow ? "\(ByteFormat.string(freeable)) can be freed" : "nothing to free",
                    needsAttention: partialBanner(snapshot) != nil, graphic: .blocks(blocks(snapshot)),
                    reclaimableBytes: freeable >= worthARow ? freeable : nil)
    }

    /// What fills System Data as blocks, largest first, with what can be freed split out as its own block in the caution tone (what
    /// Clean frees taken out of the caches it mostly comes from, the version history out of its own block, so the total stays the same).
    static func blocks(_ snapshot: SystemDataSnapshot) -> [UsageSegment] {
        var segments = usage(snapshot).segments
        let freeable = freeableBytes(snapshot)
        if freeable >= worthARow {
            func take(_ bytes: UInt64, from id: String) {
                guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
                segments[index].bytes -= min(bytes, segments[index].bytes)
                if segments[index].bytes == 0 { segments.remove(at: index) }
            }
            take(cleanBytes(snapshot), from: "caches")
            take(versionHistoryBytes(snapshot), from: "versions")
            segments.append(UsageSegment(id: "freeable", label: "Can be freed", bytes: freeable, tone: .caution))
        }
        return segments.sorted { $0.bytes > $1.bytes }
    }

    /// The page: the bar, one Clean for everything safe, then only what the user can act on. What MacSpace leaves alone is listed once,
    /// collapsed, so the total still adds up.
    static func screen(_ snapshot: SystemDataSnapshot) -> Screen {
        var widgets: [ScreenWidget] = []
        if let banner = partialBanner(snapshot) { widgets.append(banner) }
        if let free = freeNow(snapshot) { widgets.append(free) }
        if let leftover = leftoverUpdateSection(snapshot) { widgets.append(leftover) }
        if let assets = assetsSection(snapshot) { widgets.append(assets) }
        if let appData = appDataSection(snapshot) { widgets.append(appData) }
        if let other = otherSection(snapshot) { widgets.append(other) }
        let hero = UsageBar(id: "usage", title: "What fills System Data", segments: blocks(snapshot))
        return Screen(title: "System Data", hero: hero, primary: cleanAll(snapshot), widgets: widgets)
    }

    static func cleanAll(_ snapshot: SystemDataSnapshot) -> Action? {
        let total = cleanBytes(snapshot)
        guard total >= worthARow else { return nil }
        var message = "Deletes the caches, old reports and unused system assets listed under Free now. None of it holds your files, and macOS recreates what it needs."
        if versionsRow(snapshot) != nil { message += " Document version history is not deleted: it has its own Delete button." }
        return Action(id: "cleanAll", title: "Free \(ByteFormat.string(total))", symbol: "sparkles", role: .prominent,
                      confirmation: Confirmation(title: "Free \(ByteFormat.string(total))?", message: message, confirmTitle: "Free"))
    }

    // MARK: Sections

    /// What Clean deletes, item by item, then document version history, which only its own button deletes. nil when there is nothing
    /// worth a row.
    static func freeNow(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        let cleanable = snapshot.report.items.filter { $0.cleanup.kind == .deleteWhenNotRunning && ($0.expectedReclaimBytes ?? 0) >= worthARow }
            .sorted { ($0.expectedReclaimBytes ?? 0) > ($1.expectedReclaimBytes ?? 0) }
        var rows = cleanable.map { item -> Row in
            Row(id: item.id, title: item.title, subtitle: item.inUse ? "Quit \(item.owners.joined(separator: ", ")) first." : nil,
                trailing: ByteFormat.string(item.expectedReclaimBytes ?? 0),
                badge: item.inUse ? Badge("App is open", tone: .caution) : nil, symbol: "internaldrive", detail: item.cleanup.description,
                actions: item.inUse ? [] : [Action(id: "clean", title: "Free", parameters: ["id": item.id])])
        }
        if snapshot.reports.totalBytes >= worthARow {
            rows.append(Row(id: "reports", title: "Old diagnostic and crash reports", trailing: ByteFormat.string(snapshot.reports.totalBytes), symbol: "doc.text",
                            detail: "\(snapshot.reports.candidates.count) report(s) older than \(snapshot.reports.olderThanDays) days. Nothing reads them back.",
                            actions: [Action(id: "cleanReports", title: "Free", confirmation: Confirmation(
                                title: "Delete old reports?", message: "This permanently deletes \(snapshot.reports.candidates.count) report file(s).", confirmTitle: "Delete"))]))
        }
        if let assets = snapshot.purgeableAssetsBytes, assets >= assetsThreshold {
            rows.append(Row(id: "assets", title: "Unused system assets", trailing: ByteFormat.string(assets), symbol: "square.stack.3d.down.right",
                            detail: "Downloads macOS no longer needs, such as Apple Intelligence models released by the off-switch. macOS deletes them only when the disk is nearly full; this does it now. Anything needed again is downloaded again.",
                            actions: [Action(id: "purgeAssets", title: "Free", confirmation: Confirmation(
                                title: "Free unused system assets?", message: "macOS deletes the assets it no longer needs, about \(ByteFormat.string(assets)).", confirmTitle: "Free"))]))
        }
        if let versions = versionsRow(snapshot) { rows.append(versions) }
        guard !rows.isEmpty else { return nil }
        return .section(SectionWidget(id: "free", title: "Free now", widgets: [.list(ListWidget(id: "free-list", rows: rows))]))
    }

    static let manualThreshold: UInt64 = 50_000_000

    /// Everything MacSpace leaves alone (it belongs to apps, to the user or to macOS), largest first.
    static func leftAlone(_ snapshot: SystemDataSnapshot) -> [SystemDataItem] {
        let report = snapshot.report
        let handled: Set<String> = ["reports:diagnostic", "versions:documents", "update:staged", "assets:system"]
        return report.items.filter { item in
            guard let bytes = item.bytes, bytes >= manualThreshold, !handled.contains(item.id), !item.id.hasPrefix("small:") else { return false }
            switch item.cleanup.kind {
            case .review: return !countedByAnotherCategory(item)
            case .managedByMacOS, .command: return item.kind != .codeSignClone && !countedElsewhere.contains(item.kind)
            default: return false
            }
        }
        .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    /// What apps keep for themselves (their support folders and containers), listed apart from the rest MacSpace leaves alone.
    static let appDataKinds: Set<SystemDataKind> = [.appSupport, .appContainer]

    static func appDataSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        let items = leftAlone(snapshot).filter { appDataKinds.contains($0.kind) }
        guard !items.isEmpty else { return nil }
        return .section(SectionWidget(id: "appdata", title: "App data", subtitle: "Kept by apps for themselves. MacSpace leaves it alone.",
                                      widgets: [.list(ListWidget(id: "appdata-list", rows: leftAloneRows(items)))]))
    }

    static func otherSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        let items = leftAlone(snapshot).filter { !appDataKinds.contains($0.kind) }
        guard !items.isEmpty else { return nil }
        return .section(SectionWidget(id: "other", title: "Everything else", subtitle: "Used by macOS and your tools. MacSpace leaves it alone.",
                                      widgets: [.list(ListWidget(id: "other-list", rows: leftAloneRows(items)))]))
    }

    /// The ten largest, with what the item is and why it stays.
    private static func leftAloneRows(_ items: [SystemDataItem]) -> [Row] {
        items.prefix(10).map { item in
            Row(id: item.id, title: item.title, trailing: ByteFormat.string(item.bytes ?? 0),
                detail: ([item.cleanup.description] + item.notes).joined(separator: " "))
        }
    }

    /// Files of an update that is already installed; shown only when the scan recognised them as a leftover (see the inspector).
    static func leftoverUpdateSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        guard let item = snapshot.report.items.first(where: { $0.id == "update:staged" && $0.kind == .stagedUpdate && $0.cleanup.kind == .managedByMacOS }),
              let bytes = item.bytes, bytes > 0 else { return nil }
        let size = ByteFormat.string(bytes)
        let row = Row(id: "leftover-update", title: "Leftover macOS update files",
                      subtitle: "Files of an earlier update that is already installed. No update is waiting.",
                      trailing: size, symbol: "arrow.down.app",
                      detail: "macOS did not remove these after the update. A protected part of the folder stays; MacSpace deletes the rest.",
                      actions: [Action(id: "deleteStagedUpdate", title: "Delete", role: .destructive,
                                       confirmation: Confirmation(title: "Delete the leftover update files?",
                                                                  message: "This deletes about \(size) of files from an update that is already installed. If you ever need that update again, macOS downloads it again. A protected part of the folder stays.",
                                                                  confirmTitle: "Delete"),
                                       requires: [.privilegedHelper])])
        return .section(SectionWidget(id: "leftover-update", title: "Leftover update files", subtitle: "Left behind by an update that finished earlier.",
                                      widgets: [.list(ListWidget(id: "leftover-update-list", rows: [row]))]))
    }

    /// The saved history behind File > Revert To > Browse All Versions, as a row of Free now. Deleting it is irreversible, so it keeps
    /// its badge and its own confirmation, and Clean leaves it out.
    static func versionsRow(_ snapshot: SystemDataSnapshot) -> Row? {
        guard let item = snapshot.report.items.first(where: { $0.id == "versions:documents" }), let bytes = item.bytes, bytes >= manualThreshold else { return nil }
        let size = ByteFormat.string(bytes)
        return Row(id: "versions", title: "Document version history", subtitle: "Saved earlier versions of documents (File → Revert To → Browse All Versions).",
                      trailing: size, badge: Badge("Cannot be undone", tone: .critical), symbol: "clock.arrow.circlepath",
                      detail: "Deleting it removes the earlier versions of every document. The documents themselves stay. Versions share blocks with their documents, so the space freed can be less than \(size); MacSpace measures what the volume gains. Save your documents and quit apps that edit them first.",
                      actions: [Action(id: "deleteVersions", title: "Delete…", role: .destructive,
                                       confirmation: Confirmation(title: "Delete all version history?",
                                                                  message: "This permanently removes the earlier versions of every document on this Mac (\(size) stored). You will no longer be able to revert documents to earlier states. The documents themselves are not touched.\n\nSave and close your documents first. MacSpace stops the macOS versions service, deletes the store and starts the service again.",
                                                                  confirmTitle: "Delete version history"),
                                       requires: [.privilegedHelper])])
    }

    /// System downloads the user can release by changing a setting. Families with no setting are not something to act on, so they
    /// are not listed.
    static func assetsSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        let families = snapshot.assetFamilies.filter { !$0.steps.isEmpty && $0.bytes >= 100_000_000 }
        guard !families.isEmpty else { return nil }
        let rows = families.map { family -> Row in
            Row(id: "assets:\(family.id)", title: family.title, subtitle: family.heldBy, trailing: ByteFormat.string(family.bytes),
                symbol: "square.stack.3d.down.right", detail: family.verified ? nil : "Menu names can differ between macOS versions.", steps: family.steps)
        }
        return .section(SectionWidget(id: "assets", title: "Downloads you can turn off", subtitle: "Change the setting and restart; the downloads then show under Free now.",
                                      widgets: [.list(ListWidget(id: "assets-list", rows: rows))]))
    }

    /// Unreadable places the user can do something about: all of them without Full Disk Access, and the root-only ones until the helper
    /// has measured them or been reached. What macOS keeps closed even to Full Disk Access and the helper (some Apple containers, for
    /// example) is not something to warn about: no customer can fix it, so it only shows as a quiet note under the bar.
    static func actionableUnreadable(_ snapshot: SystemDataSnapshot) -> (fullDiskAccess: [String], helper: [String], helperUnreachable: [String]) {
        let paths = snapshot.report.unreadable
        let rootOnly = paths.filter(RootMeasuredLocations.allowed.contains)
        let other = paths.filter { !RootMeasuredLocations.allowed.contains($0) }
        let fda = snapshot.report.fullDiskAccess ? [] : other
        if snapshot.helperError != nil { return (fda, [], rootOnly) }
        return (fda, snapshot.helperTried ? [] : rootOnly, [])
    }

    /// How many unreadable places stay silent because nothing can be done about them.
    static func quietlySkipped(_ snapshot: SystemDataSnapshot) -> Int {
        let actionable = actionableUnreadable(snapshot)
        return snapshot.report.unreadable.count - actionable.fullDiskAccess.count - actionable.helper.count - actionable.helperUnreachable.count
    }

    /// nil when there is nothing the user can fix.
    static func partialBanner(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        let actionable = actionableUnreadable(snapshot)
        if !actionable.fullDiskAccess.isEmpty {
            return .banner(Banner(id: "partial", severity: .info, title: "Allow Full Disk Access to see everything",
                                  message: "\(actionable.fullDiskAccess.count) places could not be measured, so the numbers are low.",
                                  action: Action(id: "openFullDiskAccess", title: "Allow", role: .prominent)))
        }
        if !actionable.helper.isEmpty {
            return .banner(Banner(id: "partial", severity: .info, title: "Turn on the helper to see everything",
                                  message: "\(actionable.helper.count) places only the helper can measure: \(unreadableList(actionable.helper)). Turn it on in Settings."))
        }
        if !actionable.helperUnreachable.isEmpty {
            return .banner(Banner(id: "partial", severity: .warning, title: "The helper did not answer",
                                  message: "\(actionable.helperUnreachable.count) places were not measured. Reopen MacSpace; if it persists, reinstall the helper in Settings."))
        }
        return nil
    }

    /// Up to four locations, home folder shortened, so the user can see what is missing.
    static func unreadableList(_ paths: [String]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = paths.prefix(4).map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
        return shown.joined(separator: ", ") + (paths.count > 4 ? " and \(paths.count - 4) more" : "")
    }

    static let assetsThreshold: UInt64 = 50_000_000
}
