import Foundation
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceDiskMapPrivileged

extension DiskMapScreenBuilder {
    static func browseTitle(_ request: DiskBrowseRequest) -> String {
        if let type = request.largeType {
            return ["archives": loc("Archives"), "installers": loc("Installers"), "media": loc("Media"), "other": loc("Other"), "documents": loc("Documents")][type] ?? loc("Large files")
        }
        return switch request.kind {
        case .direct: loc("Other files")
        case .managed: loc("Files")
        case .duplicates: loc("Duplicate files")
        case .category: request.category == .largeFiles ? loc("Files") : request.category?.title ?? loc("Other")
        }
    }

    static func selectionPageID(_ request: DiskBrowseRequest, parent: String? = nil) -> String {
        var request = request
        request.afterSize = nil; request.afterPath = nil; request.selectionParent = parent; request.focusPath = nil
        return "select:" + request.pageID
    }

    static func browsePage(_ input: DiskBrowsePage) -> Screen {
        var page = input
        if page.request.kind != .duplicates {
            for n in page.files.indices { page.files[n].duplicateVerification = nil }
        }
        let open = OpenFileUse.inspect(Set(page.files.map(\.path)))
        var selection = fileSelection(page.files.filter { page.ownership[$0.path] == nil && page.request.kind != .managed }, open: open)
        let title = browseTitle(page.request), categoryID = "content-category:" + page.request.selectionScope
        var widgets: [ScreenWidget] = []
        if !page.files.isEmpty, page.request.kind == .duplicates {
            selection.sections.append(.init(id: categoryID, title: title, rows: page.files.map { fileID($0.path) },
                pageID: selectionPageID(page.request), unavailableReason: page.unavailableReason))
            widgets.append(.list(ListWidget(id: categoryID, title: title, rows: [])))
        }
        if page.request.kind == .duplicates {
            for group in page.duplicateGroups {
                let members = [group.keeper] + group.copies, id = "duplicate-set:" + group.id
                selection.sections.append(.init(id: id, title: (group.keeper.path as NSString).lastPathComponent, rows: []))
                var rows = reviewRows(members, ownership: page.ownership, open: open)
                for n in rows.indices {
                    rows[n].trailing = ByteFormat.string(members[n].bytes)
                }
                widgets.append(.list(ListWidget(id: id, title: (group.keeper.path as NSString).lastPathComponent, rows: rows,
                    subtitle: loc("\(group.copyCount ?? members.count) identical copies"), trailing: group.totalBytes.map(ByteFormat.string))))
            }
        } else {
            let grouped = Dictionary(grouping: page.files) { DiskFileType.key($0.path) }
            let ordered = grouped.keys.sorted { a, b in
                let left = page.types.first { $0.key == a }?.bytes ?? grouped[a, default: []].reduce(0) { $0 + $1.bytes }
                let right = page.types.first { $0.key == b }?.bytes ?? grouped[b, default: []].reduce(0) { $0 + $1.bytes }
                return left == right ? a < b : left > right
            }
            for key in ordered {
                let files = grouped[key, default: []].sorted { $0.logicalBytes == $1.logicalBytes ? $0.path < $1.path : $0.logicalBytes > $1.logicalBytes }
                let id = "type:" + page.request.selectionScope + ":" + key, name = DiskFileType.title(key)
                let total = page.types.first { $0.key == key }
                var rows = reviewRows(files, ownership: page.ownership, open: open)
                if page.request.kind == .managed {
                    for n in rows.indices { rows[n].unavailableReason = loc("Managed by Photos; browse or reveal in Finder.") }
                }
                widgets.append(.list(ListWidget(id: id, title: name, rows: rows,
                    subtitle: total.map { loc("\(Int(clamping: $0.count)) items") }, trailing: total.map { ByteFormat.string($0.bytes) })))
                var scope = page.request; scope.fileType = key; scope.afterPath = nil; scope.afterSize = nil; scope.focusPath = nil
                selection.sections.append(.init(id: id, title: name, rows: files.map { fileID($0.path) }, pageID: selectionPageID(scope), unavailableReason: page.unavailableReason))
            }
        }
        if page.files.isEmpty {
            let message = page.loadingFraction != nil ? loc("Reading files…") : page.unavailableReason ?? (page.request.kind == .duplicates ? loc("No verified duplicate copies yet") : loc("No files match this size and type scope."))
            widgets.append(.list(ListWidget(id: categoryID, title: title, emptyMessage: message, rows: [])))
        }
        if let reason = page.unavailableReason {
            widgets.append(.banner(Banner(id: "inventory-limit", severity: .warning, title: loc("Inventory incomplete"), message: reason)))
        }
        if let next = page.next { widgets.append(.list(ListWidget(id: "next", rows: [Row(id: next.pageID, title: loc("More items"), pageID: next.pageID, replacesPage: true)]))) }
        if page.request.kind == .category, page.request.category != .installers, !page.request.includeSmaller {
            var smaller = page.request; smaller.includeSmaller = true; smaller.inFolder = false; smaller.focusPath = nil; smaller.afterSize = nil; smaller.afterPath = nil
            widgets.append(.list(ListWidget(id: "smaller-files", rows: [Row(id: smaller.pageID, title: loc("Show all files"), pageID: smaller.pageID)])))
        }
        return Screen(title: title, subtitle: page.request.kind == .duplicates ? loc("Sizes show allocated space.") + " " + loc("Up to \(ByteFormat.string(page.eligibleBytes)) can be removed while keeping one copy of each set.") : page.request.kind == .category && page.request.category != .installers && !page.request.includeSmaller ? loc("Files of 100 MB or larger") : nil,
            layout: .singleColumn, widgets: widgets, selection: page.request.kind == .managed ? nil : selection, loadingFraction: page.loadingFraction)
    }
    static func reviewRows(_ files: [DiskFile], ownership: [String: DiskOwnershipClaim], open: [String: [OpenFileUse.Reader]]) -> [Row] {
        var rows = fileRows(files, folder: "", ownership: ownership)
        for n in files.indices {
            if let readers = open[files[n].path], !readers.isEmpty {
                rows[n].unavailableReason = loc("Open in \(readers.map(\.process).sorted().joined(separator: ", "))")
            } else if let claim = ownership[files[n].path] {
                rows[n].unavailableReason = ownershipExplanation(claim.confidence)
            }
        }
        return rows
    }

    static func fileRows(_ files: [DiskFile], folder: String, ownership: [String: DiskOwnershipClaim] = [:]) -> [Row] {
        files.map { file in
            var row = fileRow(file)
            if let claim = ownership[file.path] {
                let owners = claim.ownerPaths.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }.sorted()
                let title = ownershipTitle(claim.confidence)
                row.badges.append(Badge(owners.isEmpty ? title : title + ": " + owners.joined(separator: ", "), .info, help: ownershipExplanation(claim.confidence)))
                row.unavailableReason = ownershipExplanation(claim.confidence)
            }
            return row
        }
    }
}
