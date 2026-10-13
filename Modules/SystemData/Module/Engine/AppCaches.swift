import CoreServices
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A third-party app's cache folder in `~/Library/Caches`, or a sandboxed app's in its container (`~/Library/Containers/<bundle id>/
/// Data/Library/Caches`, read with Full Disk Access), with what decides whether it is in use: the file system's dates and the owner
/// app's last launch. Nothing in it is opened to read this. Measured on 26B5101f (2026-10-12): for 10 of 11 apps, a cache's last
/// change was within about a day of the app's last launch, so a cache that has not changed for weeks is one nothing uses.
public struct AppCache: Codable, Equatable, Sendable {
    public enum Owner: Codable, Equatable, Sendable {
        /// An installed app, with its name and when it was last opened (nil when Spotlight does not say).
        case app(name: String, lastOpened: Date?)
        /// Named after a bundle identifier that no installed app has: the app is gone, or on a disk that is not connected.
        case notInstalled
        /// A plain name (a command-line tool, a plug-in, a framework): who uses it cannot be told.
        case unknown
    }

    public var id: String
    /// The folder's own name.
    public var name: String
    public var path: String
    public var bytes: UInt64
    /// The newest date anything in the folder was created, written or first read after a change. A file's access date moves only on
    /// the first read after a change (measured on 26B5101f), so this is not the last read: an app that only reads its cache does not
    /// move it, which is why the owner's last launch is asked too.
    public var lastChange: Date
    /// Bytes created in the last two days: a cache that refills by itself comes back soon after it is deleted.
    public var recentBytes: UInt64
    /// Media and documents with names people give (`Episode 12.mp3`), which an app may keep in its cache as data (offline downloads).
    public var dataLikeBytes: UInt64
    public var owner: Owner
    /// Its app or tool is running now (as the cleaner checks it): it cannot go until it quits, so it is not listed.
    public var ownerRunning = false
    /// While its owner runs: whether that owner is an app in the Dock or the menu bar ("Open now") or another program, a plug-in's
    /// renderer or a command-line tool ("In use"). Free closes either (`AppQuitter`). nil when not known.
    public var quittable: Bool?
    /// The sandboxed app's bundle identifier when the folder is its container's caches folder; nil for a folder in `~/Library/Caches`.
    /// Only what is in a container's folder is freed, never the folder itself, which the app expects to find, and never what macOS's
    /// own services keep there (`AppCaches.isAppleEntry`).
    public var container: String? = nil
    /// For a container's folder: the bundle identifiers whose app keeps it while running, matched exactly (`ProcessCheck.runningApp`):
    /// the container's, and for an extension or a helper, its app's (`AppCaches.containerApp`).
    public var bundleIdentifiers: [String] = []

    /// The name to show: the app's when it is installed, else the folder's.
    public var title: String {
        if case let .app(name, _) = owner { return name }
        return name
    }
}

public enum AppCacheOutcome: Equatable, Sendable {
    /// Recommended: checked until the user chooses.
    case suggested
    /// Changed in the last days, or whose owner cannot be named and changed this week: listed, not checked. It comes back soon
    /// after it is freed.
    case comesBack
    /// Holds what looks like data: never listed.
    case heldBack
}

