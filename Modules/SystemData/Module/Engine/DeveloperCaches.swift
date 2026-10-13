import Foundation
import MacSpacePlatform

/// A developer tool's cache: build files Xcode keeps per project, device files per OS version, simulators that can no longer run, and
/// the download caches of package managers. Each comes back when the tool needs it again, at the cost of a slower next build or a new
/// download. Measured on the development Mac (2026-10-12): cargo 290 MB, SwiftPM 64 MB, pip 16 MB; DerivedData and simulators are
/// often tens of GB on a working developer's Mac.
public struct DeveloperCache: Codable, Equatable, Sendable {
    public enum Method: Codable, Equatable, Sendable {
        /// The folders are deleted, as an app cache is (renamed, then deleted, while no owner runs).
        case delete
        /// `xcrun simctl delete unavailable`: the simulators whose system Xcode no longer has.
        case unavailableSimulators
        /// `go clean -modcache`: Go writes its module cache read-only, so its own command removes it.
        case goModules(go: String)
    }

    public var id: String
    public var title: String
    public var paths: [String]
    public var bytes: UInt64
    /// The newest change in it; nil when not read (the simulators).
    public var lastChange: Date?
    /// Programs whose running instance stops the cleanup.
    public var owners: [String]
    public var method: Method
    /// Why it is recommended, as a pill; nil when it is not.
    public var reason: String?

    public var recommended: Bool { reason != nil }
}

public enum DeveloperCaches {
    /// Unchanged this long, a tool's cache is recommended: the tool downloads again what a project still needs.
    static let unusedDays = 7.0

    /// A package manager's cache: where it is under the home folder, and the programs that use it.
    struct Folder {
        let id: String
        let title: String
        let path: String
        let owners: [String]
    }

    static let folders: [Folder] = [
        Folder(id: "npm", title: "npm", path: ".npm/_cacache", owners: ["npm", "node"]),
        Folder(id: "yarn", title: "Yarn", path: "Library/Caches/Yarn", owners: ["yarn", "node"]),
        Folder(id: "pnpm", title: "pnpm", path: "Library/pnpm/store", owners: ["pnpm", "node"]),
        Folder(id: "bun", title: "Bun", path: ".bun/install/cache", owners: ["bun"]),
        Folder(id: "bun-library", title: "Bun", path: "Library/Caches/bun", owners: ["bun"]),
        Folder(id: "pip", title: "pip", path: "Library/Caches/pip", owners: ["pip", "pip3", "python", "python3"]),
        Folder(id: "uv", title: "uv", path: ".cache/uv", owners: ["uv"]),
        Folder(id: "swiftpm", title: loc("Swift packages"), path: "Library/Caches/org.swift.swiftpm", owners: ["swift-build", "swift-package", "xcodebuild", "Xcode"]),
        Folder(id: "cocoapods", title: "CocoaPods", path: "Library/Caches/CocoaPods", owners: ["pod"]),
        Folder(id: "gradle", title: "Gradle", path: ".gradle/caches", owners: ["gradle", "java"]),
        Folder(id: "cargo", title: loc("Rust packages"), path: ".cargo/registry", owners: ["cargo", "rustc", "rust-analyzer"]),
        Folder(id: "gobuild", title: loc("Go builds"), path: "Library/Caches/go-build", owners: ["go"]),
        Folder(id: "precommit", title: "pre-commit", path: ".cache/pre-commit", owners: ["pre-commit"]),
        Folder(id: "simulatorcaches", title: loc("Simulator caches"), path: "Library/Developer/CoreSimulator/Caches", owners: ["Simulator"]),
    ]

    /// The folders of `~/Library/Caches` and `~/.cache` this list claims, so they are listed here only, not again as an app's or a
    /// tool's cache.
    static func claimed(under folder: String) -> Set<String> {
        Set(folders.compactMap { entry -> String? in
            guard entry.path.hasPrefix(folder + "/") else { return nil }
            return entry.path.dropFirst(folder.count + 1).split(separator: "/").first.map(String.init)
        })
    }

