import Foundation
import Darwin
import MacSpacePlatform
import MacSpaceSdk
import MacSpaceDiskMapPrivileged

/// The same Screen, UsageBar and row contracts as the other storage modules. No custom page styling.
enum DiskMapScreenBuilder {
    static func fileID(_ path: String) -> String { DiskFileRemoval.id(path) }
    static func folderID(_ path: String) -> String { "folder:" + path }
    static func tile(_ index: DiskIndex, files: [DiskFile]? = nil) -> Tile {
        Tile(title: loc("disk"), figure: ByteFormat.string(index.directories[index.root]?.bytes ?? 0), status: loc("Explore disk"),
             graphic: .blocks(segments(index, folder: index.root, files: files)), refreshAfter: 5)
    }
    static func screen(_ index: DiskIndex, apps: DiskApplications, folder: String? = nil, files catalog: [DiskFile]? = nil) -> Screen {
        let folder = folder ?? index.root
        var widgets: [ScreenWidget] = []
        if folder == index.root || FileReviewPolicy.applicationsFolder(folder) {
            let appFolder = folder == index.root ? nil : folder
            let installed = applications(apps, folder: appFolder).filter { $0.classification == .installedUser }
            var rows = [Row(id: "apps", title: loc("Uninstall apps"), subtitle: apps.catalogReadAt == .distantPast ? nil : loc("\(installed.count) items"), pageID: appsPageID(folder: appFolder))]
            rows.append(Row(id: "leftovers", title: loc("Unmatched app data"),
                subtitle: apps.catalogReadAt == .distantPast ? nil : loc("\(apps.reviewableLeftovers.count) items"),
                trailing: apps.catalogReadAt == .distantPast ? nil : ByteFormat.string(apps.reviewableLeftovers.reduce(0) { $0 + $1.bytes }),
                badges: appFolder == nil ? [] : [Badge(loc("All locations"), .info)], detail: unmatchedExplanation, pageID: "app-data-review"))
            widgets.append(.list(ListWidget(id: "apps-class", title: loc("Apps"), rows: rows)))
        }
        if folder == index.root {
            widgets.append(.list(ListWidget(id: "personal-folders", title: loc("Folders"), rows: (index.personalFolders ?? []).map {
                Row(id: $0.path, title: ($0.path as NSString).lastPathComponent, trailing: ByteFormat.string($0.bytes),
                    paths: [FileReviewPolicy.livePath($0.path)], pageID: folderID($0.path))
            })))
        }
        let categories = DiskCategory.inventoryCategories.compactMap { category -> Row? in
            guard let summary = index.categories?.first(where: { $0.category == category }), summary.count > 0 else { return nil }
            let request = DiskBrowseRequest(folder: folder, kind: .category, category: category)
            return Row(id: request.pageID, title: category.title, subtitle: loc("\(Int(clamping: summary.count)) items"),
                trailing: ByteFormat.string(summary.bytes), pageID: request.pageID)
        }
        let duplicates = DiskBrowseRequest(folder: folder, kind: .duplicates)
        var duplicateBadges: [Badge] = []
        if index.duplicateFailure == true {
            duplicateBadges.append(Badge(loc("Verification incomplete"), .info, help: loc("Some files could not be verified. Refresh to retry.")))
        } else if let unknown = index.duplicateUnknown, unknown > 0 {
            duplicateBadges.append(Badge(loc("Some files not verified"), .info, help: loc("Only verified identical copies are offered for removal.")))
        }
        let duplicateCount = folder == index.root && (index.duplicateCount ?? 0) > 0 ? index.duplicateCount : nil
        let duplicateRow = Row(id: duplicates.pageID, title: loc("Duplicate files"),
            subtitle: duplicateCount.map { loc("\(Int(clamping: $0)) items") },
            trailing: duplicateCount == nil ? nil : index.duplicateBytes.map(ByteFormat.string), badges: duplicateBadges,
            detail: loc("Identical local personal files are grouped with one retained copy. No files are preselected."), pageID: duplicates.pageID)
        widgets.append(.list(ListWidget(id: "large-files", title: loc("Large files and duplicates"), rows: [duplicateRow] + categories, paths: [FileReviewPolicy.livePath(folder)])))
        if index.loadError == true {
            widgets.append(.banner(Banner(id: "file-inventory-error", severity: .warning,
                title: loc("Categories unavailable"), message: loc("Category preparation failed. The previous disk map is still available. Refresh to retry."))))
        }
        let node = index.directories[folder]
        let title = folder == index.root ? loc("Disk") : (DiskApplications.livePath(folder) as NSString).lastPathComponent
        return Screen(title: title, hero: UsageBar(id: folderID(folder), title: title, totalBytes: folder == index.root ? index.volumeUsed ?? node?.bytes : node?.bytes,
             segments: segments(index, folder: folder, files: catalog), footnote: loc("Local allocated space. Cloud-only files are not downloaded. Protected or unreadable locations may be incomplete; APFS clones and snapshots can make this differ from disk usage.")), widgets: widgets, selection: fileSelection([]))
    }
    static func segments(_ index: DiskIndex, folder: String, files catalog: [DiskFile]? = nil) -> [UsageSegment] {
        guard let node = index.directories[folder] else { return [] }
        var parts = node.folders.sorted().enumerated().compactMap { n, path -> UsageSegment? in
            guard let dir = index.directories[path] else { return nil }
            return UsageSegment(id: path, label: (path as NSString).lastPathComponent, bytes: dir.bytes, tone: .series(n), pageID: folderID(path), kind: .folder)
        }
        let files = (catalog ?? index.largeFiles).filter { ($0.path as NSString).deletingLastPathComponent == folder }
        for file in files { parts.append(UsageSegment(id: file.path, label: (file.path as NSString).lastPathComponent, bytes: file.bytes, tone: .series(parts.count), items: [fileRow(file)], selection: fileSelection([file]))) }
        let direct = node.bytes - min(node.bytes, node.folders.reduce(0) { $0 + (index.directories[$1]?.bytes ?? 0) })
        let other = direct - min(direct, files.reduce(0) { $0 + $1.bytes })
        if other > 0 { parts.append(UsageSegment(id: folder + ":files", label: loc("Other files"), bytes: other, tone: .series(parts.count), pageID: DiskBrowseRequest(folder: folder, kind: .direct).pageID, kind: .files)) }
        if folder == index.root, let used = index.volumeUsed, used > node.bytes {
            parts.append(UsageSegment(id: "unmeasured", label: loc("Protected and other disk usage"), bytes: used - node.bytes, tone: .neutral))
        }
        return parts.sorted { $0.bytes > $1.bytes }
    }
    static func applications(_ apps: DiskApplications, folder: String?) -> [DiskApplication] {
        guard let folder else { return apps.apps }
        let path = FileReviewPolicy.livePath(folder)
        return apps.apps.filter { (FileReviewPolicy.livePath($0.owner.path) as NSString).deletingLastPathComponent == path }
    }
    static func appsPageID(folder: String? = nil, other: Bool = false) -> String {
        let prefix = other ? "other-apps" : "apps"
        return folder.map { prefix + ":" + Data($0.utf8).base64EncodedString() } ?? prefix
    }
    static func appsPage(_ index: DiskIndex, apps: DiskApplications, folder: String? = nil) -> Screen {
        let scoped = applications(apps, folder: folder)
        let installed = scoped.filter { $0.classification == .installedUser }
        let other = scoped.filter { $0.classification != .installedUser }
        var rows = installed.map(appRow)
        if !other.isEmpty {
            rows.append(Row(id: "other-installations", title: loc("System components and other copies"), subtitle: loc("\(other.count) items"), pageID: appsPageID(folder: folder, other: true)))
        }
        return Screen(title: loc("Uninstall apps"), layout: .singleColumn, widgets: [.list(ListWidget(id: "installed-apps", title: loc("Apps"), emptyMessage: apps.catalogReadAt == .distantPast ? loc("Reading apps…") : loc("No apps found"), rows: rows))], selection: fileSelection([]))
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
    static func otherAppsPage(_ apps: DiskApplications, folder: String? = nil) -> Screen {
        Screen(title: loc("System components and other copies"), layout: .singleColumn,
            widgets: [.list(ListWidget(id: "other-apps", rows: applications(apps, folder: folder).filter { $0.classification != .installedUser }.map(appRow)))])
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
    static var unmatchedExplanation: String {
        loc("No installed app was matched to this data. This does not prove the app was removed. Review the locations before selecting user-owned data to free; it may contain documents and settings.")
    }
    static func appDataKind(_ path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent == "Containers" ? loc("App container") : loc("App Data")
    }

    static func leftoversPage(_ apps: DiskApplications) -> Screen {
        let rows = apps.reviewableLeftovers.map { leftover in
            Row(id: leftover.choiceID, title: leftover.identifier, trailing: ByteFormat.string(leftover.bytes),
                badges: [Badge(appDataKind(leftover.path), .info)], paths: [leftover.path])
        }
        let choices = Dictionary(apps.reviewableLeftovers.filter { $0.identity != nil }.map { ($0.choiceID, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        let selection = Selection(action: Action(id: "freeUnmatchedData", title: loc("Free selected"),
            parameters: ["trash": "0"],
            confirmation: Confirmation(title: loc("Free the selected app data?"), message: unmatchedExplanation + "\n\n" + loc("This permanently deletes only the selected app-data folders."), confirmTitle: loc("Delete")),
            requires: [.fullDiskAccess], workingTitle: loc("Freeing space")), choices: choices, scope: "unmatched-app-data")
        return Screen(title: loc("Unmatched app data"), layout: .singleColumn,
            widgets: [.banner(Banner(id: "unmatched-explanation", severity: .warning, title: loc("Review before freeing"), message: unmatchedExplanation)),
                      .list(ListWidget(id: "reviewable-app-data", title: loc("Unmatched app data"), emptyMessage: apps.catalogReadAt == .distantPast ? loc("Reading apps…") : loc("No unmatched app data found"), rows: rows))], selection: selection)
    }

    static func canDelete(_ path: String) -> Bool { DiskFileRemoval.canDelete(path) }
    static func selectable(_ file: DiskFile) -> Bool { !file.retainedDuplicateKeeper && DiskFileRemoval.selectable(file) }
    static func fileSelection(_ files: [DiskFile], open: [String: [OpenFileUse.Reader]]? = nil) -> Selection {
        let inUse = open ?? OpenFileUse.inspect(Set(files.map(\.path)))
        let candidates = files.filter { selectable($0) && inUse[$0.path]?.isEmpty != false }
        let reviewed = Dictionary(candidates.compactMap { file -> (String, String)? in
            guard let identity = file.identity ?? FileReviewIdentity(file.path), let data = try? JSONEncoder().encode(identity),
                  let encoded = String(data: data, encoding: .utf8) else { return nil }
            return (fileID(file.path), encoded)
        }, uniquingKeysWith: { first, _ in first })
        let origins = Dictionary(candidates.compactMap { file -> (String, String)? in
            guard let proof = file.duplicateVerification, let data = try? JSONEncoder().encode(proof) else { return nil }
            return (fileID(file.path), String(decoding: data, as: UTF8.self))
        }, uniquingKeysWith: { first, _ in first })
        let trash = FileRemovalSettings.movesToTrash()
        return Selection(action: Action(id: "freeFiles", title: loc("Free selected"), parameters: ["trash": trash ? "1" : "0"],
            confirmation: Confirmation(title: loc("Free the selected files?"), message: trash ? loc("The selected files will be moved to Trash.") : loc("This permanently deletes the selected files."), confirmTitle: trash ? loc("Move to Trash") : loc("Delete")),
            requires: [.fullDiskAccess], workingTitle: loc("Freeing space")),
            choices: Dictionary(candidates.filter { reviewed[fileID($0.path)] != nil }.map { (fileID($0.path), $0.bytes) }, uniquingKeysWith: { first, _ in first }),
            scope: "disk-files", partial: true, session: true, reviewed: reviewed, origins: origins, bulkResolver: "selection:")
    }
    static func fileRow(_ file: DiskFile) -> Row {
        Row(id: fileID(file.path), title: (file.path as NSString).lastPathComponent, trailing: ByteFormat.string(file.logicalBytes),
            paths: [FileReviewPolicy.livePath(file.path)], unavailableReason: file.retainedDuplicateKeeper ? loc("Retained copy") : (selectable(file) ? nil : loc("This file cannot be deleted here.")))
    }
}
