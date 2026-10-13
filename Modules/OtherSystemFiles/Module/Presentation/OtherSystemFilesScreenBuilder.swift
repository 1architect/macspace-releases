import Foundation
import MacSpaceOtherSystemFilesPrivileged
import MacSpacePlatform
import MacSpaceSdk

/// Turns a snapshot into the tile and the page. Pure, so it can be tested without a Mac.
enum OtherSystemFilesScreenBuilder {
    /// Below this, freeing is not worth a button, and a service not worth a row.
    static let threshold: UInt64 = 50_000_000

    static func tile(_ snapshot: PurgeableSnapshot) -> Tile {
        guard snapshot.services != nil || !snapshot.updates.isEmpty else { return Tile(title: loc("other system files"), status: loc("unavailable")) }
        let freeable = snapshot.freeableBytes
        let status: String
        if let removal = snapshot.removing.values.first { status = loc("removing downloads · \(Int((removal.fraction * 100).rounded()))%") }
        else if freeable < threshold { status = loc("nothing to free") }
        else if snapshot.retrying { status = loc("freeing \(ByteFormat.string(freeable))") }
        else { status = loc("free up to \(ByteFormat.string(freeable))") }
        // The total in the title: what is outside System Data. What macOS counts as purgeable matches the space System Settings counts
        // as available beyond the free space (27.49 GB here against 27.52 GB there, 2026-10-06); a prepared update it counts as macOS.
        let segments = segments(snapshot)
        let total = segments.reduce(0) { $0 + $1.bytes }
        return Tile(title: loc("other system files"), figure: total > 0 ? ByteFormat.string(total) : nil, status: status, graphic: .blocks(segments),
                    reclaimableBytes: freeable >= threshold ? freeable : nil,
                    purgeableByService: [CacheDeleteService.fsPurgeableData: freeable],
                    // Read again every few seconds while downloads are being removed, so the row and the tile follow it.
                    refreshAfter: snapshot.removing.isEmpty ? nil : 3)
    }

    /// What is outside System Data, largest first: what macOS counts as purgeable (what MacSpace frees in the caution tone) and a
    /// macOS update waiting to install.
    static func segments(_ snapshot: PurgeableSnapshot) -> [UsageSegment] {
        let services = (snapshot.services ?? [:]).filter { $0.value >= threshold || ($0.key == CacheDeleteService.fsPurgeableData && $0.value > 0) }
        var segments = services.sorted { $0.value > $1.value }.enumerated().map { index, entry in
            UsageSegment(id: entry.key, label: title(entry.key, snapshot), bytes: entry.value,
                         tone: entry.key == CacheDeleteService.fsPurgeableData ? .caution : .series(index))
        }
        segments += snapshot.updates.map { UsageSegment(id: "update:\($0.path)", label: $0.shortName, bytes: $0.bytes, tone: .neutral) }
        return segments.sorted { $0.bytes > $1.bytes }
    }

    /// The page's blocks, each with the rows it is made of, so a click on it opens a page of them (`UsageSegment.items`): the
    /// purgeable app files with their Free button, each cloud service's downloads with theirs and where they are, a waiting update
    /// with its Open. A block whose row would only repeat its name and size (a service MacSpace leaves alone and says nothing about)
    /// opens nothing. Not on the tile, which is saved.
    static func blocksWithItems(_ snapshot: PurgeableSnapshot) -> [UsageSegment] {
        let rows = [freeNow(snapshot), updatesSection(snapshot), keptSection(snapshot)].compactMap { $0 }.flatMap(rows(in:))
        return segments(snapshot).map { segment in
            var segment = segment
            let items = segment.id == CacheDeleteService.fsPurgeableDocument
                ? documentsRows(segment.bytes, snapshot) ?? []
                : rows.filter { $0.id == segment.id }
            segment.items = items.contains(where: saysMore) ? items : []
            return segment
        }
    }

    /// The rows of a section of the page.
    private static func rows(in widget: ScreenWidget) -> [Row] {
        switch widget {
        case let .list(list): return list.rows
        case let .section(section): return section.widgets.flatMap(rows(in:))
        default: return []
        }
    }

    /// A row says more than its block when it has an explanation, a button or files to show.
    private static func saysMore(_ row: Row) -> Bool {
        !(row.detail ?? "").isEmpty || !row.actions.isEmpty || !row.paths.isEmpty || !row.steps.isEmpty
    }

