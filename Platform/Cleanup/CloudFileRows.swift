import Foundation
import MacSpaceSdk

/// Both modules deliberately expose the same cloud cleanup at the user's request. They share eligibility, progress and actions.
public enum CloudFileRows {
    public static func action(_ source: PurgeableDocuments.Source) -> Action {
        Action(id: "removeDownloads", title: String(localized: "Free"), parameters: ["path": source.path],
               confirmation: Confirmation(title: String(localized: "Free \(ByteFormat.string(source.bytes)) of \(source.name) downloads?"),
                                          message: String(localized: "The files stay in \(source.name) and download again when you open them."),
                                          confirmTitle: String(localized: "Free")), workingTitle: String(localized: "Freeing space"),
               labelSamples: [String(localized: "Removing downloads")] +
                   [0, 999, 999_499, 999_499_999, 999_499_999_999, source.bytes].filter { $0 <= source.bytes }.map {
                       String(localized: "Removing \(ByteFormat.string($0))")
                   })
    }

    public static func row(_ source: PurgeableDocuments.Source, removing: CloudDownloadRemovals.Progress?, id: String? = nil) -> Row {
        // The (i) says what these are, never how many there are (`InfoText`): the count is the subtitle, the size the figure.
        var row = Row(id: id ?? "documents:\(source.path)", title: String(localized: "\(source.name) files on this Mac"),
                      subtitle: source.files == 1 ? String(localized: "1 file") : String(localized: "\(source.files) files"),
                      trailing: ByteFormat.string(source.bytes), symbol: "icloud.and.arrow.down",
                      detail: String(localized: "Copies of cloud files kept on this Mac. Removing them keeps the files in the cloud."),
                      actions: [action(source)], paths: [source.path])
        if let removing {
            row.activity = ActionProgress(fraction: removing.total > 0 ? removing.fraction : nil, message: removing.total == 0 ? String(localized: "Removing downloads") : String(localized: "Removing \(ByteFormat.string(removing.bytes))"))
        }
        return row
    }

    /// Validate the provider again; individual file eligibility is rechecked by the existing eviction mechanism.
    public static func start(_ source: PurgeableDocuments.Source, moduleID: String, moduleName: String) -> ActionResult {
        guard PurgeableDocuments.isCloudFolder(source.path) else { return .failed(String(localized: "That cloud folder is no longer on this Mac")) }
        CloudDownloadRemovals.shared.start(URL(fileURLWithPath: source.path)) { removal, freed in
            var summary = "\(source.name) downloads: \(removal.files) file(s) now only in the cloud"
            if removal.kept > 0 { summary += ", \(removal.kept) kept (not uploaded yet, in conflict, or refused)" }
            CleanupHistory.shared.record(moduleID: moduleID, moduleName: moduleName, freedBytes: freed, trigger: .manual, summary: summary)
        }
        return ActionResult(outcome: .succeeded, message: "", refresh: true)
    }
}
