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
                title: "macOS's purge service is not available",
                message: "CacheDelete is missing or failed its self-test on this macOS build, so nothing can be measured or freed here."))])
        }
        var widgets: [ScreenWidget] = []
        if let free = freeNow(snapshot) { widgets.append(free) }
        if let kept = keptSection(snapshot) { widgets.append(kept) }
        let hero = UsageBar(id: "purgeable", title: "What macOS counts as purgeable", totalBytes: snapshot.totalBytes, segments: segments(snapshot),
                            footnote: "Asked from macOS's purge service at the urgency behind the disk's \"purgeable\" figure.")
        return Screen(title: "Other System Files", hero: hero, primary: freeAction(snapshot, prominent: true), widgets: widgets)
    }

    /// "Up to": the size is macOS's estimate, which counts far more than macOS then deletes (900 MB estimated, 11 MB removed).
    static func freeAction(_ snapshot: PurgeableSnapshot, prominent: Bool) -> Action? {
        let bytes = snapshot.freeableBytes
        guard bytes >= threshold else { return nil }
        let size = ByteFormat.string(bytes)
        return Action(id: "purgeFiles", title: prominent ? "Free up to \(size)" : "Remove", symbol: prominent ? "sparkles" : nil,
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
            return Row(id: entry.key, title: service.title, trailing: ByteFormat.string(entry.value), symbol: service.symbol, detail: detail)
        }
        return .section(SectionWidget(id: "kept", title: "Left alone", subtitle: "Counted as purgeable by macOS, but not worth freeing or not tested.",
                                      widgets: [.list(ListWidget(id: "kept-list", rows: rows))]))
    }
}