    public static var claimedLibraryCaches: Set<String> { claimed(under: "Library/Caches") }
    public static var claimedToolCaches: Set<String> { claimed(under: ".cache") }

    /// Everything found under `home`, 1 MB or more, largest first.
    public static func scan(home: String = FileManager.default.homeDirectoryForCurrentUser.path, now: Date = Date()) -> [DeveloperCache] {
        var found: [DeveloperCache] = []
        func measured(_ id: String, _ title: String, _ path: String, owners: [String], method: DeveloperCache.Method = .delete,
                      reason: (Date) -> String?) {
            guard FileManager.default.fileExists(atPath: path), let dates = AppCaches.measure(path, now: now), dates.bytes >= 1_000_000 else { return }
            found.append(DeveloperCache(id: "dev:\(id)", title: title, paths: [path], bytes: dates.bytes, lastChange: dates.lastChange,
                                        owners: owners, method: method, reason: reason(dates.lastChange)))
        }
        func unused(_ lastChange: Date) -> String? {
            let days = Int(now.timeIntervalSince(lastChange) / 86_400)
            return Double(days) >= unusedDays ? loc("Unchanged for \(days) days") : nil
        }
        let xcode = (home as NSString).appendingPathComponent("Library/Developer/Xcode")
        let xcodeOwners = ["Xcode", "xcodebuild", "SourceKitService"]

        // Xcode's build files, one folder per project: its project gone, they are of no use.
        let derived = (xcode as NSString).appendingPathComponent("DerivedData")
        for path in children(derived) {
            let name = (path as NSString).lastPathComponent
            if name == "ModuleCache.noindex" {
                measured("derived:\(name)", loc("Xcode module cache"), path, owners: xcodeOwners, reason: unused)
                continue
            }
            let workspace = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("info.plist"))?["WorkspacePath"] as? String
            let project = name.split(separator: "-").dropLast().joined(separator: "-")
            measured("derived:\(name)", loc("Xcode builds: \(project.isEmpty ? name : project)"), path, owners: xcodeOwners) { lastChange in
                if let workspace, !FileManager.default.fileExists(atPath: workspace) { return loc("Project deleted") }
                return unused(lastChange)
            }
        }

        // The files Xcode copies from each device's system to debug on it, one folder per version: only the newest of each system is
        // likely to be needed again.
        for system in ["iOS", "iPadOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            let folder = (xcode as NSString).appendingPathComponent("\(system) DeviceSupport")
            let versions = children(folder).sorted { version(of: $0).lexicographicallyPrecedes(version(of: $1)) }
            for (index, path) in versions.enumerated() {
                let name = (path as NSString).lastPathComponent
                let newest = index == versions.count - 1
                measured("support:\(system):\(name)", loc("\(system) \(name) device files"), path, owners: xcodeOwners) { _ in
                    newest ? nil : loc("Older version")
                }
            }
        }

        // Simulators whose system Xcode no longer has: they cannot start again.
        if let simulators = unavailableSimulators(home: home) { found.append(simulators) }

        for folder in folders {
            measured(folder.id, folder.title, (home as NSString).appendingPathComponent(folder.path), owners: folder.owners, reason: unused)
        }