public enum AppCaches {
    /// Changed within this, a cache is in use: freeing it would only free the space until its app writes it again.
    static let recentDays = 3.0
    /// A cache no app can be named for is recommended only after this long untouched: who would miss it cannot be asked.
    static let unknownDays = 7.0
    /// From this much data-like content, a folder is never offered.
    static let dataLikeLimit: UInt64 = 50_000_000
    static let mediaAndDocumentExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "aif", "aiff", "ogg", "opus", "mp4", "m4v",
                                                          "mov", "mkv", "avi", "webm", "pdf", "doc", "docx", "pages", "key", "numbers", "xls",
                                                          "xlsx", "ppt", "pptx", "rtf", "epub"]

    /// Every cache is recommended once its app is gone or it has been left alone for a few days; an app rebuilds what it needs, at
    /// the cost of a slower first launch. Asked to be bolder on 2026-10-13: with a month untouched and the app unopened for a
    /// month, only one cache of the development Mac's 18 qualified, since most change every week.
    public static func outcome(_ cache: AppCache, now: Date = Date()) -> AppCacheOutcome {
        if cache.dataLikeBytes >= dataLikeLimit { return .heldBack }
        if cache.owner == .notInstalled { return .suggested }
        let unchanged = now.timeIntervalSince(cache.lastChange) / 86_400
        if unchanged < recentDays { return .comesBack }
        if cache.owner == .unknown, unchanged < unknownDays { return .comesBack }
        return .suggested
    }

    /// Days since the cache last changed, rounded down.
    public static func unchangedDays(_ cache: AppCache, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(cache.lastChange) / 86_400))
    }

    // MARK: Reading the Mac

    /// The folder's dates and sizes, from the file system's records alone (`fts`, which reads no file's content). For a container's
    /// folder (`skippingApple`), what macOS's own services keep in it is left out, as it is when the folder is freed.
    static func measure(_ path: String, now: Date = Date(), skippingApple: Bool = false) -> (lastChange: Date, recentBytes: UInt64, dataLikeBytes: UInt64, bytes: UInt64)? {
        guard let copy = strdup(path) else { return nil }
        defer { free(copy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [copy, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }
        let recent = now.timeIntervalSince1970 - 2 * 86_400
        var newest: TimeInterval = 0
        var recentBytes: UInt64 = 0
        var dataLike: UInt64 = 0
        var total: UInt64 = 0
        func seconds(_ time: timespec) -> TimeInterval { TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9 }
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if skippingApple, entry.pointee.fts_level == 1, let entryPath = entry.pointee.fts_path,
               isAppleEntry((String(cString: entryPath) as NSString).lastPathComponent) {
                if info == FTS_D { fts_set(fts, entry, FTS_SKIP) }
                continue
            }
            guard let stat = entry.pointee.fts_statp?.pointee else { continue }
            // A folder's own access date moves whenever something lists it (this scan too), so only its writes count.
            if info == FTS_D {
                newest = max(newest, seconds(stat.st_mtimespec), seconds(stat.st_birthtimespec))
                continue
            }
            guard info == FTS_F else { continue }
            let born = seconds(stat.st_birthtimespec)
            newest = max(newest, born, seconds(stat.st_mtimespec), seconds(stat.st_atimespec))
            let allocated = UInt64(max(stat.st_blocks, 0)) * 512
            total += allocated
            if born >= recent { recentBytes += allocated }
            if let path = entry.pointee.fts_path, isDataLike((String(cString: path) as NSString).lastPathComponent) { dataLike += allocated }
        }
        return (Date(timeIntervalSince1970: newest), recentBytes, dataLike, total)
    }

    /// A media file or document with a name a person gave it ("Episode 12.mp3"), not a key or a hash ("a3f9…e1.mp4").
    static func isDataLike(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard mediaAndDocumentExtensions.contains(ext) else { return false }
        let stem = (fileName as NSString).deletingPathExtension
        let keyLike = stem.count >= 16 && stem.allSatisfy { $0.isHexDigit || $0 == "-" || $0 == "_" }
        return !keyLike
    }

    /// Who uses the folder: an app by bundle identifier (and when it was last opened), an app by name in the Applications folders, a
    /// bundle identifier no installed app has, or no one that can be named.
    static func owner(of name: String) -> AppCache.Owner {
        #if canImport(AppKit)
        if looksLikeBundleIdentifier(name) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) else { return .notInstalled }
            return .app(name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), lastOpened: lastOpened(url.path))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in ["/Applications", home + "/Applications"] {
            let path = "\(folder)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return .app(name: name, lastOpened: lastOpened(path)) }
        }
        #endif
        return .unknown
    }

    /// `com.example.App`: two dots or more, no spaces.
    static func looksLikeBundleIdentifier(_ name: String) -> Bool {
        name.split(separator: ".").count >= 3 && !name.contains(" ")
    }

    /// When the app was last opened, as Spotlight records it; nil when it does not say (an app started from Xcode has none).
    static func lastOpened(_ appPath: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, appPath as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: Sandboxed apps' containers

    /// Whether a container is Apple's: one of macOS's apps or services.
    static func isAppleContainer(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier.hasPrefix("com.apple.") || bundleIdentifier.hasPrefix("group.com.apple.")
    }

    /// What macOS's own services keep in an app's caches folder, named after themselves: `com.apple.nsurlsessiond` holds the app's
    /// background downloads, which the service carries on with while the app is closed and whose open files it does not show
    /// (`ProcessCheck.isAppleSystemProgram`). Left to macOS.
    static func isAppleEntry(_ name: String) -> Bool { name.hasPrefix("com.apple.") }

    /// The caches folder of a third-party app's container in this home folder (`~/Library/Containers/<bundle id>/Data/Library/Caches`);
    /// nil for Apple's containers and for a name that is not one folder's.
    static func containerCachesFolder(home: String, container: String) -> String? {
        guard !container.isEmpty, !container.contains("/"), !container.hasPrefix("."), !isAppleContainer(container) else { return nil }
        return "\(home)/Library/Containers/\(container)/Data/Library/Caches"
    }

    /// What is freed from a container's caches folder: everything in it but macOS's own (`isAppleEntry`).
    static func containerContents(_ folder: String, fileManager: FileManager = .default) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).filter { !isAppleEntry($0) }.sorted()
            .map { (folder as NSString).appendingPathComponent($0) }
    }

    /// The installed app a container belongs to: the app with its bundle identifier, or, for an extension or a helper, the app whose
    /// identifier its own begins with (`net.whatsapp.WhatsApp.ServiceExtension` is WhatsApp's), as Apple requires of an app's
    /// extensions. nil when no installed app has either, as for an app that was removed. Measured on 26B5101f (2026-10-13): this named
    /// the app of 24 of the development Mac's 35 third-party containers; 10 of the other 11 belonged to apps no longer installed, and
    /// one to HandBrake's XPC service, whose identifier does not begin with HandBrake's.
    static func containerApp(_ bundleIdentifier: String, appURL: (String) -> URL? = liveAppURL) -> (bundleIdentifier: String, url: URL)? {
        var parts = bundleIdentifier.split(separator: ".")
        while parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            if let url = appURL(candidate) { return (candidate, url) }
            parts.removeLast()
        }
        return nil
    }

    /// Who a container belongs to (its app, with when it was last opened, or no installed app), and the bundle identifiers whose
    /// running keeps its caches: the container's, and its app's when that is another.
    static func containerOwner(of bundleIdentifier: String) -> (owner: AppCache.Owner, bundleIdentifiers: [String]) {
        guard let app = containerApp(bundleIdentifier) else { return (.notInstalled, [bundleIdentifier]) }
        let name = FileManager.default.displayName(atPath: app.url.path).replacingOccurrences(of: ".app", with: "")
        let identifiers = app.bundleIdentifier == bundleIdentifier ? [bundleIdentifier] : [bundleIdentifier, app.bundleIdentifier]
        return (.app(name: name, lastOpened: lastOpened(app.url.path)), identifiers)
    }

    static func liveAppURL(_ bundleIdentifier: String) -> URL? {
        #if canImport(AppKit)
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        #else
        return nil
        #endif
    }

    /// Whether macOS itself has something by this name on the sealed system volume (a framework, a daemon, an app): such a cache is
    /// Apple's even without the `com.apple.` prefix (PassKit, GameKit, GeoServices and CloudKit on 26B5101f). A name found nowhere is
    /// not proved third-party; it only falls back to the other rules. Names are compared exactly: the disk ignores case, and `pip`
    /// (Python's installer) would otherwise match `PIP.framework` (Picture in Picture).
    ///
    /// A name that begins with one of them, followed by a word of its own (`SiriEntityCache`: Siri, then EntityCache), is Apple's too:
    /// macOS names a component's caches after it. A rule, not a list of names, so it holds for components MacSpace has never seen.
    /// SiriEntityCache was taken for an app's cache on 26B5101f, and quitting "Siri" for it brought up the Siri orb (2026-10-13). Only
    /// at a word's start (a capital after a lowercase letter), and a name of four letters or more: `Photosynth` is not Photos'.
    static func isApple(_ name: String, root: String = "") -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return false }
        let names = systemNames(root: root)
        if names.contains(name) { return true }
        let characters = Array(name)
        for index in characters.indices.dropFirst(4) where characters[index].isUppercase && characters[index - 1].isLowercase {
            if names.contains(String(characters[..<index])) { return true }
        }
        return false
    }

    /// The names macOS has in the places above, read once.
    static func systemNames(root: String) -> Set<String> {
        if root.isEmpty, let cached = SystemNames.shared.names { return cached }
        var names = Set<String>()
        let places: [(folder: String, suffix: String)] = [("/System/Library/Frameworks", ".framework"), ("/System/Library/PrivateFrameworks", ".framework"),
                                                          ("/usr/libexec", ""), ("/usr/sbin", ""), ("/System/Library/CoreServices", ".app"),
                                                          ("/System/Applications", ".app")]
        for place in places {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: root + place.folder)) ?? [] {
                if place.suffix.isEmpty { names.insert(entry) }
                else if entry.hasSuffix(place.suffix) { names.insert(String(entry.dropLast(place.suffix.count))) }
            }
        }
        if root.isEmpty { SystemNames.shared.names = names }
        return names
    }
}

/// The sealed system volume's names, which change only with macOS itself.
private final class SystemNames: @unchecked Sendable {
    static let shared = SystemNames()
    private let lock = NSLock()
    private var stored: Set<String>?
    var names: Set<String>? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
