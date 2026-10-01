import Foundation
import MacSpacePlatform
import MacSpaceSdk

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
        Group(id: "appdata", title: "App data and media", kinds: [.appContainer]),
        Group(id: "cloud", title: "Cloud copies", kinds: [.cloudStorage]),
        Group(id: "caches", title: "Caches", kinds: [.appCache, .userSystemCache, .toolCache]),
        Group(id: "support", title: "App support files", kinds: [.appSupport]),
        Group(id: "leftovers", title: "Leftovers", kinds: [.partialDownload, .restoreImage, .virtualMachine, .orphanedHome, .trash, .stagedUpdate]),
        Group(id: "developer", title: "Developer tools", kinds: [.developerTools, .packageManager]),
        Group(id: "macos", title: "Managed by macOS",
              kinds: [.logs, .virtualMemory, .symbolCache, .spotlightIndex, .spotlightMetadata, .systemAssets, .snapshot, .diagnosticReports]),
    ]

    /// Items that count toward the bar. Code-signing clones share storage with their apps, so they are left out.
    static func measured(_ report: SystemDataReport) -> [SystemDataItem] {
        report.items.filter { $0.kind != .codeSignClone && ($0.bytes ?? 0) > 0 }
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
        if !snapshot.report.unreadable.isEmpty { footnote += " \(snapshot.report.unreadable.count) location(s) could not be measured." }
        return UsageBar(id: "usage", title: "What fills System Data", segments: segments, footnote: footnote)
    }

    /// Bytes MACSPACE can free right now without the user doing anything in another app. Caches of apps that are open
    /// are left out: they cannot be cleaned until the app quits.
    static func freeableBytes(_ snapshot: SystemDataSnapshot) -> UInt64 {
        let caches = snapshot.report.items.filter { $0.cleanup.kind == .deleteWhenNotRunning && !$0.inUse }
            .compactMap(\.expectedReclaimBytes).reduce(0, +)
        return caches + (snapshot.purgeableAssetsBytes ?? 0) + snapshot.reports.totalBytes
    }

    static func summary(_ snapshot: SystemDataSnapshot) -> ScreenWidget {
        var usage = usage(snapshot)
        usage.title = "System Data"
        let freeable = freeableBytes(snapshot)
        usage.footnote = freeable > 0 ? "\(ByteFormat.string(freeable)) can be freed now." : "Nothing safe to clean right now."
        return .usage(usage)
    }

    static func screen(_ snapshot: SystemDataSnapshot) -> Screen {
        let report = snapshot.report
        var widgets: [ScreenWidget] = []

        if !report.unreadable.isEmpty {
            widgets.append(.banner(Banner(id: "partial", severity: .info, title: "Some locations were not measured",
                                          message: "Grant Full Disk Access in Settings to include them. The numbers below are a lower bound.")))
        }
        widgets.append(.usage(usage(snapshot)))
        widgets.append(freeNow(snapshot))
        let manual = manualSection(report)
        if let manual { widgets.append(manual) }
        if let assets = assetsSection(snapshot) { widgets.append(assets) }
        if let review = reviewSection(report) { widgets.append(review) }
        if let managed = managedSection(report, assetsListed: freeNowHasAssets(snapshot) || !snapshot.assetFamilies.isEmpty) { widgets.append(managed) }
        return Screen(title: "System Data", subtitle: "What fills System Data, and what you can safely free.", widgets: widgets)
    }

    // MARK: Sections

    static func freeNow(_ snapshot: SystemDataSnapshot) -> ScreenWidget {
        let cleanable = snapshot.report.items.filter { $0.cleanup.kind == .deleteWhenNotRunning && ($0.expectedReclaimBytes ?? 0) > 0 }
            .sorted { ($0.expectedReclaimBytes ?? 0) > ($1.expectedReclaimBytes ?? 0) }
        var rows = cleanable.map { item -> Row in
            Row(id: item.id, title: item.title, subtitle: item.inUse ? "Quit \(item.owners.joined(separator: ", ")) first." : item.cleanup.description,
                trailing: ByteFormat.string(item.expectedReclaimBytes ?? 0),
                badge: item.inUse ? Badge("App is open", tone: .caution) : Badge("Safe", tone: .positive), symbol: "internaldrive",
                actions: item.inUse ? [] : [Action(id: "clean", title: "Clean", parameters: ["id": item.id])])
        }
        if snapshot.reports.totalBytes > 0 {
            rows.append(Row(id: "reports", title: "Old diagnostic and crash reports",
                            subtitle: "\(snapshot.reports.candidates.count) report(s) older than \(snapshot.reports.olderThanDays) days. Nothing reads them back.",
                            trailing: ByteFormat.string(snapshot.reports.totalBytes), badge: Badge("Safe", tone: .positive), symbol: "doc.text",
                            actions: [Action(id: "cleanReports", title: "Clean", confirmation: Confirmation(
                                title: "Delete old reports?", message: "This permanently deletes \(snapshot.reports.candidates.count) report file(s).", confirmTitle: "Delete"))]))
        }
        if let assets = snapshot.purgeableAssetsBytes, assets >= assetsThreshold {
            rows.append(Row(id: "assets", title: "Unused system assets", subtitle: "Downloads macOS no longer needs, such as Apple Intelligence models released by the off-switch. macOS deletes them only when the disk is nearly full; this does it now. Anything needed again is downloaded again.",
                            trailing: ByteFormat.string(assets), badge: Badge("Safe", tone: .positive), symbol: "square.stack.3d.down.right",
                            actions: [Action(id: "purgeAssets", title: "Remove", confirmation: Confirmation(
                                title: "Remove unused system assets?", message: "macOS deletes the assets it no longer needs, about \(ByteFormat.string(assets)).", confirmTitle: "Remove"))]))
        }
        var widgets: [ScreenWidget] = [.list(ListWidget(id: "free-list", emptyMessage: "Nothing safe to clean right now.", rows: rows))]
        let total = freeableBytes(snapshot)
        if rows.count > 1 && total > 0 {
            widgets.append(.button(ButtonWidget(id: "free-all", action: Action(
                id: "cleanAll", title: "Free all (\(ByteFormat.string(total)))", symbol: "sparkles", role: .prominent,
                confirmation: Confirmation(title: "Free everything listed?", message: "Deletes the system caches, old reports and unused system assets above. None of it holds your files.", confirmTitle: "Free all")),
                footnote: "The space actually freed is measured on the volume afterwards.")))
        }
        return .section(SectionWidget(id: "free", title: "Free now", subtitle: "MACSPACE can do these without you opening another app.", widgets: widgets))
    }

    static func manualSection(_ report: SystemDataReport) -> ScreenWidget? {
        guard !report.manualCleanup.isEmpty else { return nil }
        let rows = report.manualCleanup.map { entry in
            Row(id: "manual:\(entry.app)", title: entry.app, subtitle: entry.guide.frees,
                trailing: entry.bytes.map(ByteFormat.string) ?? "not measured", badge: Badge("Manual", tone: .caution), symbol: "hand.point.up.left",
                detail: entry.guide.verified ? nil : "Menu names can differ between app versions.", steps: entry.guide.steps)
        }
        return .section(SectionWidget(id: "manual", title: "Clean up manually",
                                      subtitle: "Only the app itself, or you, should remove this. Expand a row for the steps.",
                                      widgets: [.list(ListWidget(id: "manual-list", rows: rows))]))
    }

    /// Large items with no guide and no safe cleanup: shown so nothing hides in the total.
    static func reviewSection(_ report: SystemDataReport) -> ScreenWidget? {
        let guided = Set(report.manualCleanup.flatMap(\.itemIDs))
        let items = report.items.filter { $0.cleanup.kind == .review && !guided.contains($0.id) && !$0.id.hasPrefix("small:") && ($0.bytes ?? 0) > 0 }
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }.prefix(8)
        guard !items.isEmpty else { return nil }
        let rows = items.map { Row(id: $0.id, title: $0.title, trailing: ByteFormat.string($0.bytes ?? 0), badge: Badge("Review"), symbol: "magnifyingglass", detail: $0.cleanup.description) }
        return .section(SectionWidget(id: "review", title: "Worth a look", subtitle: "These belong to apps or to you.",
                                      widgets: [.list(ListWidget(id: "review-list", rows: Array(rows)))], isCollapsible: true, startsCollapsed: true))
    }

    /// What the system assets are, who keeps them, and the setting that releases each group.
    static func assetsSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        guard !snapshot.assetFamilies.isEmpty else { return nil }
        let rows = snapshot.assetFamilies.map { family -> Row in
            var notes: [String] = ["Includes: " + family.assets.prefix(6).joined(separator: ", ") + (family.assets.count > 6 ? " and \(family.assets.count - 6) more." : ".")]
            if !family.steps.isEmpty && !family.verified { notes.append("Menu names can differ between macOS versions.") }
            return Row(id: "assets:\(family.id)", title: family.title, subtitle: family.heldBy, trailing: ByteFormat.string(family.bytes),
                       badge: family.steps.isEmpty ? Badge("No setting") : Badge("Setting", tone: .caution), symbol: "square.stack.3d.down.right",
                       detail: notes.joined(separator: " "), steps: family.steps)
        }
        return .section(SectionWidget(id: "assets", title: "System assets", subtitle: "Downloads macOS keeps while a feature uses them. Change the setting, restart, then remove unused assets.",
                                      widgets: [.list(ListWidget(id: "assets-list", rows: rows))], isCollapsible: true, startsCollapsed: false))
    }

    static let assetsThreshold: UInt64 = 50_000_000

    static func freeNowHasAssets(_ snapshot: SystemDataSnapshot) -> Bool { (snapshot.purgeableAssetsBytes ?? 0) >= assetsThreshold }

    /// What fills System Data but cannot be reduced here. Anything with a button lives in "Free now" instead.
    static func managedSection(_ report: SystemDataReport, assetsListed: Bool = false) -> ScreenWidget? {
        let handledElsewhere: Set<String> = assetsListed ? ["reports:diagnostic", "assets:system"] : ["reports:diagnostic"]
        let items = report.items.filter { $0.cleanup.kind == .managedByMacOS || $0.cleanup.kind == .command }
            .filter { ($0.bytes ?? 0) > 0 && !handledElsewhere.contains($0.id) }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        guard !items.isEmpty else { return nil }
        let rows = items.map { item in
            Row(id: item.id, title: item.title, trailing: item.kind == .codeSignClone ? "~0 (shared)" : ByteFormat.string(item.bytes ?? 0),
                badge: Badge("macOS"), symbol: "gearshape", detail: ([item.cleanup.description] + item.notes).joined(separator: " "))
        }
        return .section(SectionWidget(id: "managed", title: "Why System Data is large", subtitle: "These are in use or managed by macOS, so MACSPACE cannot reduce them. They are listed so the total adds up.",
                                      widgets: [.list(ListWidget(id: "managed-list", rows: rows))], isCollapsible: true, startsCollapsed: true))
    }
}
