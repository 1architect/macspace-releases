import Foundation
import MacSpacePlatform
import MacSpaceSdk
#if canImport(AppKit)
import AppKit
#endif

public enum SystemDataSchema {
    public static let version = 1
}

/// Explains the Data-volume storage that System Settings lumps into "System Data", and cleans only what is safe:
/// regenerable caches and code-signing clones, and only while the owning app is not running.

public enum SystemDataKind: String, Codable, Sendable {
    /// `/var/folders/…/X/<bundle id>.code_sign_clone`: a copy of an app bundle macOS keeps after validating it.
    case codeSignClone
    /// `~/Library/Caches/<app>`.
    case appCache
    /// The per-user system cache `/var/folders/…/C/<name>` (e.g. the clang module cache).
    case userSystemCache
    /// `~/.cache/<tool>`: caches of command-line tools.
    case toolCache
    case appSupport
    case developerTools
    case packageManager
    case virtualMemory
    case logs
    case diagnosticReports
    case systemAssets
    case spotlightIndex
    case trash
    case snapshot
    /// `/.DocumentRevisions-V100`: the Versions / Auto Save history of edited documents.
    case documentVersions
    /// `/macOS Install Data`: a staged macOS update.
    case stagedUpdate
    /// Group Containers, Containers and Daemon Containers.
    case appContainer
    case cloudStorage
    case symbolCache
    case spotlightMetadata
    /// An unfinished download (`.part`, `.crdownload`, `.prlupd-part`, Safari `.download` bundles…).
    case partialDownload
    /// A macOS restore image (`.ipsw`), e.g. left behind after creating a virtual machine.
    case restoreImage
    /// A virtual machine bundle (Parallels `.pvm`, UTM `.utm`, VMware `.vmwarevm`).
    case virtualMachine
    /// A home folder left behind by a deleted account (`/Users/<name>` owned by no account, or `/Users/Deleted Users/*`).
    case orphanedHome
}

public struct SystemDataCleanup: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// MacSpace can delete it while the owning app is not running; macOS or the app recreates what it needs.
        case deleteWhenNotRunning
        /// Handled by another MacSpace command or a supported tool (`command`).
        case command
        /// Managed by macOS; leave it.
        case managedByMacOS
        /// Data that belongs to an app or the user; show it, don't clean it.
        case review
    }

    public let kind: Kind
    public let description: String
    public let command: String?
}

public struct SystemDataItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: SystemDataKind
    public let paths: [String]
    /// Allocated-size estimate. APFS clones and shared extents make this an upper bound on what deleting frees.
    public var bytes: UInt64?
    public var readable: Bool
    /// Apps whose running instance blocks cleanup (bundle identifiers or names).
    public let owners: [String]
    /// Whether an owner is running now.
    public let inUse: Bool
    public let cleanup: SystemDataCleanup
    public let notes: [String]
    /// What cleaning is expected to free. For APFS clones this is ~0 even though `bytes` is large.
    public var expectedReclaimBytes: UInt64? = nil
    /// Steps the user takes in the owning app when MacSpace cannot clean it.
    public var guide: ManualCleanupGuide? = nil
}

public struct SystemDataReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let volumes: [VolumeUsage]
    public var items: [SystemDataItem]
    public var measuredBytes: UInt64
    /// Expected reclaim of the items MacSpace can clean (not their `du` size).
    public let cleanableBytes: UInt64
    /// Data only the owning app can clean, with steps, one entry per app.
    public let manualCleanup: [ManualCleanupSummary]
    /// Locations that exist but this process cannot read (Full Disk Access or root needed).
    public var unreadable: [String]
    public var warnings: [String]
    /// Whether Full Disk Access was granted during the scan; decides whether an unreadable place is something the user can fix.
    public var fullDiskAccess: Bool = true
}