    /// The bar, then what MacSpace frees, on its own and row by row, then everything else macOS counts as purgeable, row by row.
    static func screen(_ snapshot: PurgeableSnapshot) -> Screen {
        guard snapshot.services != nil || !snapshot.updates.isEmpty else {
            return Screen(title: loc("Other System Files"), widgets: [.banner(Banner(id: "unavailable", severity: .warning,
                title: loc("macOS's purge service did not answer"),
                message: loc("Nothing can be measured right now. Try Refresh.")))])
        }
        var widgets: [ScreenWidget] = []
        if let free = freeNow(snapshot) { widgets.append(free) }
        if let updates = updatesSection(snapshot) { widgets.append(updates) }
        if let disks = backupDisksSection(snapshot) { widgets.append(disks) }
        if case let .section(kept)? = keptSection(snapshot), case let .list(list)? = kept.widgets.first {
            widgets.append(.list(ListWidget(id: "kept", title: loc("Deleted by macOS when the disk is full"), rows: list.rows)))
        }
        let hero = UsageBar(id: "purgeable", title: loc("Outside System Data"), totalBytes: snapshot.totalBytes + snapshot.updateBytes, segments: blocksWithItems(snapshot),
                            footnote: loc("Files macOS deletes on its own when the disk runs low. System Settings counts this space as available."))
        return Screen(title: loc("Other System Files"), hero: hero, primary: freeAction(snapshot, prominent: true), widgets: widgets)
    }

    /// "Up to": the size is macOS's estimate, which can count more than macOS then deletes. No button while MacSpace is already
    /// asking macOS again in the background.
    static func freeAction(_ snapshot: PurgeableSnapshot, prominent: Bool) -> Action? {
        let bytes = snapshot.freeableBytes
        guard bytes >= threshold, !snapshot.retrying else { return nil }
        let size = ByteFormat.string(bytes)
        return Action(id: "purgeFiles", title: prominent ? loc("Free up to \(size)") : loc("Free"), symbol: prominent ? "sparkles" : nil,
                      role: prominent ? .prominent : .normal,
                      confirmation: Confirmation(title: loc("Free up to \(size) of purgeable app files?"),
                                                 message: loc("Apps download them again if they need them."),
                                                 confirmTitle: loc("Free")), workingTitle: loc("Freeing space…"))
    }

    /// A macOS update downloaded and prepared, waiting for a restart: Software Update installs it, and macOS removes it then.
    static func updatesSection(_ snapshot: PurgeableSnapshot) -> ScreenWidget? {
        guard !snapshot.updates.isEmpty else { return nil }
        let rows = snapshot.updates.sorted { $0.bytes > $1.bytes }.map { update in
            Row(id: "update:\(update.path)", title: loc("\(update.name), ready to install"), trailing: ByteFormat.string(update.bytes),
                badge: Badge(loc("Installs at the next restart")), symbol: "arrow.down.circle",
                actions: [Action(id: "openSoftwareUpdate", title: loc("Open"))], paths: [update.path])
        }
        return .section(SectionWidget(id: "updates", title: loc("Waiting to install"), widgets: [.list(ListWidget(id: "updates-list", rows: rows))]))
    }

