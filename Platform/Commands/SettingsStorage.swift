import CoreServices
import Darwin
import Foundation

/// The startup disk as System Settings > General > Storage divides it, computed the way its Storage pane computes it. Decoded from
/// `StorageManagementService`, its category extensions and `Storage.appex` on macOS 27.2 (26B5091g) and checked against what
/// Settings showed on the same Mac:
///
/// - used is the volume's capacity less what is available for important use (free space and what macOS purges by itself);
/// - macOS is every volume of the startup container but Data (System, Preboot, Recovery, Update, VM) and the separate Recovery
///   container on the same disk (47.4458 GB of volumes against 47.45 GB in Settings, twice 1.5 hours apart; with the ISC container
///   too it would read 47.47, with the Apple Intelligence models added 48.16: the models in macOS's detail are not added to it);
/// - each category is a fixed set of places (Mail is `~/Library/Mail`, Messages its attachments, Documents the home folder without
///   `~/Library` and what other categories claim…);
/// - System Data is what is left of used once macOS and every category are taken off.
///
/// So System Data needs no list of what it holds: whatever MacSpace does not recognise on a Mac still lands in it.
public struct SettingsStorage: Codable, Equatable, Sendable {
    public struct Category: Codable, Equatable, Sendable {
        public var id: String
        public var bytes: UInt64

        public init(id: String, bytes: UInt64) {
            self.id = id
            self.bytes = bytes
        }
    }

    public var capacity: UInt64
    public var used: UInt64
    /// Settings' macOS: the volumes of the startup container other than Data, and the Recovery container's.
    public var macOS: UInt64
    public var categories: [Category]

    public init(capacity: UInt64, used: UInt64, macOS: UInt64, categories: [Category]) {
        self.capacity = capacity
        self.used = used
        self.macOS = macOS
        self.categories = categories
    }

    public func bytes(_ id: String) -> UInt64 { categories.first { $0.id == id }?.bytes ?? 0 }

    /// What Settings calls System Data: used, less macOS and every category.
    public var systemData: UInt64 {
        let taken = macOS + categories.map(\.bytes).reduce(0, +)
        return used > taken ? used - taken : 0
    }
}

/// One APFS volume, as `diskutil apfs list -plist` reports it.
public struct APFSVolumeUsage: Equatable, Sendable {
    public var device: String
    public var container: String
    public var roles: [String]
    public var bytesInUse: UInt64
    /// The container's partition ("disk0s2") and its type ("Apple_APFS", "Apple_APFS_Recovery", "Apple_APFS_ISC").
    public var store: String
    public var storeType: String

    public init(device: String, container: String, roles: [String], bytesInUse: UInt64, store: String = "", storeType: String = "") {
        self.device = device
        self.container = container
        self.roles = roles
        self.bytesInUse = bytesInUse
        self.store = store
        self.storeType = storeType
    }

    /// The whole disk a partition is on: "disk0s3" -> "disk0".
    static func wholeDisk(_ partition: String) -> String {
        guard let range = partition.range(of: #"^disk\d+"#, options: .regularExpression) else { return partition }
        return String(partition[range])
    }

    /// Every volume of every APFS container, with its container's partition type. Empty when diskutil cannot be run.
    public static func live() -> [APFSVolumeUsage] {
        var volumes = parse(diskutil(["apfs", "list", "-plist"]))
        var types: [String: String] = [:]
        for store in Set(volumes.map(\.store)) where !store.isEmpty {
            let info = (try? PropertyListSerialization.propertyList(from: diskutil(["info", "-plist", store]), format: nil)) as? [String: Any]
            types[store] = info?["Content"] as? String ?? ""
        }
        for index in volumes.indices { volumes[index].storeType = types[volumes[index].store] ?? "" }
        return volumes
    }

    static func diskutil(_ arguments: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    static func parse(_ data: Data) -> [APFSVolumeUsage] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return [] }
        return containers.flatMap { container -> [APFSVolumeUsage] in
            let reference = container["ContainerReference"] as? String ?? ""
            let store = ((container["PhysicalStores"] as? [[String: Any]])?.first?["DeviceIdentifier"] as? String) ?? ""
            return (container["Volumes"] as? [[String: Any]] ?? []).compactMap { volume in
                guard let device = volume["DeviceIdentifier"] as? String else { return nil }
                let inUse = (volume["CapacityInUse"] as? NSNumber)?.uint64Value ?? 0
                return APFSVolumeUsage(device: device, container: reference, roles: volume["Roles"] as? [String] ?? [], bytesInUse: inUse, store: store)
            }
        }
    }