public struct RunningApp: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let name: String?

    public init(bundleIdentifier: String?, name: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

/// Where to look; injectable for tests.
public struct SystemDataLocations: Sendable {
    public var home: URL
    /// The per-user system folder (`getconf DARWIN_USER_DIR` without the trailing `0/`).
    public var userSystemDirectory: URL?
    public var systemPaths: [String: String]

    public init(home: URL, userSystemDirectory: URL?, systemPaths: [String: String] = SystemDataLocations.defaultSystemPaths) {
        self.home = home
        self.userSystemDirectory = userSystemDirectory
        self.systemPaths = systemPaths
    }

    public static let defaultSystemPaths: [String: String] = [
        "commandLineTools": "/Library/Developer/CommandLineTools",
        "homebrew": "/opt/homebrew",
        "usrLocal": "/usr/local",
        "unifiedLog": "/private/var/db/diagnostics",
        "uuidtext": "/private/var/db/uuidtext",
        "systemReports": "/Library/Logs/DiagnosticReports",
        "systemAssets": "/System/Library/AssetsV2",
        "spotlight": "/System/Volumes/Data/.Spotlight-V100",
        "documentRevisions": "/System/Volumes/Data/.DocumentRevisions-V100",
        "installData": "/System/Volumes/Data/macOS Install Data",
        "systemVersion": "/System/Library/CoreServices/SystemVersion.plist",
        "symbolCache": "/System/Library/Caches/com.apple.coresymbolicationd",
        "powerlog": "/private/var/db/powerlog",
        "swap": "/private/var/vm",
        "users": "/Users",
    ]

    public static func live() -> SystemDataLocations {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let userDir: URL? = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0
            ? URL(fileURLWithPath: String(cString: buffer)).deletingLastPathComponent() : nil
        return SystemDataLocations(home: FileManager.default.homeDirectoryForCurrentUser, userSystemDirectory: userDir)
    }
}

public struct SystemDataInspector {
    /// Dynamic entries smaller than this are summarized, not listed.
    public static let minimumItemBytes: UInt64 = 50 * 1_000_000
    static let partialDownloadSuffixes = [".part", ".partial", ".crdownload", ".download", ".opdownload", ".prlupd-part"]
    static let virtualMachineSuffixes = [".pvm", ".utm", ".vmwarevm"]
    /// Cache folders of Apple daemons without a `com.apple.` prefix.
    static let appleCacheNames: Set<String> = ["GeoServices", "CloudKit", "familycircled", "features_config", "tvapp_bag", "menkaure.enabled"]

    public let locations: SystemDataLocations
    private let fileManager: FileManager
    private let runningApps: () -> [RunningApp]
    private let volumes: () -> [VolumeUsage]
    private let accountExists: (uid_t) -> Bool
    private let sizer = FileTreeSizer()

    public init(locations: SystemDataLocations = .live(), fileManager: FileManager = .default,
                runningApps: @escaping () -> [RunningApp] = SystemDataInspector.liveRunningApps,
                volumes: @escaping () -> [VolumeUsage] = SystemDataInspector.liveVolumes,
                accountExists: @escaping (uid_t) -> Bool = SystemDataInspector.liveAccountExists) {
        self.locations = locations
        self.fileManager = fileManager
        self.runningApps = runningApps
        self.volumes = volumes
        self.accountExists = accountExists
    }

    public static func liveAccountExists(_ uid: uid_t) -> Bool { getpwuid(uid) != nil }

    /// Without Full Disk Access, reading other apps' data or the user's Downloads and cloud folders makes macOS ask once per app or
    /// folder, and the scan waits on every prompt. Those places are skipped and reported as unmeasured instead.
    public var hasFullDiskAccess: Bool = LivePermissionChecker.probeFullDiskAccess() != .missing

    /// Other accounts' home folders can be measured only as root (the helper); injectable for tests.
    public var canReadOtherHomes: Bool = geteuid() == 0

    /// Folders in `/Users` that are not home folders.
    static let usersFolderEntries: Set<String> = ["Shared", "Guest", "Deleted Users", ".localized"]

    public static func liveRunningApps() -> [RunningApp] {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications.map { RunningApp(bundleIdentifier: $0.bundleIdentifier, name: $0.localizedName) }
        #else
        return []
        #endif
    }

    public static func liveVolumes() -> [VolumeUsage] { VolumeUsageReader.live() }

    // MARK: Inspect

    public func inspect(now: Date = Date()) -> SystemDataReport {
        let running = runningApps()
        var items: [SystemDataItem] = []
        var unreadable: [String] = []

        // Listed children (containers, caches) that cannot be read are reported once, as their parent folder.
        var smallBytes: [SystemDataKind: UInt64] = [:]
        func measure(_ path: String, individually: Bool) -> SizeMeasurement {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return SizeMeasurement(bytes: nil) }
            guard isDirectory.boolValue else {
                let bytes = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
                return SizeMeasurement(bytes: bytes, readable: bytes != nil)
            }
            guard (try? fileManager.contentsOfDirectory(atPath: path)) != nil else {
                return SizeMeasurement(bytes: nil, unreadableEntry: path)
            }
            let measured = sizer.size(at: URL(fileURLWithPath: path))
            return SizeMeasurement(bytes: measured?.allocatedBytesEstimate ?? measured?.logicalBytes, readable: true)
        }
        func children(_ directory: String) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? []).sorted().map { (directory as NSString).appendingPathComponent($0) }
        }
        func isRunning(_ owners: [String]) -> Bool {
            owners.contains { owner in
                running.contains { app in
                    app.bundleIdentifier?.caseInsensitiveCompare(owner) == .orderedSame
                        || app.name.map { $0.caseInsensitiveCompare(owner) == .orderedSame || owner.lowercased().contains($0.lowercased()) && $0.count >= 4 } == true
                }
            }
        }
        // Entries are registered first and measured together afterwards, in parallel: sizing is disk-bound and independent per path.
        struct Pending {
            var id: String, title: String, kind: SystemDataKind, paths: [String], owners: [String]
            var cleanup: SystemDataCleanup, notes: [String], minimum: UInt64, expectedReclaim: UInt64?, measurable: Bool
        }
        var pending: [Pending] = []
        func add(_ id: String, _ title: String, _ kind: SystemDataKind, paths: [String], owners: [String] = [],
                 cleanup: SystemDataCleanup, notes: [String] = [], minimum: UInt64 = 0, expectedReclaim: UInt64? = nil,
                 measurable: Bool = true) {
            pending.append(Pending(id: id, title: title, kind: kind, paths: paths, owners: owners, cleanup: cleanup, notes: notes,
                                   minimum: minimum, expectedReclaim: expectedReclaim, measurable: measurable))
        }
        func finish() {
            var jobs: [(entry: Int, path: String)] = []
            for (index, entry) in pending.enumerated() where entry.measurable {
                for path in entry.paths { jobs.append((index, path)) }
            }
            let results = MeasurementResults(count: jobs.count)
            DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
                let job = jobs[index]
                results.set(index, measure(job.path, individually: pending[job.entry].minimum == 0))
            }
            var next = 0
            for entry in pending {
                var total: UInt64 = 0
                var readable = false
                var measured = false
                // A folder whose subfolders this process cannot read would be undercounted silently; report it unmeasured.
                if !entry.measurable { unreadable.append(contentsOf: entry.paths.filter { !unreadable.contains($0) }) }
                if entry.measurable {
                    for _ in entry.paths {
                        let result = results.get(next)
                        next += 1
                        if let entryPath = result.unreadableEntry, !unreadable.contains(entryPath) { unreadable.append(entryPath) }
                        if let bytes = result.bytes { total += bytes; measured = true }
                        readable = readable || result.readable
                    }
                }
                guard entry.paths.contains(where: fileManager.fileExists(atPath:)) else { continue }
                // Listed entries (minimum > 0) are shown only when measurable and large enough.
                if entry.minimum > 0, !measured || total < entry.minimum {
                    // Not listed, but System Settings counts it, so it stays in the totals.
                    if measured, total > 0 { smallBytes[entry.kind, default: 0] += total }
                    continue
                }
                var item = SystemDataItem(id: entry.id, title: entry.title, kind: entry.kind, paths: entry.paths, bytes: measured ? total : nil,
                                          readable: readable, owners: entry.owners, inUse: isRunning(entry.owners), cleanup: entry.cleanup, notes: entry.notes)
                item.expectedReclaimBytes = entry.expectedReclaim ?? (entry.cleanup.kind == .deleteWhenNotRunning && measured ? total : nil)
                // A leftover of a finished update has no manual step: there is no update to install.
                item.guide = entry.id == "update:staged" && entry.cleanup.kind == .managedByMacOS ? nil : ManualCleanupGuides.guide(for: item)
                items.append(item)
            }
        }
        let deleteWhenClosed = { (what: String) in
            SystemDataCleanup(kind: .deleteWhenNotRunning, description: "Safe to delete while \(what) is not running; it is recreated when needed.", command: nil)
        }
        // Apple's own caches belong to background daemons that are always running, which the app check cannot see.
        let appleManaged = SystemDataCleanup(kind: .managedByMacOS, description: "Apple system cache used by background services; macOS manages it.", command: nil)
        // Third-party app caches are listed because they fill System Data, but cleaning them is not this module's job.
        let appCacheReview = SystemDataCleanup(kind: .review, description: "A cache of this app. Cleaning app caches is outside System Data cleanup; the app rebuilds it.", command: nil)
        func isAppleCache(_ name: String) -> Bool { name.hasPrefix("com.apple.") || Self.appleCacheNames.contains(name) }

        // Code-signing clones and the per-user system cache.
        if let userDir = locations.userSystemDirectory?.path {
            for path in children((userDir as NSString).appendingPathComponent("X")) where path.hasSuffix(".code_sign_clone") {
                let bundleID = String((path as NSString).lastPathComponent.dropLast(".code_sign_clone".count))
                add("clone:\(bundleID)", "Code-signing copy of \(bundleID)", .codeSignClone, paths: [path], owners: [bundleID],
                    cleanup: SystemDataCleanup(kind: .managedByMacOS, description: "An APFS clone of the app that macOS keeps after validating it. It shares storage with the app, so deleting it frees almost nothing; it only lowers the System Data figure in System Settings.", command: nil),
                    notes: ["Measured on 26B5091g: deleting a 6.12 GB SketchUp clone freed no measurable space."],
                    expectedReclaim: 0)
            }
            for path in children((userDir as NSString).appendingPathComponent("C")) {
                let name = (path as NSString).lastPathComponent
                add("usercache:\(name)", "System cache: \(name)", .userSystemCache, paths: [path], owners: [name],
                    cleanup: isAppleCache(name) ? appleManaged : deleteWhenClosed(name == "clang" ? "a compiler" : name), minimum: Self.minimumItemBytes)
            }
        }

        // App caches and tool caches.
        let home = locations.home.path
        for path in children((home as NSString).appendingPathComponent("Library/Caches")) {
            let name = (path as NSString).lastPathComponent
            let owner = name.hasSuffix(".ShipIt") ? String(name.dropLast(".ShipIt".count)) : name
            add("appcache:\(name)", "App cache: \(name)", .appCache, paths: [path], owners: [owner],
                cleanup: isAppleCache(name) ? appleManaged : appCacheReview, notes: name.hasSuffix(".ShipIt") ? ["An app updater's download cache."] : [],
                minimum: Self.minimumItemBytes)
        }
        for path in children((home as NSString).appendingPathComponent(".cache")) {
            let name = (path as NSString).lastPathComponent
            add("toolcache:\(name)", "Tool cache: ~/.cache/\(name)", .toolCache, paths: [path], owners: [name],
                cleanup: SystemDataCleanup(kind: .review, description: "A command-line tool's cache or runtime; the tool may download it again.", command: nil),
                minimum: Self.minimumItemBytes)
        }
        for path in children((home as NSString).appendingPathComponent("Library/Application Support")) {
            let name = (path as NSString).lastPathComponent
            add("appsupport:\(name)", "App data: \(name)", .appSupport, paths: [path], owners: [name],
                cleanup: SystemDataCleanup(kind: .review, description: "Data that belongs to the app (settings, libraries, downloads). Remove it with the app, not as junk.", command: nil),
                minimum: 100 * 1_000_000)
        }

        // Fixed locations.
        let system = locations.systemPaths
        let managed = { (description: String) in SystemDataCleanup(kind: .managedByMacOS, description: description, command: nil) }
        if let path = system["commandLineTools"] {
            add("developer:commandLineTools", "Xcode Command Line Tools", .developerTools, paths: [path],
                cleanup: SystemDataCleanup(kind: .review, description: "Needed by git, clang and Homebrew unless a full Xcode is selected with xcode-select.", command: nil))
        }
        add("packages:homebrew", "Homebrew", .packageManager, paths: [system["homebrew"], system["usrLocal"]].compactMap { $0 },
            cleanup: SystemDataCleanup(kind: .command, description: "Installed packages. Running `brew cleanup` in Terminal removes old versions and downloads; most of this size is the packages themselves.", command: nil))
        add("logs:unified", "Unified system log", .logs, paths: [system["unifiedLog"], system["uuidtext"]].compactMap { $0 },
            cleanup: managed("Rotated by logd; deleting it removes the logs needed for troubleshooting."))
        if let path = system["systemReports"] {
            add("reports:diagnostic", "Diagnostic and crash reports", .diagnosticReports,
                paths: [path, (home as NSString).appendingPathComponent("Library/Logs/DiagnosticReports")],
                cleanup: SystemDataCleanup(kind: .command, description: "Old reports are deleted from Free now.", command: nil))
        }
        if let path = system["systemAssets"] {
            add("assets:system", "System assets (MobileAsset)", .systemAssets, paths: [path],
                cleanup: SystemDataCleanup(kind: .command, description: "Unused assets are removed from Free now when macOS reports any; the rest is in use.", command: nil))
        }
        if let path = system["spotlight"] {
            add("index:spotlight", "Spotlight index", .spotlightIndex, paths: [path],
                cleanup: SystemDataCleanup(kind: .command, description: "Rebuilt by Spotlight; macOS manages it.", command: nil))
        }
        if let path = system["documentRevisions"] {
            add("versions:documents", "Document version history (Versions / Auto Save)", .documentVersions, paths: [path],
                cleanup: managed("Kept by revisiond for File > Revert To > Browse All Versions; old versions of a document can be deleted from that browser. Deleting the store removes all version history."),
                notes: ["Versions share blocks with their documents where possible, so its real cost can be lower than its size."])
        }
        if let path = system["installData"] {
            // Staged data older than the installed system belongs to an update that is long finished, not to one that is waiting.
            func modified(_ path: String?) -> Date? { path.flatMap { try? fileManager.attributesOfItem(atPath: $0)[.modificationDate] as? Date } }
            let leftover = modified(path).flatMap { staged in modified(system["systemVersion"]).map { staged < $0 } } ?? false
            if leftover {
                add("update:staged", "Leftover macOS update files", .stagedUpdate, paths: [path],
                    cleanup: managed("Files of an earlier macOS update that is already installed; no update is waiting. macOS has not removed them and they sit in a protected folder, so MacSpace leaves them alone."))
            } else {
                add("update:staged", "Staged macOS update", .stagedUpdate, paths: [path],
                    cleanup: SystemDataCleanup(kind: .review, description: "A downloaded update that macOS installs or removes; check System Settings > General > Software Update.", command: nil))
            }
        }
        if let path = system["symbolCache"] {
            add("cache:symbolication", "Symbolication cache (coresymbolicationd)", .symbolCache, paths: [path],
                cleanup: managed("Symbols for crash reports and debugging; rebuilt on demand. Root-owned."))
        }
        add("system:swap", "Swap and sleep files", .virtualMemory, paths: [system["swap"]].compactMap { $0 },
            cleanup: managed("Managed by the kernel; shrinks after a restart."))
        add("logs:powerlog", "Power log", .logs, paths: [system["powerlog"]].compactMap { $0 },
            cleanup: managed("Battery and energy history used by System Settings > Battery."))
        let library = (home as NSString).appendingPathComponent("Library")
        for folder in ["Group Containers", "Containers"] {
            guard hasFullDiskAccess else { unreadable.append((library as NSString).appendingPathComponent(folder)); continue }
            for path in children((library as NSString).appendingPathComponent(folder)) {
                let name = (path as NSString).lastPathComponent
                let apple = name.hasPrefix("com.apple.") || name.hasPrefix("group.com.apple.")
                add("container:\(name)", "\(folder == "Containers" ? "App container" : "App group data"): \(name)", .appContainer, paths: [path], owners: [name],
                    cleanup: apple ? managed("Data of an Apple app or service.")
                                   : SystemDataCleanup(kind: .review, description: "Data of a sandboxed app (for messaging apps, mostly media); clean it from inside the app.", command: nil),
                    minimum: 100 * 1_000_000)
            }
        }
        add("containers:daemons", "Daemon containers", .appContainer, paths: [(library as NSString).appendingPathComponent("Daemon Containers")],
            cleanup: managed("Data of Apple background services."))
        add("metadata:spotlight", "Per-user Spotlight metadata", .spotlightMetadata, paths: [(library as NSString).appendingPathComponent("Metadata")],
            cleanup: managed("CoreSpotlight indexes for apps' searchable content."))
        if !hasFullDiskAccess { unreadable.append((library as NSString).appendingPathComponent("CloudStorage")) }
        for path in children((library as NSString).appendingPathComponent("CloudStorage")) where hasFullDiskAccess {
            let name = (path as NSString).lastPathComponent
            add("cloud:\(name)", "Cloud storage: \(name)", .cloudStorage, paths: [path], owners: [name],
                cleanup: SystemDataCleanup(kind: .review, description: "Local copies of cloud files; use \"Remove Download\" / \"Free Up Space\" in Finder to keep them online-only.", command: nil),
                minimum: 100 * 1_000_000)
        }
        // Large files people forget: unfinished downloads, restore images and virtual machines.
        func scan(_ directory: String, depth: Int, _ visit: (String) -> Void) {
            for path in children(directory) {
                visit(path)
                var isDirectory: ObjCBool = false
                let name = (path as NSString).lastPathComponent
                let bundle = (Self.virtualMachineSuffixes + Self.partialDownloadSuffixes).contains { name.hasSuffix($0) }
                if depth > 1, !bundle, fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    scan(path, depth: depth - 1, visit)
                }
            }
        }
        let review = { (description: String) in SystemDataCleanup(kind: .review, description: description, command: nil) }
        if !hasFullDiskAccess { unreadable.append((home as NSString).appendingPathComponent("Downloads")) }
        if hasFullDiskAccess { scan((home as NSString).appendingPathComponent("Downloads"), depth: 2) { path in
            let name = (path as NSString).lastPathComponent
            if let suffix = Self.partialDownloadSuffixes.first(where: { name.hasSuffix($0) }) {
                let owner = suffix == ".prlupd-part" ? "Parallels Desktop" : (suffix == ".crdownload" ? "Google Chrome" : (suffix == ".download" ? "Safari" : "the downloading app"))
                add("download:\(name)", "Unfinished download: \(name)", .partialDownload, paths: [path], owners: [owner],
                    cleanup: review("An unfinished download by \(owner). If \(owner) is no longer downloading it, delete it."),
                    notes: ["macOS cannot classify unfinished downloads as documents, so System Settings counts them as System Data."],
                    minimum: 100 * 1_000_000)
            } else if name.lowercased().hasSuffix(".ipsw") {
                add("ipsw:\(name)", "macOS restore image: \(name)", .restoreImage, paths: [path],
                    cleanup: review("A macOS restore image. Once the Mac, device or virtual machine it was downloaded for is set up, it can be deleted."),
                    minimum: 500 * 1_000_000)
            }
        } }
        for folder in ["Parallels", "Virtual Machines.localized", "Library/Containers/com.utmapp.UTM/Data/Documents"]
        where hasFullDiskAccess || !folder.hasPrefix("Library/Containers") {
            scan((home as NSString).appendingPathComponent(folder), depth: 1) { path in
                let name = (path as NSString).lastPathComponent
                guard Self.virtualMachineSuffixes.contains(where: { name.hasSuffix($0) }) else { return }
                add("vm:\(name)", "Virtual machine: \(name)", .virtualMachine, paths: [path],
                    cleanup: review("A virtual machine's disk and state. Delete machines you no longer use from the virtualization app."),
                    minimum: 500 * 1_000_000)
            }
        }
        // Home folders of deleted accounts: macOS keeps them when "Don't change the home folder" or "Save as disk image" is chosen.
        if let users = system["users"] {
            let canReadOtherHomes = self.canReadOtherHomes
            let orphanCleanup = SystemDataCleanup(kind: .review, description: "The home folder of an account that no longer exists. Copy anything you need from it, then delete it (an administrator password is needed).", command: nil)
            for path in children(users) where !Self.usersFolderEntries.contains((path as NSString).lastPathComponent) {
                guard let owner = (try? fileManager.attributesOfItem(atPath: path)[.ownerAccountID] as? NSNumber)?.uint32Value,
                      owner != 0, !accountExists(owner) else { continue }
                let name = (path as NSString).lastPathComponent
                add("orphanhome:\(name)", "Home folder of a deleted account: \(name)", .orphanedHome, paths: [path],
                    cleanup: orphanCleanup, notes: ["Owned by user ID \(owner), which no longer has an account."], measurable: canReadOtherHomes)
            }
            for path in children((users as NSString).appendingPathComponent("Deleted Users")) where !(path as NSString).lastPathComponent.hasPrefix(".") {
                let name = (path as NSString).lastPathComponent
                add("orphanhome:deleted:\(name)", "Saved home folder of a deleted account: \(name)", .orphanedHome, paths: [path],
                    cleanup: orphanCleanup, notes: ["Saved by System Settings when the account was deleted."], measurable: canReadOtherHomes)
            }
        }
        add("trash:user", "Trash", .trash, paths: [(home as NSString).appendingPathComponent(".Trash")],
            cleanup: SystemDataCleanup(kind: .review, description: "Empty the Trash in Finder; macOS can also do it automatically after 30 days.", command: nil))

        finish()
        for (kind, bytes) in smallBytes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            items.append(SystemDataItem(id: "small:\(kind.rawValue)", title: "Smaller items", kind: kind, paths: [], bytes: bytes, readable: true, owners: [], inUse: false,
                                        cleanup: SystemDataCleanup(kind: .review, description: "Many small entries, each below the listing size.", command: nil), notes: []))
        }
        items.sort { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        let volumeUsage = volumes()
        var warnings: [String] = []
        if !unreadable.isEmpty { warnings.append("\(unreadable.count) location(s) need Full Disk Access or root to measure.") }
        let measured = items.compactMap(\.bytes).reduce(0, +)
        let cleanable = items.filter { $0.cleanup.kind == .deleteWhenNotRunning }.compactMap(\.expectedReclaimBytes).reduce(0, +)
        var report = SystemDataReport(schemaVersion: SystemDataSchema.version, generatedAt: now, volumes: volumeUsage, items: items,
                                      measuredBytes: measured, cleanableBytes: cleanable, manualCleanup: ManualCleanupGuides.summaries(for: items),
                                      unreadable: unreadable, warnings: warnings)
        report.fullDiskAccess = hasFullDiskAccess
        return report
    }
}

