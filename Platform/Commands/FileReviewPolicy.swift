import Darwin
import Foundation

/// One ownership boundary for Disk inventory, selection and execution. UID is checked separately.
public enum FileReviewPolicy {
    public enum Exclusion: String, Sendable {
        case invalidPath, outsidePersonalLocation, managedLocation, packageContents, hiddenLocation
    }
    public static let personalFolders = ["Downloads", "Documents", "Desktop", "Movies", "Music", "Pictures"]
    public static func livePath(_ path: String) -> String {
        let prefix = DataVolume.path
        return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
    }
    public static func applicationsFolder(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        let path = livePath(path)
        return path == "/Applications" || path == home + "/Applications"
    }
    public static func exclusion(_ original: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Exclusion? {
        let path = livePath(original)
        guard path.hasPrefix("/"), !path.utf8.contains(0), !path.contains("//"), !path.hasSuffix("/"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return .invalidPath }
        guard path.hasPrefix(home + "/") else { return .outsidePersonalLocation }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        let managed: Set<String> = ["Library", "Applications", "node_modules", "target", "DerivedData", "Caches"]
        if parts.contains(where: { managed.contains(String($0)) }) { return .managedLocation }
        if parts.contains(where: { $0.hasPrefix(".") }) { return .hiddenLocation }
        let packages: Set<String> = ["app", "appex", "xpc", "bundle", "framework", "plugin", "photoslibrary", "photolibrary", "musiclibrary", "band", "logicx", "xcodeproj", "xcworkspace"]
        if parts.contains(where: { packages.contains(($0 as NSString).pathExtension.lowercased()) }) { return .packageContents }
        guard let first = parts.first, personalFolders.contains(String(first)), parts.count > 1 else { return .outsidePersonalLocation }
        return nil
    }
    public static func includes(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        exclusion(path, home: home) == nil
    }
}

/// Captured file identity, including content-change markers. It never grants deletion authority.
public struct FileReviewIdentity: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public let uid: UInt32
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanos: Int64
    public let changedSeconds: Int64
    public let changedNanos: Int64
    public init?(_ path: String) {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_flags & UInt32(SF_DATALESS | SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE) == 0 else { return nil }
        self.init(value)
    }
    public init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; uid = value.st_uid; size = Int64(value.st_size)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
    }
}
