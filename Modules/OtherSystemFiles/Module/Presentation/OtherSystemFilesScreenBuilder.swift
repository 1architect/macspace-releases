import Foundation
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
        return Tile(title: total > 0 ? loc("other system files \(ByteFormat.string(total))") : loc("other system files"), status: status, graphic: .blocks(segments),
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

    /// The bar, then what MacSpace frees, on its own and row by row, then everything else macOS counts as purgeable as one group
    /// that opens a page of its own.
    static func screen(_ snapshot: PurgeableSnapshot) -> Screen {
        guard snapshot.services != nil || !snapshot.updates.isEmpty else {
            return Screen(title: loc("Other System Files"), widgets: [.banner(Banner(id: "unavailable", severity: .warning,
                title: loc("macOS's purge service did not answer"),
                message: loc("Nothing can be measured right now. Try Refresh.")))])
        }
        var widgets: [ScreenWidget] = []
        if let free = freeNow(snapshot) { widgets.append(free) }
        if let updates = updatesSection(snapshot) { widgets.append(updates) }
        if case let .section(kept)? = keptSection(snapshot), case let .list(list)? = kept.widgets.first {
            let total = keptServices(snapshot).map(\.value).reduce(0, +) - cloudBytes(snapshot)
            let row = list.rows.count == 1 ? list.rows[0]
                : Row.group(id: "group:kept", title: kept.title, symbol: "tray.full", totalBytes: total, rows: list.rows, detail: kept.subtitle)
            widgets.append(.list(ListWidget(id: "kept", title: loc("Counted by macOS"), rows: [row])))
        }
        let hero = UsageBar(id: "purgeable", title: loc("Outside System Data"), totalBytes: snapshot.totalBytes + snapshot.updateBytes, segments: segments(snapshot),
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
                                                 confirmTitle: loc("Free")))
    }

    /// A macOS update downloaded and prepared, waiting for a restart: Software Update installs it, and macOS removes it then.
    static func updatesSection(_ snapshot: PurgeableSnapshot) -> ScreenWidget? {
        guard !snapshot.updates.isEmpty else { return nil }
        let rows = snapshot.updates.map { update in
            Row(id: "update:\(update.path)", title: loc("\(update.name), ready to install"), subtitle: loc("installs at the next restart"),
                trailing: ByteFormat.string(update.bytes), symbol: "arrow.down.circle",
                actions: [Action(id: "openSoftwareUpdate", title: loc("Open"))])
        }
        return .section(SectionWidget(id: "updates", title: loc("Waiting to install"), widgets: [.list(ListWidget(id: "updates-list", rows: rows))]))
    }

    /// What MacSpace frees, as its own section on the page: the files apps marked purgeable, and each cloud service's downloads,
    /// removed only with that row's own button (they are the user's documents, kept in the cloud).
    static func freeNow(_ snapshot: PurgeableSnapshot) -> ScreenWidget? {
        var rows: [Row] = []
        if snapshot.freeableBytes >= threshold {
            let service = PurgeableService.describe(CacheDeleteService.fsPurgeableData)
            rows.append(Row(id: service.id, title: service.title, trailing: ByteFormat.string(snapshot.freeableBytes),
                            badge: snapshot.retrying ? Badge(loc("Freeing in the background"), tone: .caution) : nil, symbol: service.symbol,
                            detail: snapshot.retrying ? service.detail + " " + loc("macOS kept them when asked; MacSpace keeps asking it.") : service.detail,
                            actions: freeAction(snapshot, prominent: false).map { [$0] } ?? []))
        }
        rows += cloudRows(snapshot)
        guard !rows.isEmpty else { return nil }
        return .section(SectionWidget(id: "free", title: loc("Free now"), widgets: [.list(ListWidget(id: "free-list", rows: rows))]))
    }

    /// One row per cloud service holding downloads, each with its button. Empty while none were found.
    static func cloudRows(_ snapshot: PurgeableSnapshot) -> [Row] {
        let bytes = snapshot.services?[CacheDeleteService.fsPurgeableDocument] ?? 0
        guard bytes >= threshold else { return [] }
        return (documentsRows(bytes, snapshot) ?? []).filter { $0.id.hasPrefix("documents:") }
    }

    /// Of macOS's purgeable documents, what the cloud rows account for.
    static func cloudBytes(_ snapshot: PurgeableSnapshot) -> UInt64 {
        let bytes = snapshot.services?[CacheDeleteService.fsPurgeableDocument] ?? 0
        guard bytes >= threshold, !snapshot.documents.isEmpty else { return 0 }
        return min(snapshot.documents.map(\.bytes).reduce(0, +), bytes)
    }

    /// Removes one cloud service's downloads; the size is the row's.
    static func removeDownloadsAction(_ source: PurgeableDocuments.Source, bytes: UInt64) -> Action {
        Action(id: "removeDownloads", title: loc("Remove Downloads"), parameters: ["path": source.path],
               confirmation: Confirmation(title: loc("Remove \(ByteFormat.string(bytes)) of \(source.name) downloads?"),
                                          message: loc("The files stay in \(source.name) and download again when you open them."),
                                          confirmTitle: loc("Remove")))
    }

    /// A service's name; the purgeable documents are named after the cloud service that holds them, once it is known.
    static func title(_ id: String, _ snapshot: PurgeableSnapshot) -> String {
        guard id == CacheDeleteService.fsPurgeableDocument, !snapshot.documents.isEmpty else { return PurgeableService.describe(id).title }
        return snapshot.documents.count == 1 ? loc("\(snapshot.documents[0].name) files on this Mac") : loc("Cloud files on this Mac")
    }

    /// The purgeable documents as rows: one per cloud service that holds them, opening in place onto its folders (no page of its
    /// own: the row already sits in a group's page), and what no cloud folder accounts for. nil while none were found.
    static func documentsRows(_ bytes: UInt64, _ snapshot: PurgeableSnapshot) -> [Row]? {
        guard !snapshot.documents.isEmpty else { return nil }
        let detail = loc("Copies of cloud files kept on this Mac. Removing them keeps the files in the cloud.")
        // The rows add up to macOS's figure: where the files found come to more (read at another moment, or flagged at an urgency
        // macOS does not count), each cloud service gets its share of it. Its folders keep the sizes found.
        let found = snapshot.documents.map(\.bytes).reduce(0, +)
        func share(_ source: PurgeableDocuments.Source) -> UInt64 {
            found > bytes ? UInt64((Double(bytes) * Double(source.bytes) / Double(max(found, 1))).rounded()) : source.bytes
        }
        var rows = snapshot.documents.map { source in
            // While its downloads are being removed: how far, and no button.
            let removal = snapshot.removing[source.path]
            return Row(id: "documents:\(source.path)", title: loc("\(source.name) files on this Mac"), subtitle: source.files == 1 ? loc("1 file") : loc("\(source.files) files"),
                       trailing: ByteFormat.string(share(source)),
                       badge: removal.map { Badge($0.total == 0 ? loc("Removing downloads") : loc("Removing · \(Int(($0.fraction * 100).rounded()))%, \(ByteFormat.string($0.bytes))"), tone: .caution) },
                       symbol: "icloud.and.arrow.down", detail: detail + folderList(source),
                       actions: removal == nil ? [removeDownloadsAction(source, bytes: share(source))] : [])
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
        let kept = keptServices(snapshot)
        guard !kept.isEmpty else { return nil }
        let rows = kept.flatMap { entry -> [Row] in
            let service = PurgeableService.describe(entry.key)
            if entry.key == CacheDeleteService.fsPurgeableDocument, let rows = documentsRows(entry.value, snapshot) {
                return rows.filter { !$0.id.hasPrefix("documents:") }
            }
            return [Row(id: entry.key, title: service.title, trailing: ByteFormat.string(entry.value), symbol: service.symbol, detail: service.detail)]
        }
        guard !rows.isEmpty else { return nil }
        return .section(SectionWidget(id: "kept", title: loc("Left alone"),                                       widgets: [.list(ListWidget(id: "kept-list", rows: rows))]))
    }
}
