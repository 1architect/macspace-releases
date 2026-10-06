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
        Group(id: "update", title: "macOS update to install", kinds: [.pendingUpdate]),
        Group(id: "shared", title: "Apps' files for all users", kinds: [.sharedAppFiles]),
        Group(id: "macos", title: "Managed by macOS",
              kinds: [.logs, .symbolCache, .spotlightIndex, .spotlightMetadata, .systemAssets, .snapshot, .diagnosticReports, .systemLibrary]),
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

    /// What an item adds to System Data: its size without what macOS may delete by itself, which System Settings counts as free
    /// space. Files flagged purgeable are measured with the item; the Spotlight index and the system assets are purged by services of
    /// their own, whose figures are taken off them.
    static func counted(_ item: SystemDataItem, _ snapshot: SystemDataSnapshot) -> UInt64 {
        let bytes = item.bytes ?? 0
        var purgeable = item.purgeableBytes ?? 0
        if item.id == "index:spotlight" { purgeable = max(purgeable, snapshot.purgeableServices[CacheDeleteService.spotlightIndex] ?? 0) }
        if item.id == "assets:system" { purgeable = max(purgeable, snapshot.purgeableAssetsBytes ?? 0) }
        return bytes > purgeable ? bytes - purgeable : 0
    }

    /// What the measured items hold that macOS may delete by itself: not counted.
    static func purgeableExcluded(_ snapshot: SystemDataSnapshot) -> UInt64 {
        measured(snapshot.report).map { ($0.bytes ?? 0) - counted($0, snapshot) }.reduce(0, +)
    }

    /// System Data as System Settings counts it: everything measured, without what macOS may delete by itself.
    static func total(_ snapshot: SystemDataSnapshot) -> UInt64 {
        blocks(snapshot).map(\.bytes).reduce(0, +)
    }

    static func usage(_ snapshot: SystemDataSnapshot) -> UsageBar {
        let items = measured(snapshot.report)
        var segments: [UsageSegment] = []
        for (index, group) in groups.enumerated() {
            let bytes = items.filter { group.kinds.contains($0.kind) }.map { counted($0, snapshot) }.reduce(0, +)
            if bytes > 0 { segments.append(UsageSegment(id: group.id, label: group.title, bytes: bytes, tone: .series(index))) }
        }
        let clones = snapshot.report.items.filter { $0.kind == .codeSignClone }.compactMap(\.bytes).reduce(0, +)
        var footnote = "Measured on this Mac's Data volume, and a prepared macOS update on its Preboot volume."
        let excluded = purgeableExcluded(snapshot)
        if excluded >= worthARow { footnote += " \(ByteFormat.string(excluded)) that macOS deletes by itself when space runs low is not counted: System Settings counts it as free space." }
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
        let total = total(snapshot)
        return Tile(title: total > 0 ? "system data \(ByteFormat.string(total))" : "system data",
                    status: freeable >= worthARow ? "\(ByteFormat.string(freeable)) can be freed" : "nothing to free",
                    needsAttention: partialBanner(snapshot) != nil, graphic: .blocks(blocks(snapshot)),
                    reclaimableBytes: freeable >= worthARow ? freeable : nil,
                    purgeableByService: [CacheDeleteService.mobileAsset: snapshot.purgeableAssetsBytes ?? 0])
    }

    /// What fills System Data as blocks, largest first, with what can be freed split out as its own block in the caution tone (what
    /// Clean frees taken out of the caches it mostly comes from, the version history out of its own block, so the total stays the same).
    static func blocks(_ snapshot: SystemDataSnapshot) -> [UsageSegment] {
        var segments = usage(snapshot).segments
        // Each part of what can be freed comes out of the block that holds it. The unused system assets are not in System Data at all
        // (macOS may purge them by itself), so they are not drawn.
        var freeable: UInt64 = 0
        func take(_ bytes: UInt64, from id: String) {
            guard bytes > 0, let index = segments.firstIndex(where: { $0.id == id }) else { return }
            let taken = min(bytes, segments[index].bytes)
            segments[index].bytes -= taken
            freeable += taken
            if segments[index].bytes == 0 { segments.remove(at: index) }
        }
        let caches = snapshot.report.items.filter { $0.cleanup.kind == .deleteWhenNotRunning && !$0.inUse }.compactMap(\.expectedReclaimBytes).reduce(0, +)
        take(caches, from: "caches")
        take(snapshot.reports.totalBytes, from: "macos")
        take(versionHistoryBytes(snapshot), from: "versions")
        if freeable >= worthARow { segments.append(UsageSegment(id: "freeable", label: "Can be freed", bytes: freeable, tone: .caution)) }
        return segments.sorted { $0.bytes > $1.bytes }
    }

    /// The page: the bar, one Clean for everything safe, then only what the user can act on. What MacSpace leaves alone is listed once,
    /// collapsed, so the total still adds up.
    /// Under the bar: what can be cleaned, in its own section and item by item (Free now, then leftover update files); then one row
    /// per list of what MacSpace leaves alone (downloads, app data, everything else) with how many items it holds and their total,
    /// opening a page of its own with every item. A list of one is that item's row.
    static func screen(_ snapshot: SystemDataSnapshot) -> Screen {
        var widgets: [ScreenWidget] = []
        if let banner = partialBanner(snapshot) { widgets.append(banner) }
        if let free = freeNow(snapshot) { widgets.append(free) }
        if let leftover = leftoverUpdateSection(snapshot) { widgets.append(leftover) }
        let groups = [
            group(assetsSection(snapshot), symbol: "square.stack.3d.down.right",
                  total: snapshot.assetFamilies.filter { !$0.steps.isEmpty && $0.bytes >= 100_000_000 }.map(\.bytes).reduce(0, +)),
            group(appDataSection(snapshot), symbol: "app.badge", total: leftAlone(snapshot).filter { appDataKinds.contains($0.kind) }.map { counted($0, snapshot) }.reduce(0, +)),
            group(otherSection(snapshot), symbol: "gearshape.2", total: leftAlone(snapshot).filter { !appDataKinds.contains($0.kind) }.map { counted($0, snapshot) }.reduce(0, +)),
        ].compactMap { $0 }
        // A prepared macOS update first, on its own: it is not something MacSpace leaves alone among the rest.
        let rows = pendingUpdateRows(snapshot) + groups
        if !rows.isEmpty { widgets.append(.list(ListWidget(id: "groups", title: "What is in it", rows: rows))) }
        // The bar says only what makes its total differ from what was measured: purgeable space left out, as System Settings does.
        let excluded = purgeableExcluded(snapshot)
        let hero = UsageBar(id: "usage", title: "What fills System Data", segments: blocks(snapshot),
                            footnote: excluded >= worthARow ? "Not counted: \(ByteFormat.string(excluded)) macOS deletes by itself when space runs low, which System Settings counts as free space." : nil)
        return Screen(title: "System Data", hero: hero, primary: cleanAll(snapshot), widgets: widgets)
    }

    /// A section of rows as one group row (named after the section, its description as the tooltip), or its only row.
    static func group(_ widget: ScreenWidget?, symbol: String, total: UInt64) -> Row? {
        guard case let .section(section)? = widget else { return nil }
        let rows = section.widgets.flatMap { inner -> [Row] in
            if case let .list(list) = inner { return list.rows }
            return []
        }
        guard !rows.isEmpty else { return nil }
        if rows.count == 1 { return rows[0] }
        return Row.group(id: "group:\(section.id)", title: section.title, symbol: symbol, totalBytes: total, rows: rows, detail: section.subtitle)
    }



    static func cleanAll(_ snapshot: SystemDataSnapshot) -> Action? {
        let total = cleanBytes(snapshot)
        guard total >= worthARow else { return nil }
        var message = "Deletes caches, old reports and unused system assets. macOS recreates what it needs."
        if versionsRow(snapshot) != nil { message += " Version history stays." }
        return Action(id: "cleanAll", title: "Free \(ByteFormat.string(total))", symbol: "sparkles", role: .prominent,
                      confirmation: Confirmation(title: "Free \(ByteFormat.string(total))?", message: message, confirmTitle: "Free"))
    }

    // MARK: Sections

    /// What Clean deletes, item by item, then document version history, which only its own button deletes. nil when there is nothing
    /// worth a row.
    static func freeNow(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        // The caches of an app that is open are not freeable now, so they are not listed: they come back once it quits.
        let cleanable = snapshot.report.items.filter { $0.cleanup.kind == .deleteWhenNotRunning && !$0.inUse && ($0.expectedReclaimBytes ?? 0) >= worthARow }
            .sorted { ($0.expectedReclaimBytes ?? 0) > ($1.expectedReclaimBytes ?? 0) }
        var rows = cleanable.map { item -> Row in
            Row(id: item.id, title: item.title, trailing: ByteFormat.string(item.expectedReclaimBytes ?? 0), symbol: "internaldrive",
                detail: item.cleanup.description, actions: [Action(id: "clean", title: "Free", parameters: ["id": item.id])])
        }
        if snapshot.reports.totalBytes >= worthARow {
            rows.append(Row(id: "reports", title: "Old diagnostic and crash reports", trailing: ByteFormat.string(snapshot.reports.totalBytes), symbol: "doc.text",
                            detail: "\(snapshot.reports.candidates.count) report(s) older than \(snapshot.reports.olderThanDays) days. Nothing reads them back.",
                            actions: [Action(id: "cleanReports", title: "Free", confirmation: Confirmation(
                                title: "Delete old reports?", message: "This permanently deletes \(snapshot.reports.candidates.count) report file(s).", confirmTitle: "Delete"))]))
        }
        if let assets = snapshot.purgeableAssetsBytes, assets >= assetsThreshold {
            // While macOS is being asked again in the background, the row says so instead of offering the button.
            rows.append(Row(id: "assets", title: "Unused system assets", trailing: ByteFormat.string(assets),
                            badge: snapshot.assetsRetrying ? Badge("Freeing in the background", tone: .caution) : nil, symbol: "square.stack.3d.down.right",
                            detail: "Downloads macOS no longer needs, such as Apple Intelligence models released by the off-switch. macOS deletes them only when the disk is nearly full; this does it now. Anything needed again is downloaded again.",
                            actions: snapshot.assetsRetrying ? [] : [Action(id: "purgeAssets", title: "Free", confirmation: Confirmation(
                                title: "Free up to \(ByteFormat.string(assets)) of unused system assets?", message: "macOS deletes the assets it no longer needs. If it keeps some for now, MacSpace asks it again in the background.", confirmTitle: "Free"))]))
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
            guard item.kind != .pendingUpdate, counted(item, snapshot) >= manualThreshold, !handled.contains(item.id), !item.id.hasPrefix("small:") else { return false }
            switch item.cleanup.kind {
            case .review: return !countedByAnotherCategory(item)
            case .managedByMacOS, .command: return item.kind != .codeSignClone && !countedElsewhere.contains(item.kind)
            default: return false
            }
        }
        .sorted { counted($0, snapshot) > counted($1, snapshot) }
    }

    /// A macOS update downloaded and prepared, waiting for a restart: its own row, apart from what MacSpace leaves alone.
    static func pendingUpdateRows(_ snapshot: SystemDataSnapshot) -> [Row] {
        snapshot.report.items.filter { $0.kind == .pendingUpdate && ($0.bytes ?? 0) > 0 }.map { item in
            Row(id: item.id, title: item.title, subtitle: "installs at the next restart", trailing: ByteFormat.string(item.bytes ?? 0),
                symbol: "arrow.down.circle", detail: ([item.cleanup.description] + item.notes).joined(separator: " "),
                actions: [Action(id: "openSoftwareUpdate", title: "Open")])
        }
    }

    /// What apps keep for themselves (their support folders and containers), listed apart from the rest MacSpace leaves alone.
    static let appDataKinds: Set<SystemDataKind> = [.appSupport, .appContainer]

    static func appDataSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        let items = leftAlone(snapshot).filter { appDataKinds.contains($0.kind) }
        guard !items.isEmpty else { return nil }
        return .section(SectionWidget(id: "appdata", title: "App data", subtitle: "Kept by apps for themselves. MacSpace leaves it alone.",
                                      widgets: [.list(ListWidget(id: "appdata-list", rows: leftAloneRows(items, snapshot)))]))
    }

    static func otherSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        let items = leftAlone(snapshot).filter { !appDataKinds.contains($0.kind) }
        guard !items.isEmpty else { return nil }
        return .section(SectionWidget(id: "other", title: "Everything else", subtitle: "Used by macOS and your tools. MacSpace leaves it alone.",
                                      widgets: [.list(ListWidget(id: "other-list", rows: leftAloneRows(items, snapshot)))]))
    }

    /// Every item, largest first, with what it is and why it stays. A container's kind goes under its name: the group already says
    /// it is app data.
    private static func leftAloneRows(_ items: [SystemDataItem], _ snapshot: SystemDataSnapshot) -> [Row] {
        items.map { item in
            var title = item.title
            var subtitle: String?
            for prefix in ["App container: ", "App group data: "] where title.hasPrefix(prefix) {
                subtitle = String(prefix.dropLast(2))
                title = String(title.dropFirst(prefix.count))
            }
            let counted = counted(item, snapshot)
            let excluded = (item.bytes ?? 0) - counted
            let purgeableNote = excluded >= worthARow ? ["\(ByteFormat.string(excluded)) more in it macOS deletes by itself when space runs low, not counted."] : []
            return Row(id: item.id, title: title, subtitle: subtitle, trailing: ByteFormat.string(counted),
                       detail: ([item.cleanup.description] + item.notes + purgeableNote).joined(separator: " "))
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
                                                                  message: "About \(size) from an update that is already installed. macOS downloads it again if it is ever needed.",
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
                                                                  message: "Removes the earlier versions of every document (\(size)); you can no longer revert to them. The documents stay. Save and close them first.",
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
        let rootOnly = paths.filter(RootMeasuredLocations.isAllowed)
        let other = paths.filter { !RootMeasuredLocations.isAllowed($0) }
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