        // Go's module cache, through Go's own command (its files are read-only), only when Go is installed.
        if let go = ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go"].first(where: FileManager.default.isExecutableFile(atPath:)) {
            measured("gomodules", loc("Go modules"), (home as NSString).appendingPathComponent("go/pkg/mod"), owners: ["go", "gopls"],
                     method: .goModules(go: go), reason: unused)
        }
        return found.sorted { $0.bytes > $1.bytes }
    }

    /// "18.2 (22C152)" or "iPhone15,2 18.2 (22C152)" as numbers, to sort versions: 18.10 comes after 18.9.
    static func version(of path: String) -> [Int] {
        let name = (path as NSString).lastPathComponent
        let token = name.split(separator: " ").first { $0.first?.isNumber == true } ?? Substring(name)
        return token.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func children(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }
            .map { (folder as NSString).appendingPathComponent($0) }
    }

    // MARK: Simulators

    /// The simulators that cannot run, as one cache. Asked only when a full Xcode is selected and simulators exist: without Xcode,
    /// `xcrun` offers to install the Command Line Tools in a dialog.
    static func unavailableSimulators(home: String) -> DeveloperCache? {
        let devices = (home as NSString).appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        guard !children(devices).isEmpty, let developer = selectedDeveloperDirectory(), developer.contains(".app/") else { return nil }
        let run = HomebrewCleanup.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"], timeout: 30)
        guard run.status == 0, let data = run.stdout.data(using: .utf8),
              let list = try? JSONDecoder().decode(SimulatorList.self, from: data) else { return nil }
        let paths = list.devices.values.flatMap { $0 }.filter { $0.isAvailable == false }
            .map { (devices as NSString).appendingPathComponent($0.udid) }.filter(FileManager.default.fileExists(atPath:))
        let bytes = paths.compactMap { AppCaches.measure($0)?.bytes }.reduce(0, +)
        guard bytes >= 1_000_000 else { return nil }
        return DeveloperCache(id: "dev:simulators", title: loc("Simulators that can't run"), paths: paths, bytes: bytes, lastChange: nil,
                              owners: ["Simulator"], method: .unavailableSimulators, reason: loc("Can't run"))
    }

    struct SimulatorList: Decodable {
        struct Device: Decodable {
            let udid: String
            let isAvailable: Bool?
        }
        let devices: [String: [Device]]
    }

    /// `xcode-select -p`, read from its link rather than by running it.
    static func selectedDeveloperDirectory() -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
    }

    // MARK: Freeing

    /// Frees the caches: the folders through the cleaner's checks (no owner running, nothing open in them), the simulators and Go's
    /// modules through their tools' own commands. Returns a line per cache for the details.
    static func free(_ caches: [DeveloperCache], home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        var details: [String] = []
        let folders = caches.filter { $0.method == .delete }
        if !folders.isEmpty {
            let items = folders.map { cache in
                SystemDataItem(id: cache.id, title: cache.title, kind: .toolCache, paths: cache.paths, bytes: cache.bytes, readable: true,
                               owners: cache.owners, inUse: false, cleanup: SystemDataCleanup(kind: .deleteWhenNotRunning, description: "", command: nil),
                               notes: [])
            }
            let report = SystemDataCleaner().clean(items, allowedRoots: allowedRoots(home: home))
            details += report.results.map { "\($0.deleted ? "Deleted" : "Skipped"): \($0.itemID). \($0.detail)" }
        }
        for cache in caches where cache.method != .delete {
            guard let processes = ProcessCheck.live.processes() else {
                details.append("Skipped: \(cache.id). Couldn't check which apps are open.")
                continue
            }
            if let owner = ProcessCheck.runningOwner(cache.owners, apps: SystemDataInspector.liveRunningApps(), processes: processes,
                                                     appPath: ProcessCheck.live.appPath) {
                details.append("Skipped: \(cache.id). \(owner) is running.")
                continue
            }
            let run: HomebrewCleanup.Run
            switch cache.method {
            case .unavailableSimulators: run = HomebrewCleanup.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 600)
            case let .goModules(go): run = HomebrewCleanup.run(go, ["clean", "-modcache"], timeout: 600)
            case .delete: continue
            }
            details.append(run.status == 0 ? "Deleted: \(cache.id)." : "Skipped: \(cache.id). \(run.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return details
    }

    /// The folders developer caches may be deleted from.
    static func allowedRoots(home: String) -> [String] {
        ["Library/Developer/Xcode", "Library/Developer/CoreSimulator/Caches", "Library/Caches", "Library/pnpm", ".npm", ".bun", ".cache", ".gradle", ".cargo"]
            .map { URL(fileURLWithPath: (home as NSString).appendingPathComponent($0)).standardizedFileURL.path }
    }
}
