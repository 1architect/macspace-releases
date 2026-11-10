import Foundation
import MacSpaceSdk
import MacSpacePlatform

enum DiskFileReview {
    static let destination = "file-deletion-review"

    static func removalAction(id: String = "freeFiles", parameters: [String: String] = [:]) -> Action {
        let trash = parameters["trash"].map { $0 == "1" } ?? FileRemovalSettings.movesToTrash()
        return Action(id: id, title: trash ? loc("Move to Trash") : loc("Delete"), role: .destructive,
            parameters: parameters.merging(["trash": trash ? "1" : "0"]) { _, current in current },
            confirmation: Confirmation(title: trash ? loc("Move files to Trash?") : loc("Delete selected files?"),
                message: trash ? "" : loc("This cannot be undone."),
                confirmTitle: trash ? loc("Move to Trash") : loc("Delete")),
            requires: [.fullDiskAccess], workingTitle: loc("Freeing space"))
    }

    static func screen(files: [DiskFile], bulk: SelectionBulk, next: String?) -> Screen {
        var selection = DiskMapScreenBuilder.fileSelection(files, open: [:])
        selection.action = removalAction()
        selection.bulk = bulk
        var widgets: [ScreenWidget] = [.list(ListWidget(id: "review-files", title: loc("Selected files"),
            emptyMessage: loc("No files are selected."), rows: rows(files), cascadesOnAppear: true))]
        if let next {
            widgets.append(.list(ListWidget(id: "review-next", rows: [Row(id: next, title: loc("More items"), pageID: next, replacesPage: true)])))
        }
        return Screen(title: loc("Review selected files"), subtitle: message, layout: .singleColumn,
            widgets: widgets, selection: selection)
    }

    static func single(_ file: DiskFile, parameters: [String: String]) -> Screen {
        let action = removalAction(id: "deleteGraphFile", parameters: parameters)
        let id = DiskFileRemoval.id(file.path)
        return Screen(title: loc("Review selected files"), subtitle: message, layout: .singleColumn,
            widgets: [.list(ListWidget(id: "review-files", title: loc("Selected files"), rows: rows([file]), cascadesOnAppear: true))],
            selection: Selection(action: action, choices: [id: file.bytes], checked: [id], scope: "file-review:" + id))
    }

    static func unavailable(_ reason: String) -> Screen {
        Screen(title: loc("Review selected files"), layout: .singleColumn,
            widgets: [.list(ListWidget(id: "review-unavailable", emptyMessage: reason, rows: []))])
    }

    private static var message: String {
        FileRemovalSettings.movesToTrash() ? loc("The selected files will be moved to Trash.") : loc("This permanently deletes the selected files.")
    }

    private static func rows(_ files: [DiskFile]) -> [Row] {
        files.map { file in
            Row(id: DiskFileRemoval.id(file.path), title: (file.path as NSString).lastPathComponent,
                subtitle: FileReviewPolicy.livePath(file.path), trailing: ByteFormat.string(file.bytes),
                paths: [FileReviewPolicy.livePath(file.path)])
        }
    }
}
