import Foundation

/// Steps the user takes inside a third-party app (or a macOS screen) to shrink data MACSPACE must not delete itself:
/// message media, cloud-file copies, app caches with their own "clear" button.
public struct ManualCleanupGuide: Codable, Equatable, Sendable {
    public let app: String
    /// What the steps remove.
    public let frees: String
    public let steps: [String]
    /// Whether MACSPACE checked these steps against a real version of the app. Menu labels change between versions,
    /// so the UI should word unverified guides as "usually".
    public let verified: Bool
}

/// Per-app total of the items one guide covers.
public struct ManualCleanupSummary: Codable, Equatable, Sendable {
    public let app: String
    /// nil when none of the app's items could be measured (e.g. root-only locations without the helper).
    public let bytes: UInt64?
    public let itemIDs: [String]
    public let guide: ManualCleanupGuide
}

public enum ManualCleanupGuides {
    struct Rule {
        let tokens: [String]
        let guide: ManualCleanupGuide
    }

    static let rules: [Rule] = [
        Rule(tokens: ["whatsapp"], guide: ManualCleanupGuide(
            app: "WhatsApp", frees: "Photos, videos, voice notes and documents received in chats.",
            steps: ["Open WhatsApp → Settings → Storage (Manage storage).",
                    "Review the largest files and the chats with the most media; select and delete what you don't need.",
                    "To slow regrowth, turn off automatic media download in the same Storage settings."],
            verified: false)),
        Rule(tokens: ["onedrive"], guide: ManualCleanupGuide(
            app: "OneDrive", frees: "Local copies of files that stay available in OneDrive.",
            steps: ["In Finder, open your OneDrive folder.",
                    "Select the large folders or files → right-click → Free Up Space. They stay in the cloud (cloud icon) and download again when opened.",
                    "Keep Files On-Demand on so new files are not all downloaded (OneDrive → Settings)."],
            verified: false)),
        Rule(tokens: ["googledrive", "google drive", "drivefs"], guide: ManualCleanupGuide(
            app: "Google Drive", frees: "Mirrored or offline copies of Drive files and Drive's local cache.",
            steps: ["Google Drive menu-bar icon → gear → Preferences → Google Drive: choose \"Stream files\" instead of \"Mirror files\".",
                    "For streamed files marked for offline use: right-click in Finder → Offline access → Online only."],
            verified: false)),
        Rule(tokens: ["dropbox"], guide: ManualCleanupGuide(
            app: "Dropbox", frees: "Local copies of files that stay in Dropbox.",
            steps: ["In Finder, right-click large Dropbox folders → Make online-only."],
            verified: false)),
        Rule(tokens: ["telegram"], guide: ManualCleanupGuide(
            app: "Telegram", frees: "Cached media from chats and channels.",
            steps: ["Telegram → Settings → Data and Storage → Storage Usage → Clear Cache."],
            verified: false)),
        Rule(tokens: ["slack"], guide: ManualCleanupGuide(
            app: "Slack", frees: "Slack's cached files.",
            steps: ["Slack → Help → Troubleshooting → Clear Cache and Restart."],
            verified: false)),
        Rule(tokens: ["spotify"], guide: ManualCleanupGuide(
            app: "Spotify", frees: "Streaming cache and downloaded songs.",
            steps: ["Spotify → Settings → Storage → Clear cache; remove downloads you no longer need."],
            verified: false)),
        Rule(tokens: ["docker"], guide: ManualCleanupGuide(
            app: "Docker", frees: "Unused images, containers, volumes and build cache.",
            steps: ["Run `docker system prune` (add `--volumes` only if you don't need stopped containers' data), or Docker Desktop → Troubleshoot → Clean / Purge data."],
            verified: false)),
        Rule(tokens: ["prlupd-part", ".pvm", "parallels"], guide: ManualCleanupGuide(
            app: "Parallels Desktop", frees: "Virtual machines you no longer use and downloaded macOS restore images.",
            steps: ["Parallels Desktop → Control Center: right-click a virtual machine you don't use → Remove → Move to Trash.",
                    "A `.prlupd-part` file in Downloads is an unfinished download: let Parallels finish it, or cancel it in Parallels and delete the file."],
            verified: false)),
        Rule(tokens: [".utm", "utmapp"], guide: ManualCleanupGuide(
            app: "UTM", frees: "Virtual machines you no longer use.",
            steps: ["UTM → select the virtual machine → Delete."],
            verified: false)),
        Rule(tokens: [".ipsw"], guide: ManualCleanupGuide(
            app: "macOS restore images", frees: "Restore images that were only needed to set up a Mac, device or virtual machine.",
            steps: ["After the setup is done, delete the .ipsw file from Downloads (Finder → Move to Trash, then empty the Trash)."],
            verified: false)),
        Rule(tokens: ["claudefordesktop.shipit"], guide: ManualCleanupGuide(
            app: "Claude", frees: "A downloaded app update waiting to be installed.",
            steps: ["Quit and reopen Claude so it installs the pending update; the updater cache is emptied afterwards."],
            verified: false)),
        Rule(tokens: ["documentrevisions", "versions:documents"], guide: ManualCleanupGuide(
            app: "Document versions", frees: "Old Auto Save versions of documents.",
            steps: ["Open a large document in its app → File → Revert To → Browse All Versions.",
                    "Select old versions you don't need and delete them. macOS also thins old versions on its own."],
            verified: false)),
        Rule(tokens: ["orphanhome:"], guide: ManualCleanupGuide(
            app: "Deleted accounts' home folders", frees: "Files of accounts that were deleted from this Mac.",
            steps: ["In Finder, open the folder (Go > Go to Folder…, then the path). macOS asks for an administrator password.",
                    "Copy anything you want to keep to your own folders.",
                    "Move the folder to the Trash and empty it, or in Terminal: sudo rm -rf \"<path>\"."],
            verified: false)),
        Rule(tokens: ["update:staged", "macos install data"], guide: ManualCleanupGuide(
            app: "macOS update", frees: "The downloaded update package.",
            steps: ["System Settings → General → Software Update: install the waiting update. macOS removes the package afterwards."],
            verified: false)),
    ]

    /// The guide for an item, matched on its id and title.
    public static func guide(for item: SystemDataItem) -> ManualCleanupGuide? {
        let haystack = "\(item.id) \(item.title) \(item.paths.joined(separator: " "))".lowercased()
        return rules.first { rule in rule.tokens.contains { haystack.contains($0) } }?.guide
    }

    /// One line per app for what only the user can clean (items MACSPACE cleans itself and app caches are left out), largest first.
    public static func summaries(for items: [SystemDataItem]) -> [ManualCleanupSummary] {
        var byApp: [String: (bytes: UInt64?, ids: [String], guide: ManualCleanupGuide)] = [:]
        for item in items where item.cleanup.kind != .deleteWhenNotRunning && item.kind != .appCache {
            guard let guide = item.guide else { continue }
            var entry = byApp[guide.app] ?? (nil, [], guide)
            if let bytes = item.bytes { entry.bytes = (entry.bytes ?? 0) + bytes }
            entry.ids.append(item.id)
            byApp[guide.app] = entry
        }
        return byApp.map { ManualCleanupSummary(app: $0.key, bytes: $0.value.bytes, itemIDs: $0.value.ids, guide: $0.value.guide) }
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }
}