    /// What MacSpace frees, as its own section on the page, largest first: the files apps marked purgeable, each cloud service's
    /// downloads, removed only with that row's own button (they are the user's documents, kept in the cloud), and Time Machine's older
    /// local snapshots, with theirs.
    static func freeNow(_ snapshot: PurgeableSnapshot) -> ScreenWidget? {
        var rows = Array(zip(cloudRows(snapshot), cloudShares(snapshot)))
        if snapshot.freeableBytes >= threshold {
            let service = PurgeableService.describe(CacheDeleteService.fsPurgeableData)
            let detail = snapshot.retrying ? service.detail + " " + loc("macOS kept them when asked; MacSpace keeps asking it.") : service.detail
            rows.append((Row(id: service.id, title: service.title, trailing: ByteFormat.string(snapshot.freeableBytes),
                             badge: snapshot.retrying ? Badge(loc("Freeing in the background"), tone: .caution) : nil, symbol: service.symbol,
                             detail: detail, actions: freeAction(snapshot, prominent: false).map { [$0] } ?? []), snapshot.freeableBytes))
        }
        if let snapshots = snapshotsRow(snapshot), snapshots.freeable { rows.append((snapshots.row, snapshots.bytes)) }
        guard !rows.isEmpty else { return nil }
        let sorted = rows.enumerated().sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }.map(\.element.0)
        return .section(SectionWidget(id: "free", title: loc("Free now"), widgets: [.list(ListWidget(id: "free-list", rows: sorted))]))
    }

    /// Time Machine's local snapshots as one row: how many, what they hold together (macOS's figure), and, when some can go, a Free
    /// that deletes all but the two Time Machine still needs (`TimeMachine.LocalSnapshots`). nil when there are none. `freeable` puts
    /// it under Free now; otherwise it is listed with what macOS deletes when the disk is full, as it is the same space.
    static func snapshotsRow(_ snapshot: PurgeableSnapshot) -> (row: Row, bytes: UInt64, freeable: Bool)? {
        guard let snapshots = snapshot.timeMachine.snapshots, !snapshots.all.isEmpty else { return nil }
        let service = PurgeableService.describe(CacheDeleteService.timeMachineSnapshots)
        let bytes = snapshot.services?[CacheDeleteService.timeMachineSnapshots] ?? 0
        let removable = snapshots.removable
        let backingUp = snapshot.timeMachine.backingUp == true
        let count = snapshots.all.count == 1 ? loc("1 snapshot") : loc("\(snapshots.all.count) snapshots")
        var badges: [Badge] = []
        if !removable.isEmpty { badges.append(Badge(loc("Cannot be undone"), tone: .critical)) }
        if backingUp { badges.append(Badge(loc("Backing up now"), tone: .caution)) }
        let dates = snapshots.all.reversed().map { snapshot in
            let kept = snapshots.keptStamps.contains(snapshot.stamp)
            return snapshot.date.formatted(date: .abbreviated, time: .shortened) + (kept ? " · " + loc("kept") : "")
        }
        let detail = loc("Copies of this Mac that Time Machine keeps for a day, so files can be restored without the backup disk. Free leaves the newest and the one the next backup starts from.")
            + "\n\n" + dates.joined(separator: "\n")
        let size = ByteFormat.string(bytes)
        let free = Action(id: "freeSnapshots", title: loc("Free"), role: .destructive,
                          confirmation: Confirmation(title: removable.count == 1 ? loc("Free 1 Time Machine snapshot?") : loc("Free \(removable.count) Time Machine snapshots?"),
                                                     message: loc("Files can no longer be restored from those hours on this Mac. Backups on the backup disk stay."),
                                                     confirmTitle: loc("Free")), workingTitle: loc("Freeing space…"))
        let row = Row(id: service.id, title: service.title, subtitle: count, trailing: bytes > 0 ? size : nil, badges: badges, symbol: service.symbol,
                      detail: detail, actions: removable.isEmpty || backingUp ? [] : [free])
        return (row, bytes, !removable.isEmpty)
    }

    /// Time Machine's backup disks: each connected one as a group whose page lists its backups, newest first, and lets the user choose
    /// old ones to free (never the latest); one that is not connected says so. Their space is not this Mac's, so they are in no figure
    /// of the page.
    static func backupDisksSection(_ snapshot: PurgeableSnapshot) -> ScreenWidget? {
        let disks = snapshot.timeMachine.disks
        guard !disks.isEmpty else { return nil }
        let backingUp = snapshot.timeMachine.backingUp == true
        let entries: [(row: Row, used: UInt64)] = disks.map { (backupDiskRow($0, backingUp: backingUp), $0.usedBytes ?? 0) }
        // Largest first; disks that are not connected have no size and come after, by name.
        let rows = entries.sorted { first, second in
            first.used != second.used ? first.used > second.used : first.row.title.localizedStandardCompare(second.row.title) == .orderedAscending
        }.map(\.row)
        return .section(SectionWidget(id: "backup-disks", title: loc("Time Machine backup disks"), widgets: [.list(ListWidget(id: "backup-disks-list", rows: rows))]))
    }

    static func backupDiskRow(_ disk: TimeMachineState.BackupDisk, backingUp: Bool) -> Row {
        let destination = disk.destination
        let symbol = "externaldrive.badge.timemachine"
        guard let mount = destination.mountPoint else {
            return Row(id: "backupdisk:\(destination.id)", title: destination.name, badge: Badge(loc("Not connected")), symbol: symbol,
                       detail: loc("Connect it to see its backups and free old ones."))
        }
        guard let backups = disk.backups, let newest = backups.last else {
            return Row(id: "backupdisk:\(destination.id)", title: destination.name, trailing: disk.usedBytes.map(ByteFormat.string),
                       badge: Badge(loc("Backups not readable")), symbol: symbol, paths: [mount])
        }
        // Newest first, by date: a backup has no size of its own (its blocks are shared with the others), so there is no size to sort by.
        let rows = backups.reversed().map { backup in
            Row(id: "backup:\(backup.stamp)", title: backup.date.formatted(date: .abbreviated, time: .shortened),
                badge: backup.stamp == newest.stamp ? Badge(loc("Latest")) : nil)
        }
        var group = Row.group(id: "backupdisk:\(destination.id)", title: destination.name, symbol: symbol, totalBytes: disk.usedBytes ?? 0, rows: rows)
        group.subtitle = backups.count == 1 ? loc("1 backup") : loc("\(backups.count) backups")
        group.badges = (disk.freeBytes.map { [Badge(loc("\(ByteFormat.string($0)) free"))] } ?? []) + (backingUp ? [Badge(loc("Backing up now"), tone: .caution)] : [])
        group.paths = [mount]
        let removable = backups.filter { $0.stamp != newest.stamp }
        if !removable.isEmpty, !backingUp {
            group.selection = Selection(
                action: Action(id: "deleteBackups", title: loc("Free selected"), role: .destructive, parameters: ["mountPoint": mount],
                               confirmation: Confirmation(title: loc("Free the selected backups?"),
                                                          message: loc("They are deleted from \(destination.name) for good. Files that are only in them can't be restored."),
                                                          confirmTitle: loc("Free")),
                               requires: [.privilegedHelper], workingTitle: loc("Freeing space…")),
                choices: Dictionary(removable.map { ("backup:\($0.stamp)", UInt64(0)) }, uniquingKeysWith: { first, _ in first }))
        }
        return group
    }

    /// One row per cloud service holding downloads, each with its button. Empty while none were found.
    static func cloudRows(_ snapshot: PurgeableSnapshot) -> [Row] {
        let bytes = snapshot.services?[CacheDeleteService.fsPurgeableDocument] ?? 0
        guard bytes >= threshold else { return [] }
        return (documentsRows(bytes, snapshot) ?? []).filter { $0.id.hasPrefix("documents:") }
    }

    /// The sizes of the cloud rows, in their order.
    static func cloudShares(_ snapshot: PurgeableSnapshot) -> [UInt64] {
        let bytes = snapshot.services?[CacheDeleteService.fsPurgeableDocument] ?? 0
        guard bytes >= threshold else { return [] }
        let found = snapshot.documents.map(\.bytes).reduce(0, +)
        return snapshot.documents.sorted { $0.bytes > $1.bytes }.map { found > bytes ? UInt64((Double(bytes) * Double($0.bytes) / Double(max(found, 1))).rounded()) : $0.bytes }
    }

    /// Removes one cloud service's downloads; the size is the row's.
    static func removeDownloadsAction(_ source: PurgeableDocuments.Source, bytes: UInt64) -> Action {
        Action(id: "removeDownloads", title: loc("Free"), parameters: ["path": source.path],
               confirmation: Confirmation(title: loc("Free \(ByteFormat.string(bytes)) of \(source.name) downloads?"),
                                          message: loc("The files stay in \(source.name) and download again when you open them."),
                                          confirmTitle: loc("Free")), workingTitle: loc("Freeing space…"))
    }

    /// A service's name; the purgeable documents are named after the cloud service that holds them, once it is known.
    static func title(_ id: String, _ snapshot: PurgeableSnapshot) -> String {
        guard id == CacheDeleteService.fsPurgeableDocument, !snapshot.documents.isEmpty else { return PurgeableService.describe(id).title }
        return snapshot.documents.count == 1 ? loc("\(snapshot.documents[0].name) files on this Mac") : loc("Cloud files on this Mac")
    }

    /// The purgeable documents as rows: one per cloud service that holds them, opening in place onto its folders (no page of its
    /// own), and what no cloud folder accounts for. nil while none were found.
    static func documentsRows(_ bytes: UInt64, _ snapshot: PurgeableSnapshot) -> [Row]? {
        guard !snapshot.documents.isEmpty else { return nil }
        let detail = loc("Copies of cloud files kept on this Mac. Removing them keeps the files in the cloud.")
        // The rows add up to macOS's figure: where the files found come to more (read at another moment, or flagged at an urgency
        // macOS does not count), each cloud service gets its share of it. Its folders keep the sizes found.
        let found = snapshot.documents.map(\.bytes).reduce(0, +)
        func share(_ source: PurgeableDocuments.Source) -> UInt64 {
            found > bytes ? UInt64((Double(bytes) * Double(source.bytes) / Double(max(found, 1))).rounded()) : source.bytes
        }
        var rows = snapshot.documents.sorted { $0.bytes > $1.bytes }.map { source in
            // While its downloads are being removed: how far, and no button.
            let removal = snapshot.removing[source.path]
            return Row(id: "documents:\(source.path)", title: loc("\(source.name) files on this Mac"), subtitle: source.files == 1 ? loc("1 file") : loc("\(source.files) files"),
                       trailing: ByteFormat.string(share(source)),
                       badge: removal.map { Badge($0.total == 0 ? loc("Removing downloads") : loc("Removing · \(Int(($0.fraction * 100).rounded()))%, \(ByteFormat.string($0.bytes))"), tone: .caution) },
                       symbol: "icloud.and.arrow.down", detail: detail + folderList(source),
                       actions: removal == nil ? [removeDownloadsAction(source, bytes: share(source))] : [], paths: [source.path])
        }
        // What no cloud folder accounts for is named.
        if bytes > found, bytes - found >= threshold * 10 {
            let service = PurgeableService.describe(CacheDeleteService.fsPurgeableDocument)
            rows.append(Row(id: CacheDeleteService.fsPurgeableDocument, title: loc("Other purgeable documents"), trailing: ByteFormat.string(bytes - found),
                            symbol: service.symbol, detail: service.detail))
        }
        return rows
    }

    /// The largest folders of a cloud service, one per line, for the row's description. Empty when none is worth naming.
    static func folderList(_ source: PurgeableDocuments.Source) -> String {
        let folders = source.folders.filter { $0.bytes >= threshold }
        guard !folders.isEmpty else { return "" }
        return "\n\n" + folders.map { "\($0.name): \(ByteFormat.string($0.bytes)), \($0.files == 1 ? loc("1 file") : loc("\($0.files) files"))" }.joined(separator: "\n")
    }

    /// The services MacSpace leaves alone, largest first.
    static func keptServices(_ snapshot: PurgeableSnapshot) -> [(key: String, value: UInt64)] {
        (snapshot.services ?? [:]).filter { $0.key != CacheDeleteService.fsPurgeableData && $0.value >= threshold }.sorted { $0.value > $1.value }
    }

    /// Everything else macOS counts as purgeable, with why MacSpace leaves it, so the total adds up.
    static func keptSection(_ snapshot: PurgeableSnapshot) -> ScreenWidget? {
        // Time Machine's snapshots are one row of their own (`snapshotsRow`), here only while none can be freed, whatever their size:
        // macOS's figure for them can lag at 0 while they are listed.
        let snapshots = snapshotsRow(snapshot)
        var rows = keptServices(snapshot).filter { $0.key != CacheDeleteService.timeMachineSnapshots || snapshots == nil }.map { entry -> (rows: [Row], bytes: UInt64) in
            let service = PurgeableService.describe(entry.key)
            if entry.key == CacheDeleteService.fsPurgeableDocument, let rows = documentsRows(entry.value, snapshot) {
                return (rows.filter { !$0.id.hasPrefix("documents:") }, entry.value)
            }
            return ([Row(id: entry.key, title: service.title, trailing: ByteFormat.string(entry.value), symbol: service.symbol, detail: service.detail)], entry.value)
        }
        if let snapshots, !snapshots.freeable { rows.append(([snapshots.row], snapshots.bytes)) }
        let sorted = rows.enumerated().sorted { $0.element.bytes != $1.element.bytes ? $0.element.bytes > $1.element.bytes : $0.offset < $1.offset }
            .flatMap(\.element.rows)
        guard !sorted.isEmpty else { return nil }
        return .section(SectionWidget(id: "kept", title: loc("Left alone"), widgets: [.list(ListWidget(id: "kept-list", rows: sorted))]))
    }
}
