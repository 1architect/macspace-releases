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
        Group(id: "caches", title: loc("Other caches"), kinds: [.appCache, .userSystemCache, .toolCache]),
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
        // macOS's purge of app container caches names no container: each gets the service's share of its own caches folder.
        if item.kind == .appContainer, let caches = item.cachesBytes, snapshot.report.containerCachesBytes > 0,
           let service = snapshot.purgeableServices[CacheDeleteService.appContainerCaches] {
            let share = min(1, Double(service) / Double(snapshot.report.containerCachesBytes))
            purgeable = max(purgeable, UInt64(Double(caches) * share))
        }
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

    /// Whether everything MacSpace can measure was measured, so the remainder is what macOS keeps closed to every app: Full Disk
    /// Access granted, the helper's places read, and protected folders found. Otherwise it also holds unmeasured places and stays
    /// "Not identified", with nothing to list.
    static func isProtected(_ snapshot: SystemDataSnapshot) -> Bool {
        snapshot.report.fullDiskAccess && !snapshot.report.protectedFolders.isEmpty && partialBanner(snapshot) == nil
    }

    /// The remainder's page, measured on 26B5101f (2026-10-12): 68 folders no app can open, even with Full Disk Access and as root,
    /// among them Apple Intelligence's model families in `/System/Library/AssetsV2`; with the helper's places measured, about 7 GB
    /// on the development Mac. Their sizes cannot be read, so the rows name them and the block carries the measured total.
    /// The system asset families among the protected folders (Apple Intelligence's models among them): in the folder the "System assets"
    /// item measures, but not in its figure, since they cannot be opened.
    static func protectedAssetFamilies(_ snapshot: SystemDataSnapshot) -> [String] {
        let root = SystemDataLocations.defaultSystemPaths["systemAssets"].map { $0 + "/" } ?? "/System/Library/AssetsV2/"
        return snapshot.report.protectedFolders.filter { $0.hasPrefix(root) }
    }

    static func protectedRows(_ snapshot: SystemDataSnapshot) -> [Row] {
        guard isProtected(snapshot) else { return [] }
        let folders = snapshot.report.protectedFolders
        let assetsRoot = SystemDataLocations.defaultSystemPaths["systemAssets"].map { $0 + "/" } ?? "/System/Library/AssetsV2/"
        let databasesRoot = SystemDataLocations.defaultSystemPaths["systemDatabases"].map { $0 + "/" } ?? "/private/var/db/"
        let assets = protectedAssetFamilies(snapshot)
        let databases = folders.filter { $0.hasPrefix(databasesRoot) }
        let others = folders.filter { !$0.hasPrefix(assetsRoot) && !$0.hasPrefix(databasesRoot) }
        func count(_ paths: [String]) -> String { paths.count == 1 ? loc("1 item") : loc("\(paths.count) items") }
        var rows: [Row] = []
        if !assets.isEmpty {
            // While Apple Intelligence is on, its models stay (`SystemAssetGuard`), which is why they are on disk at all.
            rows.append(Row(id: "protected:assets", title: loc("Models and system assets"), subtitle: count(assets),
                            badge: snapshot.assetsHeld ? Badge(loc("Kept while Apple Intelligence is on")) : nil,
                            detail: loc("macOS keeps these locked, even from MacSpace.")))
        }
        if !databases.isEmpty {
            rows.append(Row(id: "protected:databases", title: loc("System databases"), subtitle: count(databases),
                            detail: loc("macOS keeps these locked, even from MacSpace.")))
        }
        if !others.isEmpty {
            rows.append(Row(id: "protected:other", title: loc("Other protected folders"), subtitle: count(others),
                            detail: loc("macOS keeps these locked, even from MacSpace.")))
        }
        rows.append(Row(id: "protected:filesystem", title: loc("File system metadata"),
                        detail: loc("What the disk records about each file.")))
        return rows
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

    /// Bytes the main Free button frees: the caches chosen on the caches page (`CachesPage.chosen`), old reports and unused system
    /// assets. Caches of apps that are open are left out: they cannot be freed until the app quits.
    static func cleanBytes(_ snapshot: SystemDataSnapshot) -> UInt64 {
        // The system assets stay while Apple Intelligence is on (`SystemAssetGuard`).
        CachesPage.chosenBytes(snapshot) + (snapshot.assetsHeld ? 0 : snapshot.purgeableAssetsBytes ?? 0) + snapshot.reports.totalBytes
    }

    /// Document version history when it is offered under Free now (its own Delete button, not Clean).
    static func versionHistoryBytes(_ snapshot: SystemDataSnapshot) -> UInt64 {
        guard versionsRow(snapshot) != nil else { return 0 }
        return snapshot.report.items.first { $0.id == "versions:documents" }?.bytes ?? 0
    }

    /// The system log when it is offered under Free now (its own button, and the page's main Free; never automatic cleaning).
    static func unifiedLogBytes(_ snapshot: SystemDataSnapshot) -> UInt64 {
        unifiedLogRow(snapshot)?.bytes ?? 0
    }

    /// The symbols for crash reports when they are offered under Free now (their own button, not Clean).
    static func symbolsBytes(_ snapshot: SystemDataSnapshot) -> UInt64 { symbolsRow(snapshot)?.bytes ?? 0 }

    /// Bytes MacSpace can free right now without the user doing anything in another app: what Clean frees, the version history, the
    /// system log and the symbols for crash reports. This is the tile's figure and its "can be freed" block.
    static func freeableBytes(_ snapshot: SystemDataSnapshot) -> UInt64 {
        cleanBytes(snapshot) + versionHistoryBytes(snapshot) + unifiedLogBytes(snapshot) + symbolsBytes(snapshot)
    }

    /// What a cleanup must reach to be worth a row: smaller amounts are noise.
    static let worthARow: UInt64 = 1_000_000

    static func tile(_ snapshot: SystemDataSnapshot) -> Tile {
        let freeable = freeableBytes(snapshot)
        let total = total(snapshot)
        return Tile(title: loc("system data"), figure: total > 0 ? ByteFormat.string(total) : nil,
                    status: freeable >= worthARow ? loc("free \(ByteFormat.string(freeable))") : loc("nothing to free"),
                    needsAttention: partialBanner(snapshot) != nil, graphic: .blocks(blocks(snapshot)),
                    reclaimableBytes: freeable >= worthARow ? freeable : nil,
                    purgeableByService: [CacheDeleteService.mobileAsset: snapshot.purgeableAssetsBytes ?? 0])
    }

    /// What fills System Data as blocks, largest first, with what can be freed split out as its own block in the caution tone (every
    /// cache of the caches page taken out of the block of the folder that holds it, the version history out of its own block, so the
    /// total stays the same).
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
        for (id, bytes) in CachesPage.claimed(snapshot, wholeItems: false) {
            if let block = blockID(of: id, snapshot) { take(bytes, from: block) }
        }
        take(snapshot.reports.totalBytes, from: "macos")
        take(versionHistoryBytes(snapshot), from: "versions")
        take(unifiedLogBytes(snapshot), from: "macos")
        take(symbolsBytes(snapshot), from: "macos")
        if freeable >= worthARow { segments.append(UsageSegment(id: "freeable", label: loc("Can be freed"), bytes: freeable, tone: .caution)) }
        // The blocks add up to System Settings' figure: what no listed folder accounts for is a block of its own.
        let unknown = notIdentified(snapshot)
        if unknown >= worthARow {
            segments.append(UsageSegment(id: "unidentified", label: isProtected(snapshot) ? loc("Protected by macOS") : loc("Not identified"), bytes: unknown, tone: .neutral))
        }
        return segments.sorted { $0.bytes > $1.bytes }
    }

    /// The page's blocks, each with the items it is made of, so a click on it opens a page of them (`UsageSegment.items`). An item's
    /// size there is what it adds to its block: what Clean frees is in the "can be freed" block instead, whose page is the rows of
    /// Free now, buttons included. What no folder accounts for has no items and opens nothing. Not on the tile, which is saved.
    static func blocksWithItems(_ snapshot: SystemDataSnapshot) -> [UsageSegment] {
        let items = measured(snapshot.report)
        let freeRows: [Row] = {
            guard case let .section(section)? = freeNow(snapshot), case let .list(list)? = section.widgets.first else { return [] }
            // The unused system assets, the wallpaper downloads and the Trash are not in the blocks (`blocks`).
            return list.rows.filter { $0.id != "assets" && $0.id != "wallpaper-downloads" && $0.id != "trash" }
        }()
        let claimed = CachesPage.claimed(snapshot)
        return blocks(snapshot).map { segment in
            var segment = segment
            if segment.id == "freeable" {
                segment.items = freeRows
            } else if segment.id == "unidentified" {
                segment.items = protectedRows(snapshot)
            } else if let group = groups.first(where: { $0.id == segment.id }) {
                let all = items.filter { group.kinds.contains($0.kind) }.map { (item: $0, bytes: inBlock($0, snapshot, claimed: claimed)) }
                // The items too small to list are one "Smaller items" row, whatever kind they are.
                let small = all.filter { $0.item.id.hasPrefix("small:") }.map(\.bytes).reduce(0, +)
                let sized = all.filter { !$0.item.id.hasPrefix("small:") && $0.bytes >= worthARow }
                var rows = sized.map { entry -> (row: Row, bytes: UInt64) in
                    var row = itemRow(entry.item, bytes: entry.bytes)
                    // The families macOS keeps closed are in the same folder but in no figure of this row: say where they are.
                    let closed = protectedAssetFamilies(snapshot)
                    if entry.item.id == "assets:system", isProtected(snapshot), !closed.isEmpty {
                        let note = loc("\(closed.count) more, including Apple Intelligence models, are under Protected by macOS.")
                        row.detail = row.detail.map { $0 + " " + note } ?? note
                    }
                    return (row, entry.bytes)
                }
                if small >= worthARow {
                    rows.append((Row(id: "small:\(group.id)", title: loc("Smaller items"), trailing: ByteFormat.string(small)), small))
                }
                segment.items = rows.sorted { $0.bytes > $1.bytes }.map(\.row)
            }
            return segment
        }
    }

    /// The block of the item with this id (`groups`), nil when it is in none.
    static func blockID(of itemID: String, _ snapshot: SystemDataSnapshot) -> String? {
        guard let item = measured(snapshot.report).first(where: { $0.id == itemID }) else { return nil }
        return groups.first { $0.kinds.contains(item.kind) }?.id
    }

    /// What an item adds to its category's block: its counted size, less what `blocks` moved to the "can be freed" block, and less the
    /// caches of the caches page, which are listed there, not again here.
    static func inBlock(_ item: SystemDataItem, _ snapshot: SystemDataSnapshot, claimed: [String: UInt64]? = nil) -> UInt64 {
        let bytes = counted(item, snapshot)
        var freed = (claimed ?? CachesPage.claimed(snapshot))[item.id] ?? 0
        if item.id == "versions:documents" && versionsRow(snapshot) != nil { freed = bytes }
        if item.id == unifiedLogID, let log = unifiedLogRow(snapshot) { freed = min(bytes, log.bytes) }
        if item.id == symbolsID && symbolsRow(snapshot) != nil { freed = bytes }
        if item.id == "reports:diagnostic" { freed = snapshot.reports.totalBytes }
        return bytes > freed ? bytes - freed : 0
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
            group(appDataSection(snapshot), symbol: "app.badge", total: leftAlone(snapshot).filter { appDataKinds.contains($0.kind) }.map { listed($0, snapshot) }.reduce(0, +)),
            group(otherSection(snapshot), symbol: "gearshape.2", total: leftAlone(snapshot).filter { !appDataKinds.contains($0.kind) }.map { listed($0, snapshot) }.reduce(0, +)),
        ].compactMap { $0 }
        let rows = groups
        if !rows.isEmpty { widgets.append(.list(ListWidget(id: "groups", title: loc("What is in it"), rows: rows))) }
        let blocks = blocksWithItems(snapshot)
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



    /// The page's main Free: what automatic cleaning frees (`cleanBytes`), and the system log, which only a Free the user confirms
    /// erases (it cannot be undone).
    static func freeButtonBytes(_ snapshot: SystemDataSnapshot) -> UInt64 { cleanBytes(snapshot) + unifiedLogBytes(snapshot) }

    static func cleanAll(_ snapshot: SystemDataSnapshot) -> Action? {
        let total = freeButtonBytes(snapshot)
        guard total >= worthARow else { return nil }
        // The title says it all; the message only names the open apps whose chosen caches go with it, which quit (`CachesPage.quitNote`).
        let message = CachesPage.quitNote(CachesPage.chosen(snapshot)) ?? ""
        return Action(id: "cleanAll", title: loc("Free \(ByteFormat.string(total))"), symbol: "sparkles", role: .prominent,
                      confirmation: Confirmation(title: loc("Free \(ByteFormat.string(total))?"), message: message, confirmTitle: loc("Free")), workingTitle: loc("Freeing space"))
    }

    // MARK: Sections

    /// Everything that can be freed, largest first: the caches page (`CachesPage`), old reports, unused system assets, stalled
    /// wallpaper downloads, document version history, the system log, the symbols for crash reports and the Trash. nil when there is
    /// nothing worth a row.
    static func freeNow(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        var rows: [(row: Row, bytes: UInt64)] = []
        if let caches = CachesPage.row(snapshot) {
            rows.append((caches, CachesPage.entries(snapshot).map(\.bytes).reduce(0, +)))
        }
        if snapshot.reports.totalBytes >= worthARow {
            rows.append((Row(id: "reports", title: loc("Old diagnostic and crash reports"), trailing: ByteFormat.string(snapshot.reports.totalBytes), symbol: "doc.text",
                             detail: loc("\(reportCount(snapshot)) older than \(snapshot.reports.olderThanDays) days."),
                             actions: [Action(id: "cleanReports", title: loc("Free"), confirmation: Confirmation(
                                title: loc("Free old reports?"), message: loc("This permanently deletes \(reportCount(snapshot))."), confirmTitle: loc("Free")), workingTitle: loc("Freeing space"))],
                             paths: paths(of: "reports:diagnostic", snapshot)), snapshot.reports.totalBytes))
        }
        if let assets = snapshot.purgeableAssetsBytes, assets >= assetsThreshold {
            // While macOS is being asked again in the background, the row says so instead of offering the button; while Apple
            // Intelligence is on, that the assets stay (its models download and update through them).
            let badge: Badge? = snapshot.assetsHeld ? Badge(loc("Kept while Apple Intelligence is on"))
                : snapshot.assetsRetrying ? Badge(loc("Freeing in the background"), tone: .caution) : nil
            rows.append((Row(id: "assets", title: loc("Unused system assets"), trailing: ByteFormat.string(assets),
                             badge: badge, symbol: "square.stack.3d.down.right",
                             detail: loc("Downloads macOS no longer needs, like released Apple Intelligence models."),
                             actions: snapshot.assetsRetrying || snapshot.assetsHeld ? [] : [Action(id: "purgeAssets", title: loc("Free"), confirmation: Confirmation(
                                title: loc("Free up to \(ByteFormat.string(assets)) of unused system assets?"), message: loc("macOS downloads them again if they're needed."), confirmTitle: loc("Free")), workingTitle: loc("Freeing space"))],
                             paths: paths(of: "assets:system", snapshot)), assets))
        }
        if let downloads = wallpaperDownloadsRow(snapshot) { rows.append(downloads) }
        if let versions = versionsRow(snapshot) { rows.append(versions) }
        if let log = unifiedLogRow(snapshot) { rows.append(log) }
        if let symbols = symbolsRow(snapshot) { rows.append(symbols) }
        if let trash = trashRow(snapshot) { rows.append(trash) }
        guard !rows.isEmpty else { return nil }
        let sorted = rows.sorted { $0.bytes > $1.bytes }.map(\.row)
        return .section(SectionWidget(id: "free", title: loc("Free now"), widgets: [.list(ListWidget(id: "free-list", rows: sorted))]))
    }

    static let manualThreshold: UInt64 = 50_000_000

    /// The Trash: Free empties it, as the Finder's Empty Trash does; its folder pill (`Row.paths`) shows it in the Finder; and whether the Finder empties old
    /// items by itself. The Trash is a category of its own in System Settings, not System Data, so it is not in the page's figures, and
    /// never part of Clean or automatic cleaning: what is in it is the user's.
    static let trashPath = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")

    static func trashRow(_ snapshot: SystemDataSnapshot) -> (row: Row, bytes: UInt64)? {
        guard let bytes = snapshot.report.items.first(where: { $0.id == "trash:user" })?.bytes, bytes >= worthARow else { return nil }
        let empties = snapshot.trashEmptiesItself == true
        let size = ByteFormat.string(bytes)
        return (Row(id: "trash", title: loc("Trash"), trailing: size,
                    badges: [Badge(loc("Cannot be undone"), tone: .critical)] + (empties ? [Badge(loc("Empties after 30 days"))] : []),
                    detail: empties ? nil : loc("The Finder can delete items that have been in it for 30 days: Finder > Settings > Advanced."),
                    actions: [Action(id: "emptyTrash", title: loc("Free"), role: .destructive,
                                     confirmation: Confirmation(title: loc("Free \(size) in the Trash?"),
                                                                message: loc("Everything in the Trash is deleted for good."),
                                                                confirmTitle: loc("Free")), workingTitle: loc("Freeing space"))],
                    paths: [Self.trashPath]), bytes)
    }

    /// The unified log's item: what Console shows, and the format strings it is read with.
    static let unifiedLogID = "logs:unified"

    /// The system log, as a row of Free now with a button of its own: only the helper can erase it, with Apple's `log erase`, and the
    /// history macOS keeps for troubleshooting goes for good, so it keeps its pill and Clean leaves it out. Mole deletes its older
    /// files; macOS itself never frees it (logd tells its purge service there is nothing to free, at every urgency).
    /// Sized by what an erase frees: what grew past what the log kept at its last erase (`SystemLogFloor`).
    static func unifiedLogRow(_ snapshot: SystemDataSnapshot) -> (row: Row, bytes: UInt64)? {
        guard let item = snapshot.report.items.first(where: { $0.id == unifiedLogID }), let total = item.bytes else { return nil }
        let bytes = total > (snapshot.logFloor ?? 0) ? total - (snapshot.logFloor ?? 0) : 0
        guard bytes >= manualThreshold else { return nil }
        let size = ByteFormat.string(bytes)
        return (Row(id: "system-log", title: loc("System log"), trailing: size, badge: Badge(loc("Cannot be undone"), tone: .critical), symbol: "list.bullet.rectangle",
                    detail: loc("Erase Console records used for troubleshooting."),
                    actions: [Action(id: "eraseUnifiedLog", title: loc("Free"), role: .destructive,
                                     confirmation: Confirmation(title: loc("Free the system log?"),
                                                                message: loc("Console's history is deleted."),
                                                                confirmTitle: loc("Free")),
                                     requires: [.privilegedHelper], workingTitle: loc("Freeing space"))],
                    paths: item.paths), bytes)
    }

    /// The symbols cache's item (`/System/Library/Caches/com.apple.coresymbolicationd`).
    static let symbolsID = "cache:symbolication"

    /// The symbols coresymbolicationd keeps for crash reports and debugging, as a row of Free now with a button of its own: only the
    /// helper can delete them, so Clean leaves them out. Sized by what they add to System Data: a part macOS marked purgeable is free
    /// space already. A cache macOS rebuilds, so no pill. No folder button: the folder is root's, and the Finder cannot open it.
    static func symbolsRow(_ snapshot: SystemDataSnapshot) -> (row: Row, bytes: UInt64)? {
        guard let item = snapshot.report.items.first(where: { $0.id == symbolsID }) else { return nil }
        let bytes = counted(item, snapshot)
        guard bytes >= manualThreshold else { return nil }
        return (Row(id: "symbols", title: loc("Symbols for crash reports"), trailing: ByteFormat.string(bytes), symbol: "ladybug",
                    detail: loc("What macOS keeps to read crash reports. It's rebuilt when needed."),
                    actions: [Action(id: "deleteSymbolicationCache", title: loc("Free"),
                                     confirmation: Confirmation(title: loc("Free the symbols for crash reports?"),
                                                                message: loc("macOS builds them again the next time it reads a crash report."),
                                                                confirmTitle: loc("Free")),
                                     requires: [.privilegedHelper], workingTitle: loc("Freeing space"))]), bytes)
    }

    /// Where the scan found the item with this id, for the row's Show in Finder.
    static func paths(of id: String, _ snapshot: SystemDataSnapshot) -> [String] {
        snapshot.report.items.first { $0.id == id }?.paths ?? []
    }

    static func reportCount(_ snapshot: SystemDataSnapshot) -> String {
        snapshot.reports.candidates.count == 1 ? loc("1 report") : loc("\(snapshot.reports.candidates.count) reports")
    }

    /// Everything MacSpace leaves alone (it belongs to apps, to the user or to macOS), largest first.
    static func leftAlone(_ snapshot: SystemDataSnapshot) -> [SystemDataItem] {
        let report = snapshot.report
        let claimed = CachesPage.claimed(snapshot)
        var handled: Set<String> = ["reports:diagnostic", "versions:documents", "update:staged", "assets:system", unifiedLogID]
        // Listed under Free now while it is worth a row; until then, with the rest macOS manages.
        if symbolsRow(snapshot) != nil { handled.insert(symbolsID) }
        return report.items.filter { item in
            guard item.kind != .pendingUpdate, listed(item, snapshot, claimed: claimed) >= manualThreshold, !handled.contains(item.id), !item.id.hasPrefix("small:"),
                  !item.id.hasPrefix(wallpaperDownloadsPrefix) else { return false }
            switch item.cleanup.kind {
            case .review: return !countedByAnotherCategory(item)
            case .managedByMacOS, .command: return item.kind != .codeSignClone && !countedElsewhere.contains(item.kind)
            default: return false
            }
        }
        .sorted { listed($0, snapshot, claimed: claimed) > listed($1, snapshot, claimed: claimed) }
    }

    /// An item's counted size without the caches the caches page lists from it (`CachesPage.claimed`).
    static func listed(_ item: SystemDataItem, _ snapshot: SystemDataSnapshot, claimed: [String: UInt64]? = nil) -> UInt64 {
        let bytes = counted(item, snapshot)
        let taken = (claimed ?? CachesPage.claimed(snapshot))[item.id] ?? 0
        return bytes > taken ? bytes - taken : 0
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
                let bytes = entry.items.map { listed($0, snapshot) }.reduce(0, +)
                let rows = leftAloneRows(entry.items, snapshot)
                if rows.count == 1 { return (rows[0], bytes) }
                return (Row.group(id: "other:\(entry.category.id)", title: entry.category.title, totalBytes: bytes, rows: rows, detail: entry.category.detail), bytes)
            }
            .sorted { $0.bytes > $1.bytes }
            .map(\.row)
        return .section(SectionWidget(id: "other", title: loc("Everything else"), widgets: [.list(ListWidget(id: "other-list", rows: rows))]))
    }

    /// How Everything else is sorted: the bar's categories.
    struct OtherCategory {
        let id: String
        let title: String
        var detail: String? = nil

        static let other = OtherCategory(id: "other", title: loc("Other"))

        /// Why a category is left alone, behind its (i), where the title does not say it. The caches here are the apps' own and
        /// macOS's, in use: an app rebuilds its cache as soon as it runs again. What MacSpace does clean, the per-user system cache,
        /// the apps' web caches and the developer caches, is on the caches page (`CachesPage`).
        static let details: [String: String] = [
            "caches": loc("Apps and macOS rebuild these by themselves."),
        ]

        /// The bar's category that holds this kind, or Other.
        static func of(_ kind: SystemDataKind) -> OtherCategory {
            groups.first { $0.kinds.contains(kind) }.map { OtherCategory(id: $0.id, title: $0.title, detail: details[$0.id]) } ?? other
        }
    }

    /// Every item, largest first, with what the user can do about it when there is something. A container's kind goes under its name: the group already says
    /// it is app data.
    private static func leftAloneRows(_ items: [SystemDataItem], _ snapshot: SystemDataSnapshot) -> [Row] {
        let claimed = CachesPage.claimed(snapshot)
        return items.map { itemRow($0, bytes: listed($0, snapshot, claimed: claimed)) }
    }

    /// An item as a row: its name, what kind of item it is as a pill, its size, what the user can do about it, and where its files are.
    static func itemRow(_ item: SystemDataItem, bytes: UInt64) -> Row {
        let (title, kind) = presentation(item)
        // What macOS manages needs no explanation: only what the user can do something about has one.
        let detail = item.cleanup.kind == .managedByMacOS || item.cleanup.description.isEmpty ? nil : item.cleanup.description
        return Row(id: item.id, title: title, trailing: ByteFormat.string(bytes), badge: kind.map { Badge($0) }, detail: detail, paths: item.paths)
    }

    /// An item's name and its kind, read from its id and folder, not from its title, which is in the user's language: the kind is
    /// the row's pill, not part of its name ("Firefox" and "App cache", not "App cache: Firefox").
    static func presentation(_ item: SystemDataItem) -> (title: String, kind: String?) {
        func name(after prefix: String) -> String { String(item.id.dropFirst(prefix.count)) }
        if item.id.hasPrefix("container:") {
            return (name(after: "container:"), item.paths.contains { $0.contains("/Group Containers/") } ? loc("App group data") : loc("App container"))
        }
        let kinds: [(prefix: String, kind: String)] = [("appcache:", loc("App cache")), ("supportcache:", loc("Web cache")),
                                                       ("usercache:", loc("System cache")), ("toolcache:", loc("Tool cache")),
                                                       ("cloud:", loc("Cloud storage")), ("vm:", loc("Virtual machine")),
                                                       ("library:", loc("Your Library")), ("home:", loc("Your home folder"))]
        for entry in kinds where item.id.hasPrefix(entry.prefix) { return (name(after: entry.prefix), entry.kind) }
        if item.id.hasPrefix("shared:"), item.title == name(after: "shared:") {
            return (name(after: "shared:"), loc("All users"))
        }
        if item.id == "assets:system" { return (item.title, "MobileAsset") }
        return (item.title, nil)
    }

    /// Files of an update that is already installed; shown only when the scan recognised them as a leftover (see the inspector).
    static func leftoverUpdateSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        guard let item = snapshot.report.items.first(where: { $0.id == "update:staged" && $0.kind == .stagedUpdate && $0.cleanup.kind == .managedByMacOS }),
              let bytes = item.bytes, bytes > 0 else { return nil }
        let size = ByteFormat.string(bytes)
        let row = Row(id: "leftover-update", title: loc("Leftover macOS update files"),
                      trailing: size, symbol: "arrow.down.app",
                      detail: loc("From an update that's already installed."),
                      actions: [Action(id: "deleteStagedUpdate", title: loc("Free"), role: .destructive,
                                       confirmation: Confirmation(title: loc("Free the leftover update files?"), confirmTitle: loc("Free")),
                                       requires: [.privilegedHelper], workingTitle: loc("Freeing space"))],
                      paths: item.paths)
        return .section(SectionWidget(id: "leftover-update", title: loc("Leftover update files"),
                                      widgets: [.list(ListWidget(id: "leftover-update-list", rows: [row]))]))
    }

    /// The folders of idleassetsd's downloads the helper found (`SystemDataReport.rootOnly`), one item per account folder.
    static let wallpaperDownloadsPrefix = "downloads:idleassetsd:"

    /// The wallpaper and screen saver downloads macOS left unfinished, as a row of Free now with a button of its own. Only the helper
    /// can delete them, and only those older than its retention window, so Clean and automatic cleaning leave them out.
    static func wallpaperDownloadsRow(_ snapshot: SystemDataSnapshot) -> (row: Row, bytes: UInt64)? {
        let bytes = snapshot.report.items.filter { $0.id.hasPrefix(wallpaperDownloadsPrefix) }.compactMap(\.bytes).reduce(0, +)
        guard bytes >= manualThreshold else { return nil }
        let size = ByteFormat.string(bytes)
        return (Row(id: "wallpaper-downloads", title: loc("Wallpaper and screen saver downloads"), trailing: size, symbol: "photo.on.rectangle",
                    detail: loc("Wallpapers and screen savers macOS is downloading. A large size means stuck downloads."),
                    actions: [Action(id: "deleteWallpaperDownloads", title: loc("Free"),
                                     confirmation: Confirmation(title: loc("Free stuck wallpaper downloads?"),
                                                                message: loc("macOS downloads them again if they're needed."),
                                                                confirmTitle: loc("Free")),
                                     requires: [.privilegedHelper], workingTitle: loc("Freeing space"))],
                    paths: snapshot.report.items.filter { $0.id.hasPrefix(wallpaperDownloadsPrefix) }.flatMap(\.paths)), bytes)
    }

    /// The saved history behind File > Revert To > Browse All Versions, as a row of Free now. Deleting it is irreversible, so it keeps
    /// its badge and its own confirmation, and Clean leaves it out.
    static func versionsRow(_ snapshot: SystemDataSnapshot) -> (row: Row, bytes: UInt64)? {
        guard let item = snapshot.report.items.first(where: { $0.id == "versions:documents" }), let bytes = item.bytes, bytes >= manualThreshold else { return nil }
        let size = ByteFormat.string(bytes)
        return (Row(id: "versions", title: loc("Document version history"),
                      trailing: size, badge: Badge(loc("Cannot be undone"), tone: .critical), symbol: "clock.arrow.circlepath",
                      detail: loc("Earlier versions of your documents (File > Revert To). Only keeps the latest version."),
                      actions: [Action(id: "deleteVersions", title: loc("Free"), role: .destructive,
                                       confirmation: Confirmation(title: loc("Free all version history?"),
                                                                  message: loc("You won't be able to revert any document to an earlier version. Save and close your documents first."),
                                                                  confirmTitle: loc("Free")),
                                       requires: [.privilegedHelper], workingTitle: loc("Freeing space"))],
                      paths: item.paths), bytes)
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
        let paths = places(snapshot.report.unreadable)
        let rootOnly = paths.filter(RootMeasuredLocations.isAllowed)
        let other = paths.filter { !RootMeasuredLocations.isAllowed($0) }
        let fda = snapshot.report.fullDiskAccess ? [] : other
        if snapshot.helperError != nil { return (fda, [], rootOnly) }
        return (fda, snapshot.helperTried ? [] : rootOnly, [])
    }

    /// How many unreadable places stay silent because nothing can be done about them.
    static func quietlySkipped(_ snapshot: SystemDataSnapshot) -> Int {
        let actionable = actionableUnreadable(snapshot)
        return places(snapshot.report.unreadable).count - actionable.fullDiskAccess.count - actionable.helper.count - actionable.helperUnreachable.count
    }

    /// Unreadable paths as the user would name the places: the other accounts' folders in `/private/var/folders` (dozens of caches
    /// and temporary folders, one per macOS service) are one place.
    static func places(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.map { $0.hasPrefix("/private/var/folders/") ? "/private/var/folders" : $0 }.filter { seen.insert($0).inserted }
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
