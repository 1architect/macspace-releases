import Foundation
import MacSpaceSdk
import MacSpacePlatform
import MacSpaceDiskMapPrivileged

extension DiskMapScreenBuilder {
    static func browseTitle(_ request: DiskBrowseRequest) -> String {
        if let type = request.largeType {
            return ["archives": loc("Archives"), "installers": loc("Installers"), "media": loc("Media"), "other": loc("Other")][type] ?? loc("Large files")
        }
        return switch request.kind {
        case .direct: loc("Other files")
        case .duplicates: loc("Duplicate files")
        case .category: request.category?.title ?? loc("Other")
        }
    }

    static func selectionPageID(_ request: DiskBrowseRequest, parent: String? = nil) -> String {
        var request = request
        request.afterSize = nil; request.afterPath = nil; request.selectionParent = parent
        return "select:" + request.pageID
    }

    static func browsePage(_ page: DiskBrowsePage) -> Screen {
        let open = OpenFileUse.inspect(Set(page.files.map(\.path)))
        var selection = fileSelection(page.files.filter { page.ownership[$0.path] == nil }, open: open)
        let title = browseTitle(page.request), categoryID = "content-category:" + page.request.selectionScope
        var lists: [ScreenWidget] = [.list(ListWidget(id: categoryID, title: title,
            emptyMessage: page.files.isEmpty ? (page.request.kind == .duplicates ? loc("No verified duplicate copies yet") : loc("No files in this group")) : nil, rows: [],
            paths: [FileReviewPolicy.livePath(page.request.folder)]))]
        selection.sections.append(.init(id: categoryID, title: title, rows: page.files.map { fileID($0.path) },
            pageID: selectionPageID(page.request), unavailableReason: page.unavailableReason))
        if page.request.kind == .duplicates {
            for group in page.duplicateGroups {
                let id = "duplicate-set:" + group.id
                var keeper = fileRow(group.keeper)
                keeper.id = "keeper:" + keeper.id
                keeper.unavailableReason = nil
                keeper.badges.append(Badge(loc("Retained copy"), .info))
                let rows = [keeper] + reviewRows(group.copies, ownership: page.ownership, open: open)
                if case var .list(list) = lists[0] {
                    list.rows += [Row(id: id, title: loc("Identical files"), sectionID: id)] + rows
                    lists[0] = .list(list)
                }
            }
        } else {
            let groups = Dictionary(grouping: page.files) { DiskDatabase.parent($0.path) }
            for folder in groups.keys.sorted() {
                let files = groups[folder] ?? [], id = "files:" + page.request.selectionScope + ":" + folder
                let title = FileReviewPolicy.livePath(folder)
                if case var .list(list) = lists[0] {
                    let heading = Row(id: id, title: title, paths: [FileReviewPolicy.livePath(folder)], sectionID: id)
                    list.rows += [heading] + reviewRows(files, ownership: page.ownership, open: open)
                    lists[0] = .list(list)
                }
                selection.sections.append(.init(id: id, title: title, rows: files.map { fileID($0.path) },
                    pageID: selectionPageID(page.request, parent: folder)))
            }
        }
        if let reason = page.unavailableReason {
            lists.append(.banner(Banner(id: "inventory-limit", severity: .warning, title: loc("Inventory incomplete"), message: reason)))
        }
        if let next = page.next {
            lists.append(.list(ListWidget(id: "next", rows: [Row(id: next.pageID, title: loc("More items"), pageID: next.pageID)])))
        }
        if page.request.kind == .category, !page.request.includeSmaller {
            var smaller = page.request
            smaller.includeSmaller = true; smaller.afterSize = nil; smaller.afterPath = nil
            lists.append(.list(ListWidget(id: "smaller-files", rows: [Row(id: smaller.pageID, title: loc("Show smaller files"), pageID: smaller.pageID, replacesPage: true)])))
        }
        return Screen(title: title, subtitle: page.request.kind == .category && !page.request.includeSmaller ? loc("Files of 100 MB or larger") : nil, layout: .singleColumn, widgets: lists, selection: selection)
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
