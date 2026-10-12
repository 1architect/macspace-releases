import Darwin
import Foundation

/// Removes the downloads idleassetsd (Aerial wallpapers and screen savers) left unfinished in the temporary folders of
/// `/private/var/folders`: `CFNetworkDownload_*.tmp` files that a stuck download can grow to hundreds of GB (Mole issue #1253).
///
/// The helper finds the folders itself and takes no path from the caller: only `/private/var/folders/<bucket>/<account>/T/
/// com.apple.idleassetsd`. In them it deletes only regular files named `CFNetworkDownload_*.tmp`, directly in the folder (no
/// subfolders), untouched for longer than the retention window (3 days, Mole's default for temporary files), so a download that
/// is still running is left alone. Every folder on the way is opened without following symbolic links, and every file is read with
/// `lstat` before it goes: a link, a folder or anything else with that name is refused.
public struct WallpaperDownloadResult: Codable, Equatable, Sendable {
    public let executed: Bool
    /// The `com.apple.idleassetsd` folders found.
    public let folders: Int
    public let removedFiles: Int
    /// What the removed files took on disk (their allocated blocks); the app measures the volume as well.
    public let removedBytes: UInt64
    /// Downloads newer than the retention window, kept.
    public let keptRecentFiles: Int
    /// Entries with a download's name that are not regular files (links, folders…), refused.
    public let refusedEntries: Int
    public let error: String?

    public init(executed: Bool, folders: Int, removedFiles: Int, removedBytes: UInt64, keptRecentFiles: Int, refusedEntries: Int, error: String?) {
        self.executed = executed
        self.folders = folders
        self.removedFiles = removedFiles
        self.removedBytes = removedBytes
        self.keptRecentFiles = keptRecentFiles
        self.refusedEntries = refusedEntries
        self.error = error
    }
}

public struct WallpaperDownloadCleaner {
    public static let foldersRoot = "/private/var/folders"
    public static let folderName = "com.apple.idleassetsd"
    public static let filePrefix = "CFNetworkDownload_"
    public static let fileSuffix = ".tmp"
    public static let retentionDays = 3
    public static let retention = TimeInterval(retentionDays) * 86_400

    let foldersRoot: String
    let retention: TimeInterval
    let now: () -> Date

    public init(foldersRoot: String = WallpaperDownloadCleaner.foldersRoot, retention: TimeInterval = WallpaperDownloadCleaner.retention,
                now: @escaping () -> Date = Date.init) {
        self.foldersRoot = foldersRoot
        self.retention = retention
        self.now = now
    }

    static func isDownloadName(_ name: String) -> Bool {
        name.hasPrefix(filePrefix) && name.hasSuffix(fileSuffix) && name.count > filePrefix.count + fileSuffix.count && !name.contains("/")
    }

    /// Opens a folder inside another one; nil for a link, a file or anything that is not a real folder.
    private static func openFolder(_ name: String, in parent: Int32) -> Int32? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        return fd >= 0 ? fd : nil
    }

    /// The names in an open folder, without `.` and `..`.
    private static func names(in folder: Int32) -> [String] {
        let copy = dup(folder)
        guard copy >= 0 else { return [] }
        guard let stream = fdopendir(copy) else { close(copy); return [] }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    public func execute() -> WallpaperDownloadResult {
        let rootFD = open(foldersRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            return WallpaperDownloadResult(executed: false, folders: 0, removedFiles: 0, removedBytes: 0, keptRecentFiles: 0, refusedEntries: 0,
                                           error: "The temporary folders could not be read.")
        }
        defer { close(rootFD) }
        let cutoff = now().addingTimeInterval(-retention).timeIntervalSince1970
        var folders = 0, removed = 0, kept = 0, refused = 0
        var bytes: UInt64 = 0
        var failures: [String] = []
        for bucket in Self.names(in: rootFD) {
            guard let bucketFD = Self.openFolder(bucket, in: rootFD) else { continue }
            defer { close(bucketFD) }
            for account in Self.names(in: bucketFD) {
                guard let accountFD = Self.openFolder(account, in: bucketFD) else { continue }
                defer { close(accountFD) }
                guard let temporaryFD = Self.openFolder("T", in: accountFD) else { continue }
                defer { close(temporaryFD) }
                guard let folderFD = Self.openFolder(Self.folderName, in: temporaryFD) else { continue }
                defer { close(folderFD) }
                folders += 1
                for name in Self.names(in: folderFD) where Self.isDownloadName(name) {
                    var info = stat()
                    guard fstatat(folderFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                    guard info.st_mode & S_IFMT == S_IFREG else { refused += 1; continue }
                    let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
                    guard modified < cutoff else { kept += 1; continue }
                    // unlinkat removes the entry itself: were it swapped for a link meanwhile, the link goes, never what it points to,
                    // and a folder is refused.
                    if unlinkat(folderFD, name, 0) == 0 {
                        removed += 1
                        // A file with other hard links frees nothing.
                        if info.st_nlink <= 1 { bytes += UInt64(max(info.st_blocks, 0)) * 512 }
                    } else {
                        failures.append("\(bucket)/\(account)/T/\(Self.folderName)/\(name): \(String(cString: strerror(errno)))")
                    }
                }
            }
        }
        return WallpaperDownloadResult(executed: true, folders: folders, removedFiles: removed, removedBytes: bytes, keptRecentFiles: kept,
                                       refusedEntries: refused, error: failures.isEmpty ? nil : failures.joined(separator: " "))
    }
}
