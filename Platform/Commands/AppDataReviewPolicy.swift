import Foundation

/// Explicit user review is limited to app-data locations, never arbitrary Library roots or documents.
public enum AppDataReviewPolicy {
    public static let directoryBases = ["Application Support", "Containers", "Group Containers", "Application Scripts", "Caches", "HTTPStorages", "WebKit", "Logs", "Saved Application State"]
    public static let fileBases = ["Preferences", "Preferences/ByHost", "Cookies", "HTTPStorages"]

    public static func includesDirectory(_ path: String, home: String) -> Bool {
        guard FileReviewPolicy.isNormalizedAbsolutePath(home, allowTrailingSlash: false),
              FileReviewPolicy.isNormalizedAbsolutePath(path, allowTrailingSlash: false) else { return false }
        return directoryBases.contains { base in
            let prefix = home + "/Library/" + base + "/"
            guard path.hasPrefix(prefix) else { return false }
            let parts = path.dropFirst(prefix.count).split(separator: "/")
            // System-managed document/sync stores are not optional app support folders.
            let protected: Set<String> = ["clouddocs", "mobilesync", "addressbook", "callhistorydb", "knowledge", "syncservices", "apple"]
            let name = parts.first?.lowercased() ?? ""
            return parts.allSatisfy { !$0.hasPrefix(".") } && !(base == "Application Support" && protected.contains(name))
                && !(base == "Logs" && ["diagnosticreports", "crashreporter"].contains(name))
        }
    }
    public static func includesFile(_ path: String, home: String) -> Bool {
        guard FileReviewPolicy.isNormalizedAbsolutePath(home, allowTrailingSlash: false),
              FileReviewPolicy.isNormalizedAbsolutePath(path, allowTrailingSlash: false) else { return false }
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        return (parent == home + "/Library/Preferences" || parent == home + "/Library/Preferences/ByHost") && name.hasSuffix(".plist")
            || (parent == home + "/Library/Cookies" || parent == home + "/Library/HTTPStorages") && name.hasSuffix(".binarycookies")
    }
}
