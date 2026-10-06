import Foundation
import MacSpacePlatform
import MacSpaceSdk

/// Turns a snapshot into the tile and the page. Pure, so it can be tested without a Mac.
enum OtherSystemFilesScreenBuilder {
    /// Below this, freeing is not worth a button, and a service not worth a row.
    static let threshold: UInt64 = 50_000_000

    static func tile(_ snapshot: PurgeableSnapshot) -> Tile {
        guard snapshot.services != nil else { return Tile(title: "other system files", status: "unavailable") }
        let freeable = snapshot.freeableBytes
        let status: String
        if freeable < threshold { status = "nothing to free" }
        else if snapshot.retrying { status = "freeing \(ByteFormat.string(freeable))" }
        else { status = "up to \(ByteFormat.string(freeable)) can be freed" }
        // The total in the title: what macOS counts as purgeable, which matches the space System Settings counts as available beyond
        // the free space (27.49 GB here against 27.52 GB there, 2026-10-06).
        let segments = segments(snapshot)
        let total = segments.reduce(0) { $0 + $1.bytes }
        return Tile(title: total > 0 ? "other system files \(ByteFormat.string(total))" : "other system files", status: status, graphic: .blocks(segments),
                    reclaimableBytes: freeable >= threshold ? freeable : nil,
                    purgeableByService: [CacheDeleteService.fsPurgeableData: freeable])
    }

    /// What macOS counts as purgeable, largest first; what MacSpace frees in the caution tone.
    static func segments(_ snapshot: PurgeableSnapshot) -> [UsageSegment] {
        let services = (snapshot.services ?? [:]).filter { $0.value >= threshold || ($0.key == CacheDeleteService.fsPurgeableData && $0.value > 0) }
        return services.sorted { $0.value > $1.value }.enumerated().map { index, entry in
            UsageSegment(id: entry.key, label: title(entry.key, snapshot), bytes: entry.value,
                         tone: entry.key == CacheDeleteService.fsPurgeableData ? .caution : .series(index))
        }
    }

    /// The bar, then what MacSpace frees, on its own and row by row, then everything else macOS counts as purgeable as one group
    /// that opens a page of its own.
    static func screen(_ snapshot: PurgeableSnapshot) -> Screen {
        guard snapshot.services != nil else {
            return Screen(title: "Other System Files", widgets: [.banner(Banner(id: "unavailable", severity: .warning,
                title: "macOS's purge service did not answer",
                message: "CacheDelete is missing on this system or did not answer, so nothing can be measured or freed right now. Refresh to ask again."))])
        }
        var widgets: [ScreenWidget] = []
        if let free = freeNow(snapshot) { widgets.append(free) }
        if case let .section(kept)? = keptSection(snapshot), case let .list(list)? = kept.widgets.first {
            let total = keptServices(snapshot).map(\.value).reduce(0, +)
            let row = list.rows.count == 1 ? list.rows[0]
                : Row.group(id: "group:kept", title: kept.title, symbol: "tray.full", totalBytes: total, rows: list.rows, detail: kept.subtitle)
            widgets.append(.list(ListWidget(id: "kept", title: "Counted by macOS", rows: [row])))
        }
        let hero = UsageBar(id: "purgeable", title: "What macOS counts as purgeable", totalBytes: snapshot.totalBytes, segments: segments(snapshot),
                            footnote: "Asked from macOS's purge service at the urgency behind the disk's \"purgeable\" figure.")
        return Screen(title: "Other System Files", hero: hero, primary: freeAction(snapshot, prominent: true), widgets: widgets)
    }

    /// "Up to": the size is macOS's estimate, which can count more than macOS then deletes. No button while MacSpace is already
    /// asking macOS again in the background.
    static func freeAction(_ snapshot: PurgeableSnapshot, prominent: Bool) -> Action? {
        let bytes = snapshot.freeableBytes
        guard bytes >= threshold, !snapshot.retrying else { return nil }
        let size = ByteFormat.string(bytes)
        return Action(id: "purgeFiles", title: prominent ? "Free up to \(size)" : "Free", symbol: prominent ? "sparkles" : nil,
                      role: prominent ? .prominent : .normal,
                      confirmation: Confirmation(title: "Free up to \(size) of purgeable app files?",
                                                 message: "macOS deletes the files apps marked purgeable. Apps download again what they need.",
                                                 confirmTitle: "Free"))
    }

