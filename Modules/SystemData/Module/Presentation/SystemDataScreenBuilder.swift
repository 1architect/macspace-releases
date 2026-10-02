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
        Group(id: "macos", title: "Managed by macOS",
              kinds: [.logs, .symbolCache, .spotlightIndex, .spotlightMetadata, .systemAssets, .snapshot, .diagnosticReports]),
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
        let elsewhere = snapshot.report.items.filter { countedElsewhere.contains($0.kind) }.compactMap(\.bytes).reduce(0, +)
        let otherCategory = snapshot.report.items.filter(countedByAnotherCategory).compactMap(\.bytes).reduce(0, +)
        if otherCategory > 0 { footnote += " \(ByteFormat.string(otherCategory)) of cloud copies, downloads, virtual machines and apps' own data are not counted: System Settings lists them under Documents and Applications." }
        if elsewhere > 0 { footnote += " \(ByteFormat.string(elsewhere)) of developer tools and swap are not counted: System Settings lists them under Developer and macOS." }
        let skipped = quietlySkipped(snapshot)
        if skipped > 0 { footnote += skipped == 1 ? " 1 place macOS keeps private was skipped." : " \(skipped) places macOS keeps private were skipped." }
        return UsageBar(id: "usage", title: "What fills System Data", segments: segments, footnote: footnote)
    }

    /// Bytes MacSpace can free right now without the user doing anything in another app. Caches of apps that are open
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

        if let banner = partialBanner(snapshot) { widgets.append(banner) }
        widgets.append(.usage(usage(snapshot)))
        widgets.append(freeNow(snapshot))
        let manual = manualSection(report)
        if let manual { widgets.append(manual) }
        if let versions = versionsSection(snapshot) { widgets.append(versions) }
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
                confirmation: Confirmation(title: "Free everything listed?", message: "Deletes the system caches, old reports, unused system assets above. None of it holds your files.", confirmTitle: "Free all")),
                footnote: "The space actually freed is measured on the volume afterwards.")))
        }
        return .section(SectionWidget(id: "free", title: "Free now", subtitle: "MacSpace can do these without you opening another app.", widgets: widgets))
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

    /// The saved history behind File > Revert To > Browse All Versions. Deleting it is irreversible, so it sits apart from "Free now".
    static func versionsSection(_ snapshot: SystemDataSnapshot) -> ScreenWidget? {
        guard let item = snapshot.report.items.first(where: { $0.id == "versions:documents" }), let bytes = item.bytes, bytes > 0 else { return nil }
        let size = ByteFormat.string(bytes)
        let row = Row(id: "versions", title: "Document version history", subtitle: "Saved earlier versions of documents (File → Revert To → Browse All Versions).",
                      trailing: size, badge: Badge("Cannot be undone", tone: .critical), symbol: "clock.arrow.circlepath",
                      detail: "Deleting it removes the earlier versions of every document. The documents themselves stay. Versions share blocks with their documents, so the space freed can be less than \(size); MacSpace measures what the volume gains. Save your documents and quit apps that edit them first.",
                      actions: [Action(id: "deleteVersions", title: "Delete…", role: .destructive,
                                       confirmation: Confirmation(title: "Delete all version history?",
                                                                  message: "This permanently removes the earlier versions of every document on this Mac (\(size) stored). You will no longer be able to revert documents to earlier states. The documents themselves are not touched.\n\nSave and close your documents first. MacSpace stops the macOS versions service, deletes the store and starts the service again.",
                                                                  confirmTitle: "Delete version history"),
                                       requires: [.privilegedHelper])])
        return .section(SectionWidget(id: "versions", title: "Version history", subtitle: "Irreversible. Use it only if you never revert documents.",
                                      widgets: [.list(ListWidget(id: "versions-list", rows: [row]))], isCollapsible: true, startsCollapsed: false))
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

    /// Unreadable places the user can do something about: all of them without Full Disk Access, and the root-only ones until the helper
    /// has measured them or been reached. What macOS keeps closed even to Full Disk Access and the helper (some Apple containers, for
    /// example) is not something to warn about: no customer can fix it, so it only shows as a quiet note under the bar.
    static func actionableUnreadable(_ snapshot: SystemDataSnapshot) -> (fullDiskAccess: [String], helper: [String], helperUnreachable: [String]) {
        let paths = snapshot.report.unreadable
        let rootOnly = paths.filter(RootMeasuredLocations.allowed.contains)
        let other = paths.filter { !RootMeasuredLocations.allowed.contains($0) }
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
        var parts: [String] = []
        var action: Action?
        if !actionable.fullDiskAccess.isEmpty {
            parts.append("MacSpace needs Full Disk Access to include: \(unreadableList(actionable.fullDiskAccess)).")
            action = Action(id: "openFullDiskAccess", title: "Open Full Disk Access", role: .prominent)
        }
        if !actionable.helper.isEmpty {
            parts.append("Turn on the helper in Settings to include: \(unreadableList(actionable.helper)). Full Disk Access does not cover them.")
        }
        if !actionable.helperUnreachable.isEmpty {
            parts.append("The helper could not be reached, so these were not measured: \(unreadableList(actionable.helperUnreachable)). Reopen MacSpace; if it persists, remove and install the helper again in Settings.")
        }
        guard !parts.isEmpty else { return nil }
        parts.append("The numbers below are a lower bound until then.")
        return .banner(Banner(id: "partial", severity: .info, title: "Some locations were not measured", message: parts.joined(separator: " "), action: action))
    }

    /// Up to four locations, home folder shortened, so the user can see what is missing.
    static func unreadableList(_ paths: [String]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = paths.prefix(4).map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
        return shown.joined(separator: ", ") + (paths.count > 4 ? " and \(paths.count - 4) more" : "")
    }

    static let assetsThreshold: UInt64 = 50_000_000

    static func freeNowHasAssets(_ snapshot: SystemDataSnapshot) -> Bool { (snapshot.purgeableAssetsBytes ?? 0) >= assetsThreshold }

    /// What fills System Data but cannot be reduced here. Anything with a button lives in "Free now" instead.
    static func managedSection(_ report: SystemDataReport, assetsListed: Bool = false) -> ScreenWidget? {
        let handledElsewhere: Set<String> = assetsListed ? ["reports:diagnostic", "assets:system", "versions:documents"] : ["reports:diagnostic", "versions:documents"]
        let items = report.items.filter { $0.cleanup.kind == .managedByMacOS || $0.cleanup.kind == .command }
            .filter { ($0.bytes ?? 0) > 0 && !handledElsewhere.contains($0.id) }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        guard !items.isEmpty else { return nil }
        let rows = items.map { item in
            Row(id: item.id, title: item.title, trailing: item.kind == .codeSignClone ? "~0 (shared)" : ByteFormat.string(item.bytes ?? 0),
                badge: Badge("macOS"), symbol: "gearshape", detail: ([item.cleanup.description] + item.notes).joined(separator: " "))
        }
        return .section(SectionWidget(id: "managed", title: "Why System Data is large", subtitle: "These are in use or managed by macOS, so MacSpace cannot reduce them. They are listed so the total adds up.",
                                      widgets: [.list(ListWidget(id: "managed-list", rows: rows))], isCollapsible: true, startsCollapsed: true))
    }
}