// MARK: - Cleanup

public struct SystemDataCleanupResult: Codable, Equatable, Sendable {
    public let itemID: String
    public let deleted: Bool
    public let detail: String
}

public struct SystemDataCleanupReport: Codable, Equatable, Sendable {
    public let results: [SystemDataCleanupResult]
    /// Measured change in the Data volume's free space; the only trustworthy number for APFS clones.
    public let freeBytesBefore: UInt64?
    public let freeBytesAfter: UInt64?
}

/// Deletes `deleteWhenNotRunning` items after re-checking that no owner is running. Not journaled: caches and
/// clones are recreated by macOS or the app, not restored.
public struct SystemDataCleaner {
    private let fileManager: FileManager
    private let runningApps: () -> [RunningApp]
    private let freeSpace: () -> UInt64?

    public init(fileManager: FileManager = .default, runningApps: @escaping () -> [RunningApp] = SystemDataInspector.liveRunningApps,
                freeSpace: @escaping () -> UInt64? = SystemDataCleaner.dataVolumeFreeBytes) {
        self.fileManager = fileManager
        self.runningApps = runningApps
        self.freeSpace = freeSpace
    }

    public static func dataVolumeFreeBytes() -> UInt64? { DataVolume.freeBytes() }

    public func clean(_ items: [SystemDataItem], allowedRoots: [String]) -> SystemDataCleanupReport {
        let before = freeSpace()
        let running = runningApps()
        let results = items.map { item -> SystemDataCleanupResult in
            guard item.cleanup.kind == .deleteWhenNotRunning else {
                return SystemDataCleanupResult(itemID: item.id, deleted: false, detail: "Not a cleanable item (\(item.cleanup.kind.rawValue)).")
            }
            if let owner = item.owners.first(where: { owner in
                running.contains { $0.bundleIdentifier?.caseInsensitiveCompare(owner) == .orderedSame
                    || $0.name.map { $0.caseInsensitiveCompare(owner) == .orderedSame || owner.lowercased().contains($0.lowercased()) && $0.count >= 4 } == true }
            }) {
                return SystemDataCleanupResult(itemID: item.id, deleted: false, detail: "\(owner) is running; quit it first.")
            }
            for path in item.paths {
                let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
                guard allowedRoots.contains(where: { standardized.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else {
                    return SystemDataCleanupResult(itemID: item.id, deleted: false, detail: "\(path) is outside the cleanable locations.")
                }
                do { try fileManager.removeItem(atPath: standardized) } catch {
                    return SystemDataCleanupResult(itemID: item.id, deleted: false, detail: (error as NSError).localizedDescription)
                }
            }
            return SystemDataCleanupResult(itemID: item.id, deleted: true, detail: "Deleted \(item.paths.joined(separator: ", ")).")
        }
        return SystemDataCleanupReport(results: results, freeBytesBefore: before, freeBytesAfter: freeSpace())
    }

    /// The directories cleanable items may live in.
    public static func allowedRoots(_ locations: SystemDataLocations) -> [String] {
        var roots: [String] = []
        if let userDir = locations.userSystemDirectory {
            roots.append(userDir.appendingPathComponent("X").path)
            roots.append(userDir.appendingPathComponent("C").path)
        }
        return roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }
}

struct SizeMeasurement {
    var bytes: UInt64?
    var readable = false
    var unreadableEntry: String?
}

/// Collects parallel measurements; each index is written once.
final class MeasurementResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SizeMeasurement]

    init(count: Int) { values = Array(repeating: SizeMeasurement(bytes: nil), count: count) }

    func set(_ index: Int, _ value: SizeMeasurement) { lock.lock(); values[index] = value; lock.unlock() }
    func get(_ index: Int) -> SizeMeasurement { lock.lock(); defer { lock.unlock() }; return values[index] }
}
