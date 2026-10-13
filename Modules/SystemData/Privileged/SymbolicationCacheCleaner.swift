import Darwin
import Foundation
import MacSpacePlatform

/// Empties the cache coresymbolicationd keeps of apps' symbols, which crash reports and debugging tools read
/// (`/System/Library/Caches/com.apple.coresymbolicationd`): one memory-mapped archive, `data`, measured at 2.10 GB on 2026-09-30 and
/// 1.69 GB in System Settings' System Data on an earlier reading, on the development Mac. The folder is root's (`drwx------`) and has
/// no SIP flag. The daemon rebuilds the cache when it is gone (its own words: "%s does not exist, resetting cache").
///
/// The helper takes no path. It opens the folder without following links, deletes what is in it (never the folder), then stops the
/// daemon if it is running: it keeps the archive mapped, so its blocks would only come back when it exits on its own. launchd starts
/// it again on the next request (a Mach service), and it starts a new cache. A request that arrives while it is stopped waits for
/// launchd to start it.
public struct SymbolicationCacheResult: Codable, Equatable, Sendable {
    public let executed: Bool
    public let bytesBefore: UInt64?
    public let bytesAfter: UInt64?
    public let removedEntries: Int
    /// The daemon was running and stopped, so the mapped archive was let go.
    public let daemonStopped: Bool
    public let error: String?

    public init(executed: Bool, bytesBefore: UInt64?, bytesAfter: UInt64?, removedEntries: Int, daemonStopped: Bool, error: String?) {
        self.executed = executed
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.removedEntries = removedEntries
        self.daemonStopped = daemonStopped
        self.error = error
    }
}

public struct SymbolicationCacheCleaner {
    public static let cachePath = "/System/Library/Caches/com.apple.coresymbolicationd"
    public static let daemonName = "coresymbolicationd"

    let cachePath: String
    let runner: any CommandRunning
    let fileManager: FileManager
    let sleep: (TimeInterval) -> Void

    public init(cachePath: String = SymbolicationCacheCleaner.cachePath, runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 30),
                fileManager: FileManager = .default, sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.cachePath = cachePath
        self.runner = runner
        self.fileManager = fileManager
        self.sleep = sleep
    }

    func size() -> UInt64? { FileTreeSizer().size(at: URL(fileURLWithPath: cachePath))?.bytes }

    private func run(_ executable: String, _ arguments: [String]) -> CommandResult? { try? runner.run(executable, arguments) }

    func daemonPID() -> Int32? {
        guard let result = run("/usr/bin/pgrep", ["-x", Self.daemonName]), result.exitCode == 0 else { return nil }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").first.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Asks the daemon to quit, then makes it if it does not within five seconds. True once that process is gone.
    func stop(_ pid: Int32) -> Bool {
        for signal in ["-TERM", "-KILL"] {
            guard run("/bin/kill", [signal, String(pid)])?.exitCode == 0 else { return daemonPID() != pid }
            for _ in 0..<10 {
                if daemonPID() != pid { return true }
                sleep(0.5)
            }
        }
        return daemonPID() != pid
    }

    public func execute() -> SymbolicationCacheResult {
        // The folder itself must be a real folder, not a link put in its place.
        var info = stat()
        guard lstat(cachePath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            return SymbolicationCacheResult(executed: false, bytesBefore: nil, bytesAfter: nil, removedEntries: 0, daemonStopped: false,
                                            error: "The symbols cache is not there.")
        }
        let folder = open(cachePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else {
            return SymbolicationCacheResult(executed: false, bytesBefore: nil, bytesAfter: nil, removedEntries: 0, daemonStopped: false,
                                            error: "The symbols cache could not be opened: \(String(cString: strerror(errno))).")
        }
        close(folder)
        let before = size()
        var removed = 0
        var failures: [String] = []
        // Each entry goes as it is: a link is removed itself, never what it points to.
        for name in (try? fileManager.contentsOfDirectory(atPath: cachePath)) ?? [] {
            do { try fileManager.removeItem(atPath: (cachePath as NSString).appendingPathComponent(name)); removed += 1 }
            catch { failures.append("\(name): \(error.localizedDescription)") }
        }
        var stopped = false
        if removed > 0, let pid = daemonPID() {
            stopped = stop(pid)
            if !stopped { failures.append("coresymbolicationd did not stop; its space comes back when it quits by itself.") }
        }
        return SymbolicationCacheResult(executed: removed > 0, bytesBefore: before, bytesAfter: size(), removedEntries: removed, daemonStopped: stopped,
                                        error: failures.isEmpty ? nil : failures.joined(separator: " "))
    }
}
