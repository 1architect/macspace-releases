import Foundation
import Darwin
import MacSpacePlatform
import MacSpaceSdk

/// The same Screen, UsageBar and row contracts as the other storage modules. No custom page styling.
enum DiskMapScreenBuilder {
    static func folderID(_ path: String) -> String { "folder:" + path }
    static func largeID(_ path: String) -> String { "large:" + path }
    static func largeFiles(_ index: DiskIndex, folder: String) -> [DiskFile] {
        index.largeFiles.filter { index.contains($0.path, below: folder) && !$0.path.contains("/.Trash/") && !$0.path.contains("/.Trashes/") }
    }
    static func tile(_ index: DiskIndex) -> Tile {
        Tile(title: loc("disk"), figure: ByteFormat.string(index.directories[index.root]?.bytes ?? 0), status: loc("Explore disk"),
             graphic: .blocks(segments(index, folder: index.root)), refreshAfter: 5)
    }
    static func screen(_ index: DiskIndex, apps: DiskApplications, folder: String? = nil) -> Screen {
        let folder = folder ?? index.root
        var widgets: [ScreenWidget] = []
        if folder == index.root {
            let leftovers = apps.leftovers.reduce(0) { $0 + $1.bytes }
            let rows = [Row(id: "apps", title: loc("Uninstall apps"), subtitle: loc("\(apps.apps.count) items"), pageID: "apps"),
                        Row(id: "leftovers", title: loc("Leftovers from removed apps"), trailing: ByteFormat.string(leftovers),
                            detail: loc("Data with exact application identifiers for which no installed app was found. Shared app-group data is preserved."),
                            actions: apps.leftovers.isEmpty ? [] : [Action(id: "freeLeftovers", title: loc("Free"), role: .destructive,
                                confirmation: Confirmation(title: loc("Free leftover app data?"), message: apps.leftovers.flatMap(\.paths).joined(separator: "\n"), confirmTitle: loc("Free")), requires: [.fullDiskAccess], workingTitle: loc("Freeing space"))])]
            widgets.append(.list(ListWidget(id: "apps-class", title: loc("Apps"), rows: rows)))
        }
        var rows = Array(largeFiles(index, folder: folder).prefix(5)).map(fileRow)
        rows.append(Row(id: largeID(folder), title: loc("More items"), subtitle: loc("Files of 100 MB or larger"), pageID: largeID(folder)))
        widgets.append(.list(ListWidget(id: "large-class", title: loc("Large files"), rows: rows)))
        let node = index.directories[folder]
        let title = folder == index.root ? loc("Disk") : (DiskApplications.livePath(folder) as NSString).lastPathComponent
        return Screen(title: title, hero: UsageBar(id: folderID(folder), title: title, totalBytes: folder == index.root ? index.volumeUsed ?? node?.bytes : node?.bytes,
             segments: segments(index, folder: folder), footnote: loc("Local allocated space. Cloud-only files are not downloaded. Protected or unreadable locations may be incomplete; APFS clones and snapshots can make this differ from disk usage.")), widgets: widgets)
    }
    static func segments(_ index: DiskIndex, folder: String) -> [UsageSegment] {
        guard let node = index.directories[folder] else { return [] }
        var parts = node.folders.sorted().enumerated().compactMap { n, path -> UsageSegment? in
            guard let dir = index.directories[path], dir.bytes > 0 else { return nil }
            return UsageSegment(id: path, label: (path as NSString).lastPathComponent, bytes: dir.bytes, tone: .series(n), pageID: folderID(path))
        }
        let files = index.largeFiles.filter { ($0.path as NSString).deletingLastPathComponent == folder }
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
        let rows = apps.apps.map { app -> Row in
            let dataSize = app.dataPaths.reduce(UInt64(0)) { $0 + (index.directories[DiskApplications.measuredPath($1, index: index)]?.bytes ?? 0) }
            let action = Action(id: "uninstall", title: loc("Uninstall"), role: .destructive,
                parameters: ["app": app.owner.path, "identifier": app.owner.identifier],
                confirmation: Confirmation(title: loc("Uninstall \(app.owner.name)?"), message: loc("The app and its owned support files, settings, caches and helpers will be removed. Shared data used by other installed apps is preserved.") + "\n\n" + ([app.owner.path] + app.dataPaths).joined(separator: "\n"), confirmTitle: loc("Uninstall")), requires: [.fullDiskAccess, .privilegedHelper], workingTitle: loc("Uninstalling"))
            return Row(id: app.owner.path, title: app.owner.name, trailing: ByteFormat.string(app.bytes + dataSize),
                       detail: app.removable ? app.owner.identifier : loc("This app is managed by macOS or MacSpace and cannot be removed here."),
                       actions: app.removable ? [action] : [], paths: [app.owner.path], iconPath: app.owner.path)
        }
        return Screen(title: loc("Uninstall apps"), layout: .singleColumn, widgets: [.list(ListWidget(id: "installed-apps", title: loc("Apps"), emptyMessage: loc("No apps found"), rows: rows))])
    }
    static func allLargePage(_ index: DiskIndex, folder: String) -> Screen {
        Screen(title: loc("Large files"), layout: .singleColumn, widgets: [.list(ListWidget(id: "all-large", title: loc("Files of 100 MB or larger"), emptyMessage: loc("No large files in this folder"), rows: largeFiles(index, folder: folder).map(fileRow)))])
    }
    static func canDelete(_ path: String) -> Bool {
        let live = DiskApplications.livePath(path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var st = stat()
        return live.hasPrefix(home + "/") && !live.contains(".app/") && !live.contains("/.Trash/")
            && lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && st.st_uid == getuid()
            && URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
    }
    static func fileRow(_ file: DiskFile) -> Row {
        let name = (file.path as NSString).lastPathComponent
        let action = Action(id: "deleteFile", title: loc("Delete"), role: .destructive, parameters: ["path": file.path],
            confirmation: Confirmation(title: loc("Delete \(name)?"), message: loc("This permanently deletes the file.") + "\n" + DiskApplications.livePath(file.path), confirmTitle: loc("Delete")), requires: [.fullDiskAccess], workingTitle: loc("Deleting"))
        return Row(id: file.path, title: name, trailing: ByteFormat.string(file.logicalBytes),
                   detail: DiskApplications.livePath(file.path), actions: canDelete(file.path) ? [action] : [], paths: [DiskApplications.livePath(file.path)])
    }
}