    /// The volumes System Settings counts as macOS: all of the Data volume's container but its Data volumes, and every volume of a
    /// Recovery container on the same disk (the one Apple silicon Macs start recovery from).
    public static func systemVolumes(_ volumes: [APFSVolumeUsage], dataDevice: String) -> UInt64 {
        guard let boot = volumes.first(where: { $0.device == dataDevice }) else { return 0 }
        let disk = wholeDisk(boot.store)
        return volumes.filter { volume in
            volume.container == boot.container ? !volume.roles.contains("Data")
                : volume.storeType == "Apple_APFS_Recovery" && !disk.isEmpty && wholeDisk(volume.store) == disk
        }.map(\.bytesInUse).reduce(0, +)
    }
}

/// The apps Spotlight has indexed. Settings applies additional scopes and filters to this list.
public enum IndexedApps {
    public static func paths() -> [String] {
        guard let query = MDQueryCreate(kCFAllocatorDefault, "kMDItemContentType == 'com.apple.application-bundle'" as CFString, nil, nil),
              MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var paths: [String] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { paths.append(path) }
        }
        return paths
    }

    /// The apps not inside another app, outside macOS's own folders (whose apps are part of macOS).
    public static func outermost(_ paths: [String]) -> [String] {
        let sorted = paths.filter { !$0.hasPrefix("/System/") }.sorted()
        var kept: [String] = []
        for path in sorted where !kept.contains(where: { path.hasPrefix($0 + "/") }) { kept.append(path) }
        return kept
    }
}

