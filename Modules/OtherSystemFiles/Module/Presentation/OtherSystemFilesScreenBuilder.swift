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
        return Tile(title: "other system files", status: status, graphic: .blocks(segments(snapshot)),
                    reclaimableBytes: freeable >= threshold ? freeable : nil,
                    purgeableByService: [CacheDeleteService.fsPurgeableData: freeable])
    }

    /// What macOS counts as purgeable, largest first; what MacSpace frees in the caution tone.
    static func segments(_ snapshot: PurgeableSnapshot) -> [UsageSegment] {
        let services = (snapshot.services ?? [:]).filter { $0.value >= threshold || ($0.key == CacheDeleteService.fsPurgeableData && $0.value > 0) }
        return services.sorted { $0.value > $1.value }.enumerated().map { index, entry in
            UsageSegment(id: entry.key, label: PurgeableService.describe(entry.key).title, bytes: entry.value,
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
            let total = (snapshot.services ?? [:]).filter { service in list.rows.contains { $0.id == service.key } }.values.reduce(0, +)
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
                                                 message: "macOS deletes the files apps marked purgeable, as it would when the disk is critically full. If it keeps some for now, MacSpace asks it again in the background. Apps download again what they need.",
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

    /// Everything else macOS counts as purgeable, with why MacSpace leaves it, so the total adds up.
    static func keptSection(_ snapshot: PurgeableSnapshot) -> ScreenWidget? {
        let kept = (snapshot.services ?? [:]).filter { $0.key != CacheDeleteService.fsPurgeableData && $0.value >= threshold }
            .sorted { $0.value > $1.value }
        guard !kept.isEmpty else { return nil }
        let rows = kept.map { entry in
            let service = PurgeableService.describe(entry.key)
            return Row(id: entry.key, title: service.title, trailing: ByteFormat.string(entry.value), symbol: service.symbol, detail: service.detail)
        }
        return .section(SectionWidget(id: "kept", title: "Left alone", subtitle: "Counted as purgeable by macOS, but not worth freeing or not tested.",
                                      widgets: [.list(ListWidget(id: "kept-list", rows: rows))]))
    }
}
