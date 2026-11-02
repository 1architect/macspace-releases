import Foundation
import Darwin
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceDiskMapPrivileged

/// The same Screen, UsageBar and row contracts as the other storage modules. No custom page styling.
enum DiskMapScreenBuilder {
    static func fileID(_ path: String) -> String { "file:" + Data(path.utf8).base64EncodedString() }
    static func folderID(_ path: String) -> String { "folder:" + path }
    static func largeID(_ path: String) -> String { "large:" + path }
    static func largeFiles(_ index: DiskIndex, folder: String, files: [DiskFile]? = nil) -> [DiskFile] {
        (files ?? index.largeFiles).filter { index.contains($0.path, below: folder) && !$0.path.contains("/.Trash/") && !$0.path.contains("/.Trashes/") }
    }
    static func tile(_ index: DiskIndex, files: [DiskFile]? = nil) -> Tile {
        Tile(title: loc("disk"), figure: ByteFormat.string(index.directories[index.root]?.bytes ?? 0), status: loc("Explore disk"),
             graphic: .blocks(segments(index, folder: index.root, files: files)), refreshAfter: 5)
    }
    static func screen(_ index: DiskIndex, apps: DiskApplications, folder: String? = nil, files catalog: [DiskFile]? = nil) -> Screen {
        let folder = folder ?? index.root
        var widgets: [ScreenWidget] = []
        if folder == index.root {
            let installed = apps.apps.filter { $0.classification == .installedUser }
            let leftovers = apps.reviewableLeftovers.reduce(UInt64(0)) { $0 + $1.bytes }
            let rows = [Row(id: "apps", title: loc("Uninstall apps"), subtitle: apps.catalogReadAt == .distantPast ? nil : loc("\(installed.count) items"), pageID: "apps"),
                        Row(id: "leftovers", title: loc("Leftovers from removed apps"), trailing: ByteFormat.string(leftovers),
                            detail: loc("These identifiers were not matched to the discovered apps. Ownership is uncertain, so this data is kept for review."), pageID: "app-data-review")]
            widgets.append(.list(ListWidget(id: "apps-class", title: loc("Apps"), rows: rows)))
        }
        let files = largeFiles(index, folder: folder, files: catalog)
        var rows = files.map(fileRow)
        rows.append(Row(id: largeID(folder), title: loc("More items"), subtitle: loc("Files of 100 MB or larger"), pageID: largeID(folder)))
        widgets.append(.list(ListWidget(id: "large-class", title: loc("Large files"), rows: rows, fillsRemainingSpace: true)))
        let node = index.directories[folder]
        let title = folder == index.root ? loc("Disk") : (DiskApplications.livePath(folder) as NSString).lastPathComponent
        return Screen(title: title, hero: UsageBar(id: folderID(folder), title: title, totalBytes: folder == index.root ? index.volumeUsed ?? node?.bytes : node?.bytes,
             segments: segments(index, folder: folder, files: catalog), footnote: loc("Local allocated space. Cloud-only files are not downloaded. Protected or unreadable locations may be incomplete; APFS clones and snapshots can make this differ from disk usage.")), widgets: widgets, selection: fileSelection(files, folder: folder))
    }
    static func segments(_ index: DiskIndex, folder: String, files catalog: [DiskFile]? = nil) -> [UsageSegment] {
        guard let node = index.directories[folder] else { return [] }
        var parts = node.folders.sorted().enumerated().compactMap { n, path -> UsageSegment? in
            guard let dir = index.directories[path], dir.bytes > 0 else { return nil }
            return UsageSegment(id: path, label: (path as NSString).lastPathComponent, bytes: dir.bytes, tone: .series(n), pageID: folderID(path))
        }
        let files = (catalog ?? index.largeFiles).filter { ($0.path as NSString).deletingLastPathComponent == folder }
        for file in files { parts.append(UsageSegment(id: file.path, label: (file.path as NSString).lastPathComponent, bytes: file.bytes, tone: .series(parts.count), items: [fileRow(file)])) }
        let direct = node.bytes - min(node.bytes, node.folders.reduce(0) { $0 + (index.directories[$1]?.bytes ?? 0) })
        let other = direct - min(direct, files.reduce(0) { $0 + $1.bytes })
        if other > 0 { parts.append(UsageSegment(id: folder + ":files", label: loc("Other files"), bytes: other, tone: .series(parts.count))) }
        if folder == index.root, let used = index.volumeUsed, used > node.bytes {
            parts.append(UsageSegment(id: "unmeasured", label: loc("Protected and other disk usage"), bytes: used - node.bytes, tone: .neutral))
        }
        return parts.sorted { $0.bytes > $1.bytes }
    }
    static func appsPage(_ index: DiskIndex, apps: DiskApplications) -> Screen {
        let installed = apps.apps.filter { $0.classification == .installedUser }
        let other = apps.apps.filter { $0.classification != .installedUser }
        var rows = installed.map(appRow)
        if !other.isEmpty {
            rows.append(Row(id: "other-installations", title: loc("System components and other copies"), subtitle: loc("\(other.count) items"), pageID: "other-apps"))
        }
        return Screen(title: loc("Uninstall apps"), layout: .singleColumn, widgets: [.list(ListWidget(id: "installed-apps", title: loc("Apps"), emptyMessage: apps.catalogReadAt == .distantPast ? loc("Reading apps…") : loc("No apps found"), rows: rows))])
    }
    static func appRow(_ app: DiskApplication) -> Row {
        let action: Action? = app.removable ? app.plan.flatMap { plan in
            guard let encoded = try? plan.encoded() else { return nil }
            return Action(id: "uninstall", title: loc("Uninstall"), role: .destructive,
                parameters: ["app": app.owner.path, "identifier": app.owner.identifier, "plan": encoded],
                confirmation: Confirmation(title: loc("Uninstall \(app.owner.name)?"),
                    message: loc("Only the following reviewed targets will be removed. Shared, inferred and unknown data is preserved.") + "\n\n" + plan.targets.map(\.path).joined(separator: "\n"), confirmTitle: loc("Uninstall")),
                requires: [.fullDiskAccess, .privilegedHelper], workingTitle: loc("Uninstalling"))
        } : nil
        let hasData = app.ownership.contains { $0.source != "bundle" }
        return Row(id: app.owner.path, title: app.owner.name, trailing: ByteFormat.string(app.bytes + (app.ownershipBytes[.verifiedExclusive] ?? 0)),
            detail: app.owner.identifier + "\n" + eligibilityReason(app.classification), actions: action.map { [$0] } ?? [], paths: [app.owner.path], iconPath: app.owner.path, pageID: !hasData ? nil : "app:" + Data(app.owner.path.utf8).base64EncodedString())
    }
    static func otherAppsPage(_ apps: DiskApplications) -> Screen {
        Screen(title: loc("System components and other copies"), layout: .singleColumn,
            widgets: [.list(ListWidget(id: "other-apps", rows: apps.apps.filter { $0.classification != .installedUser }.map(appRow)))])
    }
    static func appDataPage(_ app: DiskApplication) -> Screen {
        let groups = [OwnershipConfidence.verifiedExclusive, .shared, .inferred, .unknown].compactMap { confidence -> Row? in
            let claims = app.ownership.filter { $0.source != "bundle" && $0.confidence == confidence }
            guard !claims.isEmpty else { return nil }
            let paths = Array(Set(claims.flatMap(\.paths))).sorted()
            return Row(id: app.owner.path + ":" + confidence.rawValue, title: ownershipTitle(confidence), trailing: ByteFormat.string(app.ownershipBytes[confidence] ?? 0),
                detail: ownershipExplanation(confidence), children: paths.map { Row(id: $0, title: ($0 as NSString).lastPathComponent, paths: [$0]) })
        }
        return Screen(title: app.owner.name, layout: .singleColumn, widgets: [.list(ListWidget(id: "app-data", rows: groups))])
    }
    static func eligibilityReason(_ classification: AppClassification) -> String {
        switch classification {
        case .installedUser: loc("Installed app. Removal is limited to the exact reviewed targets.")
        case .protectedSystem: loc("Protected system component; cannot be removed here.")
        case .background: loc("Background component; its removal needs a separate lifecycle.")
        case .extraCopy: loc("Additional or unconfirmed app copy; kept separate from installed apps.")
        case .macSpaceLifecycle: loc("Use MacSpace’s uninstall option in Settings.")
        }
    }
    static func ownershipTitle(_ confidence: OwnershipConfidence) -> String {
        switch confidence {
        case .verifiedExclusive: loc("Verified app data")
        case .shared: loc("Shared data")
        case .inferred: loc("Possible app data")
        case .unknown: loc("Uncertain ownership")
        }
    }
    static func ownershipExplanation(_ confidence: OwnershipConfidence) -> String {
        switch confidence {
        case .verifiedExclusive: loc("Evidence identifies this installation as the exclusive owner.")
        case .shared: loc("Other app installations also claim this data. It is preserved.")
        case .inferred: loc("The identifier or location suggests an association, but does not prove ownership. It is preserved.")
        case .unknown: loc("Available metadata cannot establish exclusive ownership. It is preserved.")
        }
    }
    static func leftoversPage(_ apps: DiskApplications) -> Screen {
        let rows = apps.reviewableLeftovers.map { leftover in
            Row(id: leftover.identifier, title: leftover.identifier, trailing: ByteFormat.string(leftover.bytes),
                detail: loc("These identifiers were not matched to the discovered apps. Ownership is uncertain, so this data is kept for review."),
                children: leftover.paths.map { Row(id: $0, title: ($0 as NSString).lastPathComponent, paths: [$0]) })
        }
        return Screen(title: loc("Leftovers from removed apps"), layout: .singleColumn, widgets: [.list(ListWidget(id: "reviewable-app-data", emptyMessage: loc("No unmatched app data found"), rows: rows))])
    }
    static func allLargePage(_ index: DiskIndex, folder: String, files catalog: [DiskFile]? = nil) -> Screen {
        let files = largeFiles(index, folder: folder, files: catalog)
        return Screen(title: loc("Large files"), layout: .singleColumn, widgets: [.list(ListWidget(id: "all-large", title: loc("Files of 100 MB or larger"), emptyMessage: loc("No large files in this folder"), rows: files.map(fileRow)))], selection: fileSelection(files, folder: folder))
    }
    static func canDelete(_ path: String) -> Bool {
        let live = DiskApplications.livePath(path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var st = stat()
        return live.hasPrefix(home + "/") && !live.contains(".app/") && !live.contains("/.Trash/")
            && lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && st.st_uid == getuid()
            && URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
    }
    /// Eligibility is measured once; deletion revalidates against the filesystem immediately before acting.
    static func selectable(_ file: DiskFile) -> Bool {
        guard let uid = file.ownerUID else { return false }
        let path = DiskApplications.livePath(file.path)
        return uid == getuid() && path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/")
            && !path.contains(".app/") && !path.contains("/.Trash/")
    }
    static func fileSelection(_ files: [DiskFile], folder: String) -> Selection {
        let candidates = files.filter { selectable($0) }
        return Selection(action: Action(id: "freeFiles", title: loc("Free selected"), role: .prominent, parameters: ["folder": folder],
            confirmation: Confirmation(title: loc("Free the selected files?"), message: loc("This permanently deletes the selected files."), confirmTitle: loc("Free")),
            requires: [.fullDiskAccess], workingTitle: loc("Freeing space")),
            choices: Dictionary(candidates.map { (fileID($0.path), $0.bytes) }, uniquingKeysWith: { first, _ in first }),
            scope: folderID(folder))
    }
    static func fileRow(_ file: DiskFile) -> Row {
        Row(id: fileID(file.path), title: (file.path as NSString).lastPathComponent, trailing: ByteFormat.string(file.logicalBytes),
            paths: [DiskApplications.livePath(file.path)])
    }
}
