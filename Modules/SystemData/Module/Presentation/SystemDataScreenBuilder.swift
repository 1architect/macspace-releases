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
        Group(id: "versions", title: loc("Document versions"), kinds: [.documentVersions]),
        Group(id: "appdata", title: loc("Apple app data"), kinds: [.appContainer]),
        Group(id: "cloud", title: loc("Cloud files on this Mac"), kinds: [.cloudStorage]),
        Group(id: "caches", title: loc("Caches"), kinds: [.appCache, .userSystemCache, .toolCache]),
        Group(id: "support", title: loc("App support files"), kinds: [.appSupport]),
        Group(id: "leftovers", title: loc("Leftovers"), kinds: [.orphanedHome, .trash, .stagedUpdate]),
        Group(id: "developer", title: loc("Homebrew & packages"), kinds: [.packageManager]),
        Group(id: "shared", title: loc("Shared app files"), kinds: [.sharedAppFiles]),
        Group(id: "macos", title: loc("Managed by macOS"),
              kinds: [.logs, .symbolCache, .spotlightIndex, .spotlightMetadata, .systemAssets, .snapshot, .diagnosticReports, .systemLibrary]),
    ]

    /// Kinds System Settings lists in other categories: the Command Line Tools under Developer (1.42 GB there against 1.31-1.41 GB
    /// measured), swap, which sits on the VM volume, and a prepared macOS update, on the Preboot volume, which Settings counts under
    /// macOS: its macOS figure is every volume but the Data volume (System 18.58 + Preboot 21.94 with the update + Recovery 3.04 =
    /// 43.56 GB, against 47.45 GB there, 2026-10-06), and leaving the update in System Data put it 10.7 GB above Settings.
    static let countedElsewhere: Set<SystemDataKind> = [.developerTools, .virtualMemory, .pendingUpdate]

    /// Whether System Settings files the item under another category: cloud copies, unfinished downloads, restore images and virtual
    /// machines under Documents, and third-party apps' containers under Applications. Measured on 26B5091g: Documents 6.7 GB ≈
    /// Documents + Desktop + Downloads + cloud copies; Applications 28.48 GB = 19.04 GB of bundles + about 9.4 GB of app data; a 25 GB
    /// restore image in Downloads showed up in System Data until Spotlight indexed it, then moved to Documents (+21.91 GB there, −21.91 GB
    /// in System Data, used space unchanged). Apple's own containers stay in System Data.
    static func countedByAnotherCategory(_ item: SystemDataItem) -> Bool {
        switch item.kind {
        case .partialDownload, .restoreImage, .virtualMachine: return true
        case .appContainer where item.cleanup.kind == .review: return true
        default:
            // All of it in a place another category claims (`SystemDataItem.elsewhereBytes`).
            guard let elsewhere = item.elsewhereBytes, let bytes = item.bytes else { return false }
            return elsewhere >= bytes
        }
    }

    /// Items that count toward the bar. Code-signing clones share storage with their apps, so they are left out.
    static func measured(_ report: SystemDataReport) -> [SystemDataItem] {
        report.items.filter { $0.kind != .codeSignClone && !countedElsewhere.contains($0.kind) && !countedByAnotherCategory($0) && ($0.bytes ?? 0) > 0 }
    }

    /// What an item adds to System Data: its size without what macOS may delete by itself, which System Settings counts as free
    /// space. Files flagged purgeable are measured with the item; the Spotlight index and the system assets are purged by services of
    /// their own, whose figures are taken off them.
    /// The apps inside it are not counted either: System Settings lists them under Applications.
    static func counted(_ item: SystemDataItem, _ snapshot: SystemDataSnapshot) -> UInt64 {
        let bytes = item.bytes ?? 0
        let out = purgeable(item, snapshot) + (item.elsewhereBytes ?? 0)
        return bytes > out ? bytes - out : 0
    }

    /// What an item holds that macOS may delete by itself.
    static func purgeable(_ item: SystemDataItem, _ snapshot: SystemDataSnapshot) -> UInt64 {
        var purgeable = item.purgeableBytes ?? 0
        if item.id == "index:spotlight" { purgeable = max(purgeable, snapshot.purgeableServices[CacheDeleteService.spotlightIndex] ?? 0) }
        if item.id == "assets:system" { purgeable = max(purgeable, snapshot.purgeableAssetsBytes ?? 0) }
        return min(purgeable, item.bytes ?? 0)
    }

    /// What the measured items hold that macOS may delete by itself: not counted.
    static func purgeableExcluded(_ snapshot: SystemDataSnapshot) -> UInt64 {
        measured(snapshot.report).map { purgeable($0, snapshot) }.reduce(0, +)
    }

    /// What the measured items hold that System Settings lists in another category (apps, developer files…): not counted.
    static func appsExcluded(_ snapshot: SystemDataSnapshot) -> UInt64 {
        measured(snapshot.report).compactMap(\.elsewhereBytes).reduce(0, +)
    }

    /// System Data as System Settings counts it: what is left of the used space once macOS and every other category are taken off
    /// (`SettingsStorage`). Without that reading, what the items add up to.
    static func total(_ snapshot: SystemDataSnapshot) -> UInt64 {
        snapshot.settings?.systemData ?? blocks(snapshot).map(\.bytes).reduce(0, +)
    }

    /// What System Settings counts in System Data beyond every folder MacSpace lists: files only macOS can read (the system's
    /// protected stores, other apps' sealed data), the file system's own records, and what changed between the two readings.
    static func notIdentified(_ snapshot: SystemDataSnapshot) -> UInt64 {
        guard let settings = snapshot.settings else { return 0 }
        let listed = measured(snapshot.report).map { counted($0, snapshot) }.reduce(0, +)
        return settings.systemData > listed ? settings.systemData - listed : 0
    }

    static func usage(_ snapshot: SystemDataSnapshot) -> UsageBar {
        let items = measured(snapshot.report)
        var segments: [UsageSegment] = []
        for (index, group) in groups.enumerated() {
            let bytes = items.filter { group.kinds.contains($0.kind) }.map { counted($0, snapshot) }.reduce(0, +)
            if bytes > 0 { segments.append(UsageSegment(id: group.id, label: group.title, bytes: bytes, tone: .series(index))) }
        }
        let clones = snapshot.report.items.filter { $0.kind == .codeSignClone }.compactMap(\.bytes).reduce(0, +)
        var footnote = "Measured on this Mac's Data volume."
        let excluded = purgeableExcluded(snapshot)
        if excluded >= worthARow { footnote += " \(ByteFormat.string(excluded)) that macOS deletes by itself when space runs low is not counted: System Settings counts it as free space." }
        let apps = appsExcluded(snapshot)
        if apps >= worthARow { footnote += " \(ByteFormat.string(apps)) of apps inside these folders are not counted: System Settings lists them under Applications." }
        if clones > 0 { footnote += " \(ByteFormat.string(clones)) of code-signing copies share space with their apps and are not counted." }
        let elsewhere = snapshot.report.items.filter { countedElsewhere.contains($0.kind) }.compactMap(\.bytes).reduce(0, +)
        let otherCategory = snapshot.report.items.filter(countedByAnotherCategory).compactMap(\.bytes).reduce(0, +)
        if otherCategory > 0 { footnote += " \(ByteFormat.string(otherCategory)) of cloud copies, downloads, virtual machines and apps' own data are not counted: System Settings lists them under Documents and Applications." }
        if elsewhere > 0 { footnote += " \(ByteFormat.string(elsewhere)) of developer tools and swap are not counted: System Settings lists them under Developer and macOS." }
        let skipped = quietlySkipped(snapshot)
        if skipped > 0 { footnote += skipped == 1 ? " 1 place macOS keeps private was skipped." : " \(skipped) places macOS keeps private were skipped." }
        return UsageBar(id: "usage", title: loc("What fills System Data"), segments: segments, footnote: footnote)
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
        return Tile(title: total > 0 ? loc("system data \(ByteFormat.string(total))") : loc("system data"),
                    status: freeable >= worthARow ? loc("free \(ByteFormat.string(freeable))") : loc("nothing to free"),
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
        if freeable >= worthARow { segments.append(UsageSegment(id: "freeable", label: loc("Can be freed"), bytes: freeable, tone: .caution)) }
        // The blocks add up to System Settings' figure: what no listed folder accounts for is a block of its own.
        let unknown = notIdentified(snapshot)
        if unknown >= worthARow { segments.append(UsageSegment(id: "unidentified", label: loc("Not identified"), bytes: unknown, tone: .neutral)) }
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
        let rows = groups
        if !rows.isEmpty { widgets.append(.list(ListWidget(id: "groups", title: loc("What is in it"), rows: rows))) }
        let blocks = blocks(snapshot)
        let hero = UsageBar(id: "usage", title: loc("What fills System Data"), totalBytes: snapshot.settings.map { _ in total(snapshot) }, segments: blocks)
        return Screen(title: loc("System Data"), hero: hero, primary: cleanAll(snapshot), widgets: widgets)
    }

    /// A section of rows as one group row (named after the section, its description behind the (i)), or its only row.
    static func group(_ widget: ScreenWidget?, symbol: String, total: UInt64) -> Row? {
        guard case let .section(section)? = widget else { return nil }
        let rows = section.widgets.flatMap { inner -> [Row] in
            if case let .list(list) = inner { return list.rows }
            return []
        }
        guard !rows.isEmpty else { return nil }
        if rows.count == 1 { return rows[0] }
        var group = Row.group(id: "group:\(section.id)", title: section.title, symbol: symbol, totalBytes: total, rows: rows, detail: section.subtitle)
        // The items, not the categories they are sorted into (Everything else).
        let count = rows.map { max($0.children.count, 1) }.reduce(0, +)
        group.subtitle = count == 1 ? loc("1 item") : loc("\(count) items")
        return group
    }



    static func cleanAll(_ snapshot: SystemDataSnapshot) -> Action? {
        let total = cleanBytes(snapshot)
        guard total >= worthARow else { return nil }
        var message = loc("Deletes caches, old reports and unused system assets.")
        if versionsRow(snapshot) != nil { message += " " + loc("Version history stays.") }
        return Action(id: "cleanAll", title: loc("Free \(ByteFormat.string(total))"), symbol: "sparkles", role: .prominent,
                      confirmation: Confirmation(title: loc("Free \(ByteFormat.string(total))?"), message: message, confirmTitle: loc("Free")))
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
                detail: item.cleanup.description, actions: [Action(id: "clean", title: loc("Free"), parameters: ["id": item.id])])
        }
        if snapshot.reports.totalBytes >= worthARow {
            rows.append(Row(id: "reports", title: loc("Old diagnostic and crash reports"), trailing: ByteFormat.string(snapshot.reports.totalBytes), symbol: "doc.text",
                            detail: loc("\(reportCount(snapshot)) older than \(snapshot.reports.olderThanDays) days."),
                            actions: [Action(id: "cleanReports", title: loc("Free"), confirmation: Confirmation(
                                title: loc("Delete old reports?"), message: loc("This permanently deletes \(reportCount(snapshot))."), confirmTitle: loc("Delete")))]))
        }
        if let assets = snapshot.purgeableAssetsBytes, assets >= assetsThreshold {
            // While macOS is being asked again in the background, the row says so instead of offering the button.
            rows.append(Row(id: "assets", title: loc("Unused system assets"), trailing: ByteFormat.string(assets),
                            badge: snapshot.assetsRetrying ? Badge(loc("Freeing in the background"), tone: .caution) : nil, symbol: "square.stack.3d.down.right",
                            detail: loc("Downloads macOS no longer needs, like released Apple Intelligence models."),
                            actions: snapshot.assetsRetrying ? [] : [Action(id: "purgeAssets", title: loc("Free"), confirmation: Confirmation(
                                title: loc("Free up to \(ByteFormat.string(assets)) of unused system assets?"), message: loc("macOS downloads them again if they're needed."), confirmTitle: loc("Free")))]))
        }
        if let versions = versionsRow(snapshot) { rows.append(versions) }
        guard !rows.isEmpty else { return nil }
        return .section(SectionWidget(id: "free", title: loc("Free now"), widgets: [.list(ListWidget(id: "free-list", rows: rows))]))
    }

    static let manualThreshold: UInt64 = 50_000_000

    static func reportCount(_ snapshot: SystemDataSnapshot) -> String {
        snapshot.reports.candidates.count == 1 ? loc("1 report") : loc("\(snapshot.reports.candidates.count) reports")
    }

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

    /// What apps keep for themselves (their support folders and containers), listed apart from the rest MacSpace leaves alone.
    static let appDataKinds: Set<SystemDataKind> = [.appSupport, .appContainer]

    static func appDataSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        let items = leftAlone(snapshot).filter { appDataKinds.contains($0.kind) }
        guard !items.isEmpty else { return nil }
        return .section(SectionWidget(id: "appdata", title: loc("App data"),
                                      widgets: [.list(ListWidget(id: "appdata-list", rows: leftAloneRows(items, snapshot)))]))
    }

    /// The rest of what MacSpace leaves alone, sorted into the bar's categories (caches, cloud files, leftovers…), largest first: a
    /// category of several items is a group with a page of its own, a category of one is that item's row.
    static func otherSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        let items = leftAlone(snapshot).filter { !appDataKinds.contains($0.kind) }
        guard !items.isEmpty else { return nil }
        var categories: [(category: OtherCategory, items: [SystemDataItem])] = []
        for item in items {
            let category = OtherCategory.of(item.kind)
            if let index = categories.firstIndex(where: { $0.category.id == category.id }) {
                categories[index].items.append(item)
            } else {
                categories.append((category, [item]))
            }
        }
        let rows = categories
            .map { entry -> (row: Row, bytes: UInt64) in
                let bytes = entry.items.map { counted($0, snapshot) }.reduce(0, +)
                let rows = leftAloneRows(entry.items, snapshot)
                if rows.count == 1 { return (rows[0], bytes) }
                return (Row.group(id: "other:\(entry.category.id)", title: entry.category.title, totalBytes: bytes, rows: rows), bytes)
            }
            .sorted { $0.bytes > $1.bytes }
            .map(\.row)
        return .section(SectionWidget(id: "other", title: loc("Everything else"), widgets: [.list(ListWidget(id: "other-list", rows: rows))]))
    }

    /// How Everything else is sorted: the bar's categories.
    struct OtherCategory {
        let id: String
        let title: String

        static let other = OtherCategory(id: "other", title: loc("Other"))

        /// The bar's category that holds this kind, or Other.
        static func of(_ kind: SystemDataKind) -> OtherCategory {
            groups.first { $0.kinds.contains(kind) }.map { OtherCategory(id: $0.id, title: $0.title) } ?? other
        }
    }

    /// Every item, largest first, with what the user can do about it when there is something. A container's kind goes under its name: the group already says
    /// it is app data.
    private static func leftAloneRows(_ items: [SystemDataItem], _ snapshot: SystemDataSnapshot) -> [Row] {
        items.map { item in
            var title = item.title
            var subtitle: String?
            // A container's name alone, and what kind it is in the note; read from its id and folder, not from its title, which is
            // in the user's language.
            if item.id.hasPrefix("container:") {
                title = String(item.id.dropFirst("container:".count))
                subtitle = item.paths.contains { $0.contains("/Group Containers/") } ? loc("App group data") : loc("App container")
            }
            // What macOS manages needs no explanation: only what the user can do something about has one.
            let detail = item.cleanup.kind == .managedByMacOS || item.cleanup.description.isEmpty ? nil : item.cleanup.description
            return Row(id: item.id, title: title, subtitle: subtitle, trailing: ByteFormat.string(counted(item, snapshot)), detail: detail)
        }
    }

    /// Files of an update that is already installed; shown only when the scan recognised them as a leftover (see the inspector).
    static func leftoverUpdateSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        guard let item = snapshot.report.items.first(where: { $0.id == "update:staged" && $0.kind == .stagedUpdate && $0.cleanup.kind == .managedByMacOS }),
              let bytes = item.bytes, bytes > 0 else { return nil }
        let size = ByteFormat.string(bytes)
        let row = Row(id: "leftover-update", title: loc("Leftover macOS update files"),
                      trailing: size, symbol: "arrow.down.app",
                      detail: loc("From an update that's already installed."),
                      actions: [Action(id: "deleteStagedUpdate", title: loc("Delete"), role: .destructive,
                                       confirmation: Confirmation(title: loc("Delete the leftover update files?"),
                                                                  message: loc("About \(size) from an update that's already installed."),
                                                                  confirmTitle: loc("Delete")),
                                       requires: [.privilegedHelper])])
        return .section(SectionWidget(id: "leftover-update", title: loc("Leftover update files"),
                                      widgets: [.list(ListWidget(id: "leftover-update-list", rows: [row]))]))
    }

    /// The saved history behind File > Revert To > Browse All Versions, as a row of Free now. Deleting it is irreversible, so it keeps
    /// its badge and its own confirmation, and Clean leaves it out.
    static func versionsRow(_ snapshot: SystemDataSnapshot) -> Row? {
        guard let item = snapshot.report.items.first(where: { $0.id == "versions:documents" }), let bytes = item.bytes, bytes >= manualThreshold else { return nil }
        let size = ByteFormat.string(bytes)
        return Row(id: "versions", title: loc("Document version history"),
                      trailing: size, badge: Badge(loc("Cannot be undone"), tone: .critical), symbol: "clock.arrow.circlepath",
                      detail: loc("Earlier versions of your documents (File > Revert To). The documents themselves stay."),
                      actions: [Action(id: "deleteVersions", title: loc("Delete…"), role: .destructive,
                                       confirmation: Confirmation(title: loc("Delete all version history?"),
                                                                  message: loc("You won't be able to revert any document to an earlier version. Save and close your documents first."),
                                                                  confirmTitle: loc("Delete version history")),
                                       requires: [.privilegedHelper])])
    }

    /// System downloads the user can release by changing a setting. Families with no setting are not something to act on, so they
    /// are not listed.
    static func assetsSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        let families = snapshot.assetFamilies.filter { !$0.steps.isEmpty && $0.bytes >= 100_000_000 }
        guard !families.isEmpty else { return nil }
        let rows = families.map { family -> Row in
            Row(id: "assets:\(family.id)", title: family.title, trailing: ByteFormat.string(family.bytes),
                symbol: "square.stack.3d.down.right", steps: family.steps)
        }
        return .section(SectionWidget(id: "assets", title: loc("Downloads you can turn off"),
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
            return .banner(Banner(id: "partial", severity: .info, title: loc("Allow Full Disk Access to see everything"),
                                  message: loc("\(actionable.fullDiskAccess.count) places couldn't be measured."),
                                  action: Action(id: "openFullDiskAccess", title: loc("Allow"), role: .prominent)))
        }
        if !actionable.helper.isEmpty {
            return .banner(Banner(id: "partial", severity: .info, title: loc("Turn on the helper to see everything"),
                                  message: loc("\(actionable.helper.count) places only the helper can measure: \(unreadableList(actionable.helper)). Turn it on in Settings.")))
        }
        if !actionable.helperUnreachable.isEmpty {
            return .banner(Banner(id: "partial", severity: .warning, title: loc("The helper did not answer"),
                                  message: loc("\(actionable.helperUnreachable.count) places weren't measured. Reopen MacSpace.")))
        }
        return nil
    }

    /// Up to four locations, home folder shortened, so the user can see what is missing.
    static func unreadableList(_ paths: [String]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = paths.prefix(4).map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
        return shown.joined(separator: ", ") + (paths.count > 4 ? " " + loc("and \(paths.count - 4) more") : "")
    }

    static let assetsThreshold: UInt64 = 50_000_000
}
