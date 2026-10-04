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
        return Tile(title: "other system files", status: freeable >= threshold ? "up to \(ByteFormat.string(freeable)) can be freed" : "nothing to free",
                    graphic: .blocks(segments(snapshot)), reclaimableBytes: freeable >= threshold ? freeable : nil)
    }

    /// What macOS counts as purgeable, largest first; what MacSpace frees in the caution tone.
    static func segments(_ snapshot: PurgeableSnapshot) -> [UsageSegment] {
        let services = (snapshot.services ?? [:]).filter { $0.value >= threshold || ($0.key == CacheDeleteService.fsPurgeableData && $0.value > 0) }
        return services.sorted { $0.value > $1.value }.enumerated().map { index, entry in
            let freeable = entry.key == CacheDeleteService.fsPurgeableData && !snapshot.declined
            return UsageSegment(id: entry.key, label: PurgeableService.describe(entry.key).title, bytes: entry.value,
                                tone: freeable ? .caution : .series(index))
        }
    }

    static func screen(_ snapshot: PurgeableSnapshot) -> Screen {
        guard snapshot.services != nil else {
            return Screen(title: "Other System Files", widgets: [.banner(Banner(id: "unavailable", severity: .warning,
                title: "macOS's purge service did not answer",
                message: "CacheDelete is missing on this system or did not answer, so nothing can be measured or freed right now. Refresh to ask again."))])
        }
        // Under the bar, one row per group with its count and total, opening a page with every item (as System Data does).
        var groups: [Row] = []
        for widget in [freeNow(snapshot), keptSection(snapshot)].compactMap({ $0 }) {
            guard case let .section(section) = widget, case let .list(list)? = section.widgets.first else { continue }
            if list.rows.count == 1 { groups.append(list.rows[0]); continue }
            let total = (snapshot.services ?? [:]).filter { service in list.rows.contains { $0.id == service.key } }.values.reduce(0, +)
            groups.append(Row.group(id: "group:\(section.id)", title: section.title, symbol: "tray.full", totalBytes: total, rows: list.rows,
                                    detail: section.subtitle))
        }
        let widgets: [ScreenWidget] = groups.isEmpty ? [] : [.list(ListWidget(id: "groups", title: "What is in it", rows: groups))]
        let hero = UsageBar(id: "purgeable", title: "What macOS counts as purgeable", totalBytes: snapshot.totalBytes, segments: segments(snapshot),
                            footnote: "Asked from macOS's purge service at the urgency behind the disk's \"purgeable\" figure.")
        return Screen(title: "Other System Files", hero: hero, primary: freeAction(snapshot, prominent: true), widgets: widgets)
    }

    /// "Up to": the size is macOS's estimate, which counts far more than macOS then deletes (900 MB estimated, 11 MB removed).
    static func freeAction(_ snapshot: PurgeableSnapshot, prominent: Bool) -> Action? {
        let bytes = snapshot.freeableBytes
        guard bytes >= threshold else { return nil }
        let size = ByteFormat.string(bytes)
        return Action(id: "purgeFiles", title: prominent ? "Free up to \(size)" : "Free", symbol: prominent ? "sparkles" : nil,
                      role: prominent ? .prominent : .normal,
                      confirmation: Confirmation(title: "Free up to \(size) of purgeable app files?",
                                                 message: "macOS deletes the files apps marked purgeable, as it would when the disk is critically full. It decides how much of them goes; what it keeps is then listed as left alone. Apps download again what they need.",
                                                 confirmTitle: "Free"))
    }

    static func freeNow(_ snapshot: PurgeableSnapshot) -> ScreenWidget? {
        guard let action = freeAction(snapshot, prominent: false) else { return nil }
        let service = PurgeableService.describe(CacheDeleteService.fsPurgeableData)
        let row = Row(id: service.id, title: service.title, trailing: ByteFormat.string(snapshot.freeableBytes), symbol: service.symbol,
                      detail: service.detail, actions: [action])
        return .section(SectionWidget(id: "free", title: "Free now", widgets: [.list(ListWidget(id: "free-list", rows: [row]))]))
    }

    /// Everything else macOS counts as purgeable, with why MacSpace leaves it, so the total adds up. Drawn like System Data's lists:
    /// open, one row per service with its symbol, the reason in the row's detail.
    static func keptSection(_ snapshot: PurgeableSnapshot) -> ScreenWidget? {
        // The files apps marked purgeable are left alone too while macOS declines them.
        let kept = (snapshot.services ?? [:]).filter { ($0.key != CacheDeleteService.fsPurgeableData || snapshot.declined) && $0.value >= threshold }
            .sorted { $0.value > $1.value }
        guard !kept.isEmpty else { return nil }
        let rows = kept.map { entry in
            let service = PurgeableService.describe(entry.key)
            let detail = entry.key == CacheDeleteService.fsPurgeableData
                ? "macOS kept these when MacSpace asked it to delete them: it deletes them only when it needs the space. Offered again once its estimate grows."
                : service.detail
            // What macOS kept can always be asked for again: it decides at the moment it is asked, and the disk tile still counts it.
            let again = entry.key == CacheDeleteService.fsPurgeableData
                ? [Action(id: "purgeFiles", title: "Ask again", parameters: ["again": "true"])] : []
            return Row(id: entry.key, title: service.title, trailing: ByteFormat.string(entry.value), symbol: service.symbol, detail: detail,
                       actions: again)
        }
        return .section(SectionWidget(id: "kept", title: "Left alone", subtitle: "Counted as purgeable by macOS, but not worth freeing or not tested.",
                                      widgets: [.list(ListWidget(id: "kept-list", rows: rows))]))
    }
}
