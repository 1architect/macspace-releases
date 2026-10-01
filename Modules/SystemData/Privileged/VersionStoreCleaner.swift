import Foundation
import MacSpacePlatform

/// Deletes the contents of the macOS Versions store (`/System/Volumes/Data/.DocumentRevisions-V100`), which holds the saved
/// history behind File > Revert To > Browse All Versions. The history of every document goes; the documents themselves do not.
///
/// revisiond owns the store, so it is stopped first, the folder's contents are removed (never the folder), and revisiond is
/// started again, which rebuilds an empty store. If revisiond cannot be stopped, nothing is deleted.
public struct VersionStoreResult: Codable, Equatable, Sendable {
    public let executed: Bool
    public let bytesBefore: UInt64?
    public let bytesAfter: UInt64?
    public let removedEntries: Int
    public let daemonRestarted: Bool
    public let error: String?

    public init(executed: Bool, bytesBefore: UInt64?, bytesAfter: UInt64?, removedEntries: Int, daemonRestarted: Bool, error: String?) {
        self.executed = executed
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.removedEntries = removedEntries
        self.daemonRestarted = daemonRestarted
        self.error = error
    }
}

public struct VersionStoreCleaner {
    public static let storePath = "/System/Volumes/Data/.DocumentRevisions-V100"
    public static let daemonLabel = "system/com.apple.revisiond"
    public static let daemonPlist = "/System/Library/LaunchDaemons/com.apple.revisiond.plist"

    let storePath: String
    let runner: any CommandRunning
    let fileManager: FileManager
    let sleep: (TimeInterval) -> Void

    public init(storePath: String = VersionStoreCleaner.storePath, runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 30),
                fileManager: FileManager = .default, sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.storePath = storePath
        self.runner = runner
        self.fileManager = fileManager
        self.sleep = sleep
    }

    func size() -> UInt64? {
        FileTreeSizer().size(at: URL(fileURLWithPath: storePath)).map { $0.allocatedBytesEstimate ?? $0.logicalBytes }
    }

    private func run(_ executable: String, _ arguments: [String]) -> CommandResult? { try? runner.run(executable, arguments) }

    private func launchctl(_ arguments: [String]) -> Bool { run("/bin/launchctl", arguments)?.exitCode == 0 }

    private func daemonPID() -> Int32? {
        guard let result = run("/usr/bin/pgrep", ["-x", "revisiond"]), result.exitCode == 0 else { return nil }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").first.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func startDaemon() -> Bool {
        launchctl(["bootstrap", "system", Self.daemonPlist]) || launchctl(["kickstart", Self.daemonLabel])
    }

    /// How the daemon was held still while the store is emptied.
    enum Hold { case unloaded, frozen(Int32) }

    /// Unloads revisiond. macOS may refuse that for its own services, so the fallback freezes the running process instead.
    func hold() -> (Hold?, String) {
        let bootout = run("/bin/launchctl", ["bootout", Self.daemonLabel])
        if bootout?.exitCode == 0 { return (.unloaded, "") }
        let why = bootout.map { String(decoding: $0.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "launchctl did not run"
        if let pid = daemonPID(), run("/bin/kill", ["-STOP", String(pid)])?.exitCode == 0 { return (.frozen(pid), why) }
        return (nil, why)
    }

    /// Starts revisiond again: a frozen process is killed so launchd (KeepAlive) starts a fresh one that rebuilds the store.
    func release(_ hold: Hold) -> Bool {
        switch hold {
        case .unloaded:
            return startDaemon()
        case let .frozen(pid):
            _ = run("/bin/kill", ["-KILL", String(pid)])
            for _ in 0..<20 {
                if let now = daemonPID(), now != pid { return true }
                sleep(0.5)
            }
            return startDaemon()
        }
    }

    public func execute() -> VersionStoreResult {
        guard fileManager.fileExists(atPath: storePath), let names = try? fileManager.contentsOfDirectory(atPath: storePath) else {
            return VersionStoreResult(executed: false, bytesBefore: nil, bytesAfter: nil, removedEntries: 0, daemonRestarted: false,
                                      error: "The version store could not be read.")
        }
        let before = size()
        let (held, why) = hold()
        guard let held else {
            return VersionStoreResult(executed: false, bytesBefore: before, bytesAfter: before, removedEntries: 0, daemonRestarted: false,
                                      error: "macOS would not let revisiond stop (\(why.isEmpty ? "no reason given" : why)), so nothing was deleted.")
        }
        var removed = 0
        var failures: [String] = []
        for name in names {
            do { try fileManager.removeItem(atPath: (storePath as NSString).appendingPathComponent(name)); removed += 1 }
            catch { failures.append("\(name): \(error.localizedDescription)") }
        }
        let restarted = release(held)
        let after = size()
        var problems = failures
        if !restarted { problems.append("revisiond did not restart; restart the Mac to start it again.") }
        return VersionStoreResult(executed: true, bytesBefore: before, bytesAfter: after, removedEntries: removed, daemonRestarted: restarted,
                                  error: problems.isEmpty ? nil : problems.joined(separator: " "))
    }
}