/// Measures `SettingsStorage` on this Mac; every source can be replaced for tests.
public struct SettingsStorageMeter {
    public var home: URL
    public var dataVolume = "/System/Volumes/Data"
    public var root = ""
    public var volumes: () -> [APFSVolumeUsage] = APFSVolumeUsage.live
    public var apps: () -> [String] = IndexedApps.paths
    /// (capacity, available for important use) of the Data volume.
    public var space: () -> (UInt64, UInt64)? = SettingsStorageMeter.liveSpace
    public var dataDevice: () -> String? = SettingsStorageMeter.liveDataDevice
    /// iCloud Drive keeps Desktop and Documents: Settings counts them there, not in Documents.
    public var desktopAndDocumentsInICloud: () -> Bool = SettingsStorageMeter.liveDesktopAndDocumentsInICloud

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public static func liveSpace() -> (UInt64, UInt64)? {
        let values = try? URL(fileURLWithPath: DataVolume.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeTotalCapacity, let available = values?.volumeAvailableCapacityForImportantUsage, available >= 0 else { return nil }
        return (UInt64(capacity), UInt64(available))
    }

    public static func liveDataDevice() -> String? {
        var stats = statfs()
        guard statfs(DataVolume.path, &stats) == 0 else { return nil }
        let name = withUnsafeBytes(of: stats.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return name.hasPrefix("/dev/") ? String(name.dropFirst(5)) : name
    }

    public static func liveDesktopAndDocumentsInICloud() -> Bool {
        let documents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return (try? documents.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }
    func system(_ absolute: String) -> String { root + absolute }

    /// Every place a category other than System Data claims, for telling what in a folder is System Data. The home folder outside
    /// `~/Library` is Documents and is not listed: test it with `isDocuments`.
    public func claimedPlaces(apps: [String]) -> [String] { places(apps: applicationPaths(apps)).flatMap(\.paths) }

    /// The places Settings lists in its live categories, measured once per scan.
    public static func liveClaimedPlaces(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        SettingsStorageMeter(home: home).claimedPlaces(apps: IndexedApps.paths())
    }

    /// STMApplicationSizer searches home, /Applications and /System/Applications; the last belongs to macOS. It also skips
    /// home Library, the trash, bundles without identifiers, and nested apps even when Spotlight has not indexed their parent.
    func applicationPaths(_ paths: [String]) -> [String] {
        let applicationRoot = system("/Applications")
        let excludedIDs: Set<String> = ["com.apple.Music", "com.apple.iBooksX", "com.apple.mail", "com.apple.TV",
                                        "com.apple.podcasts", "com.apple.Photos", "com.apple.MobileSMS"]
        return IndexedApps.outermost(paths.filter { candidate in
            guard candidate.hasPrefix(applicationRoot + "/") || candidate.hasPrefix(home.path + "/"),
                  !candidate.hasPrefix(path("Library") + "/"), !candidate.hasPrefix(path(".Trash") + "/"),
                  let id = Bundle(path: candidate)?.bundleIdentifier, !id.isEmpty, !excludedIDs.contains(id) else { return false }
            var parent = URL(fileURLWithPath: candidate).deletingLastPathComponent()
            while parent.path != "/" {
                if ApplicationBundles.isApplication(parent.path) { return false }
                parent.deleteLastPathComponent()
            }
            return true
        })
    }

    /// Whether Settings counts `path` as Documents: in the home folder, outside `~/Library` (and outside the places other categories
    /// claim there, which `claimedPlaces` lists).
    public static func isDocuments(_ path: String, home: String) -> Bool {
        path.hasPrefix(home + "/") && path != home + "/Library" && !path.hasPrefix(home + "/Library/")
    }

    /// The places of each category, as Settings' extensions claim them (paths in the home folder are relative to it).
    func places(apps: [String]) -> [(id: String, paths: [String])] {
        var musicMedia = [path("Music/iTunes/iTunes Media")]
        // The Music app's media folder, wherever its library keeps it ("Media" or the localized "Media.localized").
        for name in ["Music/Music/Media", "Music/Music/Media.localized"] where FileManager.default.fileExists(atPath: path(name)) { musicMedia.append(path(name)) }
        return [
            // The whole /Applications folder (including files beside bundles), eligible indexed apps in home, and containers.
            ("applications", [system("/Applications")] + apps.filter { !$0.hasPrefix(system("/Applications") + "/") } + appContainers(apps: apps)
                + [path("Library/Application Support/Steam")]),
            ("developer", [system("/Library/Developer/CommandLineTools"), system("/Library/Developer/CoreSimulator"), path("Library/Developer"),
                           path("Library/Caches/com.apple.dt.Xcode"), system("/AppleInternal/Developer")]),
            ("photos", [photoLibrary()].compactMap { $0 }),
            ("music", musicMedia),
            ("tv", [path("Movies/TV/Media"), path("Movies/TV/TV Library"), path("Movies/Apple TV/Media")]),
            ("books", [path("Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books")]),
            ("mail", [path("Library/Mail")]),
            ("messages", [path("Library/Messages/Attachments")]),
            ("iCloudDrive", [path("Library/Mobile Documents")]),
            ("trash", [path(".Trash")]),
            ("iosFiles", [path("Library/Application Support/MobileSync/Backup"), path("Library/iTunes/iPhone Software Updates"),
                          path("Library/iTunes/iPad Software Updates"), path("Library/iTunes/iPod Software Updates"),
                          path("Library/iTunes/Apple TV Software Updates")]),
            ("garageBand", ["/Library/Application Support/GarageBand/Instrument Library", "/Library/Application Support/GarageBand/Learn to Play/Basic Lessons",
                            "/Library/Application Support/Logic/Alchemy Samples", "/Library/Application Support/Logic/Channel Strip Settings",
                            "/Library/Application Support/Logic/EXS Factory Samples", "/Library/Application Support/Logic/Plug-In Settings",
                            "/Library/Application Support/Logic/Sampler Instruments", "/Library/Application Support/Logic/Ultrabeat Samples",
                            "/Library/Audio/Apple Loops/Apple", "/Library/Audio/Impulse Responses/Apple"].map(system)),
            ("otherUsers", otherHomes()),
        ]
    }

    /// Containers of installed apps: every third-party one, and Apple's only for an app installed outside macOS's own folders (Safari).
    func appContainers(apps: [String]) -> [String] {
        let installed = Set(apps.compactMap { Bundle(path: $0)?.bundleIdentifier?.lowercased() })
        var paths: [String] = []
        for name in children(path("Library/Containers")) {
            let id = name.lowercased()
            let apple = id.hasPrefix("com.apple.")
            if !apple || installed.contains(id) || installed.contains(where: { id.hasPrefix($0 + ".") }) { paths.append(path("Library/Containers/\(name)")) }
        }
        // Apple's own group containers belong to macOS (`group.com.apple.…`); team-prefixed ones go with the app (Apple's pro apps).
        for name in children(path("Library/Group Containers")) where !name.lowercased().hasPrefix("group.com.apple.") && !name.lowercased().hasPrefix("com.apple.") {
            paths.append(path("Library/Group Containers/\(name)"))
        }
        return paths
    }

    func photoLibrary() -> String? {
        let fallback = path("Pictures/Photos Library.photoslibrary")
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    func otherHomes() -> [String] {
        children(system("/Users")).filter { $0 != home.lastPathComponent && !$0.hasPrefix(".") }.map { system("/Users/\($0)") }
    }

    func children(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0 != ".DS_Store" && $0 != ".localized" }
    }

    /// How many places are measured at the same time. The scan of System Data's items runs beside this one.
    static let workers = 3

    public func measure() -> SettingsStorage? {
        guard let (capacity, available) = space(), capacity >= available else { return nil }
        let systemVolumes = dataDevice().map { APFSVolumeUsage.systemVolumes(volumes(), dataDevice: $0) } ?? 0
        let apps = applicationPaths(self.apps())
        let places = places(apps: apps)
        // Documents: the home folder without ~/Library, ~/Applications, the trash and every place another category claims there (the
        // media folders Settings names, the apps Spotlight found); Desktop and Documents too when iCloud Drive keeps them.
        var excluded = Set(places.flatMap(\.paths).filter { $0.hasPrefix(home.path + "/") })
        for name in ["Library", "Applications", ".Trash", "Music/iTunes/iTunes Media", "Music/Music/Media", "Movies/Apple TV/Media",
                     "Movies/TV/Media", "Movies/TV/TV Library"] { excluded.insert(path(name)) }
        if desktopAndDocumentsInICloud() { excluded.formUnion([path("Desktop"), path("Documents")]) }
        // Every place, and the home folder for Documents, measured side by side: one after the other they took 10 seconds.
        let jobs = places.flatMap { $0.paths.map { AllocatedSize.Job(path: $0) } }
            + [AllocatedSize.Job(path: home.path, excluding: excluded, excludingApplications: true)]
        let sizes = AllocatedSize.allocatedBytes(jobs, workers: Self.workers)
        var next = 0
        var categories = places.map { place in
            defer { next += place.paths.count }
            return SettingsStorage.Category(id: place.id, bytes: sizes[next..<next + place.paths.count].reduce(0, +))
        }
        categories.insert(SettingsStorage.Category(id: "documents", bytes: sizes[next]), at: 1)
        return SettingsStorage(capacity: capacity, used: capacity - available, macOS: systemVolumes, categories: categories)
    }
}

/// Allocated sizes of folder trees, as `du` counts them: each file's blocks once (a hard-linked file at its first path), folders still only in the cloud skipped
/// (listing them would make the cloud app fetch them).
public enum AllocatedSize {
    public struct Job: Sendable {
        public var path: String
        public var excluding: Set<String>
        public var excludingApplications: Bool

        public init(path: String, excluding: Set<String> = [], excludingApplications: Bool = false) {
            self.path = path
            self.excluding = excluding
            self.excludingApplications = excludingApplications
        }
    }

    public static func allocatedBytes(_ root: String, excluding excluded: Set<String>, excludingApplications: Bool = false) -> UInt64 {
        var info = stat()
        guard lstat(root, &info) == 0 else { return 0 }
        guard info.st_mode & S_IFMT == S_IFDIR else { return UInt64(max(info.st_blocks, 0)) * 512 }
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { return 0 }
        // A file reached by several hard links counts once (`HardLinks`).
        struct Sums { var total: UInt64 = 0, links = Set<UInt64>() }
        return DirectoryWalk.walk(root, extended: false, initial: Sums()) { sums, path, entry in
            if !excluded.isEmpty, excluded.contains(path()) { return .skip }
            if excludingApplications && ApplicationBundles.isApplication(path()) { return .skip }
            if entry.isDirectory {
                return entry.isDataless ? .skip : .descend
            }
            if entry.linkCount > 1, entry.isRegularFile, let inode = HardLinks.inode(path()), !sums.links.insert(inode).inserted { return .skip }
            sums.total += entry.allocatedBytes
            return .skip
        }.state.total
    }

    /// Several trees at once, `workers` at a time, in the order given.
    public static func allocatedBytes(_ jobs: [(path: String, excluding: Set<String>)], workers: Int) -> [UInt64] {
        allocatedBytes(jobs.map { Job(path: $0.path, excluding: $0.excluding) }, workers: workers)
    }

    public static func allocatedBytes(_ jobs: [Job], workers: Int) -> [UInt64] {
        let results = LockedArray(repeating: UInt64(0), count: jobs.count)
        let queue = JobCounter(count: jobs.count)
        DispatchQueue.concurrentPerform(iterations: min(max(workers, 1), max(jobs.count, 1))) { _ in
            while let index = queue.next() {
                let job = jobs[index]
                results.set(index, allocatedBytes(job.path, excluding: job.excluding, excludingApplications: job.excludingApplications))
            }
        }
        return results.values
    }
}

private enum ApplicationBundles {
    /// Match the Documents reporter's case-sensitive suffix check followed by NSURLIsApplicationKey, rather than guessing from
    /// an extension alone. Check files too: macOS can return true for a regular file named *.app.
    static func isApplication(_ path: String) -> Bool {
        path.hasSuffix(".app") && (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true
    }
}

/// Hands out the indices 0..<count once each, to workers pulling the next as they finish one.
public final class JobCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private var issued = 0

    public init(count: Int) { self.count = count }

    public func next() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard issued < count else { return nil }
        issued += 1
        return issued - 1
    }
}

/// An array written by parallel workers, each index once.
public final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element]

    public init(repeating value: Element, count: Int) { storage = Array(repeating: value, count: count) }

    public func set(_ index: Int, _ value: Element) { lock.lock(); storage[index] = value; lock.unlock() }
    public var values: [Element] { lock.lock(); defer { lock.unlock() }; return storage }
}