    /// The files MacSpace frees, as their own section on the page.
    static func freeNow(_ snapshot: PurgeableSnapshot) -> ScreenWidget? {
        guard snapshot.freeableBytes >= threshold else { return nil }
        let service = PurgeableService.describe(CacheDeleteService.fsPurgeableData)
        let row = Row(id: service.id, title: service.title, trailing: ByteFormat.string(snapshot.freeableBytes),
                      badge: snapshot.retrying ? Badge("Freeing in the background", tone: .caution) : nil, symbol: service.symbol,
                      detail: snapshot.retrying ? service.detail + " macOS kept them when asked; MacSpace keeps asking it." : service.detail,
                      actions: freeAction(snapshot, prominent: false).map { [$0] } ?? [])
        return .section(SectionWidget(id: "free", title: "Free now", widgets: [.list(ListWidget(id: "free-list", rows: [row]))]))
    }

    /// A service's name; the purgeable documents are named after the cloud service that holds them, once it is known.
    static func title(_ id: String, _ snapshot: PurgeableSnapshot) -> String {
        guard id == CacheDeleteService.fsPurgeableDocument, !snapshot.documents.isEmpty else { return PurgeableService.describe(id).title }
        return snapshot.documents.count == 1 ? "\(snapshot.documents[0].name) files on this Mac" : "Cloud files on this Mac"
    }

    /// The purgeable documents as rows: one per cloud service that holds them, opening in place onto its folders (no page of its
    /// own: the row already sits in a group's page), and what no cloud folder accounts for. nil while none were found.
    static func documentsRows(_ bytes: UInt64, _ snapshot: PurgeableSnapshot) -> [Row]? {
        guard !snapshot.documents.isEmpty else { return nil }
        let detail = "Files downloaded from the cloud and kept there. macOS may delete these local copies when the disk runs low; they download again when opened. In Finder, Free Up Space removes a folder's copies now, and Always Keep on This Device takes it out of this figure."
        // The rows add up to macOS's figure: where the files found come to more (read at another moment, or flagged at an urgency
        // macOS does not count), each cloud service gets its share of it. Its folders keep the sizes found.
        let found = snapshot.documents.map(\.bytes).reduce(0, +)
        func share(_ source: PurgeableDocuments.Source) -> UInt64 {
            found > bytes ? UInt64((Double(bytes) * Double(source.bytes) / Double(max(found, 1))).rounded()) : source.bytes
        }
        var rows = snapshot.documents.map { source in
            Row(id: "documents:\(source.path)", title: "\(source.name) files on this Mac", subtitle: source.files == 1 ? "1 file" : "\(source.files) files",
                trailing: ByteFormat.string(share(source)), symbol: "icloud.and.arrow.down", detail: detail,
                steps: source.folders.filter { $0.bytes >= threshold }.map { "\($0.name): \(ByteFormat.string($0.bytes)), \($0.files == 1 ? "1 file" : "\($0.files) files")" })
        }
        // What no cloud folder accounts for is named.
        if bytes > found, bytes - found >= threshold * 10 {
            let service = PurgeableService.describe(CacheDeleteService.fsPurgeableDocument)
            rows.append(Row(id: CacheDeleteService.fsPurgeableDocument, title: "Other purgeable documents", trailing: ByteFormat.string(bytes - found),
                            symbol: service.symbol, detail: service.detail))
        }
        return rows
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
            if entry.key == CacheDeleteService.fsPurgeableDocument, let rows = documentsRows(entry.value, snapshot) { return rows }
            return [Row(id: entry.key, title: service.title, trailing: ByteFormat.string(entry.value), symbol: service.symbol, detail: service.detail)]
        }
        return .section(SectionWidget(id: "kept", title: "Left alone", subtitle: "Counted as purgeable by macOS, but not worth freeing or not tested.",
                                      widgets: [.list(ListWidget(id: "kept-list", rows: rows))]))
    }
}
