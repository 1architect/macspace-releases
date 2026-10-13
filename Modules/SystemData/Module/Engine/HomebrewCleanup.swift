import Foundation
import MacSpacePlatform

/// Homebrew's own cleanup (`brew cleanup`), run as the user, the way they would run it in Terminal, with three of Homebrew's settings
/// changed for the run: no autoremove (plain `brew cleanup` also uninstalls formulae installed only as dependencies, which a cleanup
/// button must not do), no auto-update and no analytics (MacSpace uses the network for its updates only). Read in Homebrew 7.0.8's
/// source (`cleanup.rb`, `env_config.rb`) on 2026-10-12; the review is in the maintainer's notes.
///
/// Two ways: Homebrew's default (old versions, and downloads it no longer needs or that are older than 120 days), and with every
/// download (`--prune=all`), which Homebrew fetches again when it needs one. Each is measured first with a dry run (`-n`), which
/// changes nothing and takes about a second.
public enum HomebrewCleanup {
    public struct Estimate: Codable, Equatable, Sendable {
        /// What Homebrew says it would free, in its own units (decimal); nil when the dry run failed.
        public var bytes: UInt64?
        /// Homebrew's error, when the dry run failed: its "Error:" line ("Refusing to load cask … from untrusted tap …").
        public var error: String?
    }

    public struct Plan: Codable, Equatable, Sendable {
        public var brew: String
        public var standard: Estimate
        public var allDownloads: Estimate
    }

    /// Where Homebrew is: Apple silicon's prefix, then Intel's. An app does not get the shell's PATH, so it is not looked up there.
    static let locations = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public static func brew(fileManager: FileManager = .default) -> String? {
        locations.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Both dry runs (about a second each); nil when Homebrew is not installed, or has no package list yet: Homebrew downloads it
    /// (about 15 MB) before any command when it has none, even a dry run with auto-update off (`api.rb`, `fetch_api_files!`), and a
    /// scan must not use the network.
    public static func plan() -> Plan? {
        guard let brew = brew(), hasPackageList() else { return nil }
        return Plan(brew: brew, standard: estimate(brew, allDownloads: false), allDownloads: estimate(brew, allDownloads: true))
    }

    /// Homebrew's package list in its default cache (`api/internal/packages.<platform>.jws.json`). A brew started by an app uses the
    /// default cache: settings exported in a shell profile do not reach it.
    static func hasPackageList(cache: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Homebrew").path) -> Bool {
        let folder = (cache as NSString).appendingPathComponent("api/internal")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).contains { $0.hasPrefix("packages.") && $0.hasSuffix(".jws.json") }
    }

    static func arguments(allDownloads: Bool, dryRun: Bool) -> [String] {
        ["cleanup"] + (dryRun ? ["-n"] : []) + (allDownloads ? ["--prune=all"] : [])
    }

    static func estimate(_ brew: String, allDownloads: Bool) -> Estimate {
        let run = Self.run(brew, arguments(allDownloads: allDownloads, dryRun: true), timeout: 120)
        // A run that failed can print part of its list first: it says nothing about what a real run frees.
        guard run.status == 0 else { return Estimate(bytes: nil, error: errorLine(run.stderr) ?? "brew exited with status \(run.status)") }
        return Estimate(bytes: freed(run.stdout) ?? 0, error: nil)
    }

    /// Homebrew's total, its last line: "==> This operation would free approximately 138.2MB of disk space." (decimal units, no line
    /// at all when there is nothing to remove).
    static func freed(_ output: String) -> UInt64? {
        let pattern = #"(?:would free|has freed) approximately ([\d.,]+)\s*(B|KB|MB|GB|TB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).last,
              let numberRange = Range(match.range(at: 1), in: output), let unitRange = Range(match.range(at: 2), in: output),
              let number = Double(output[numberRange].replacingOccurrences(of: ",", with: "")) else { return nil }
        let scale: Double = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][String(output[unitRange])] ?? 1
        return UInt64(number * scale)
    }

    static func errorLine(_ stderr: String) -> String? {
        stderr.split(separator: "\n").last { $0.hasPrefix("Error:") }.map { String($0.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces) }
    }

    /// Whether Homebrew is already running (an install or upgrade): a cleanup then would delete the files it is unpacking.
    static func isRunning(_ brew: String, processes: [RunningProcess]) -> Bool {
        let prefix = ((brew as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return processes.contains { process in
            process.name == "brew" || process.executablePath.map { $0.hasPrefix(prefix + "/Library/Homebrew/") } == true
        }
    }

    /// The real cleanup. Returns Homebrew's output, and its error when it failed.
    static func clean(_ brew: String, allDownloads: Bool) -> (succeeded: Bool, freed: UInt64?, error: String?) {
        let run = Self.run(brew, arguments(allDownloads: allDownloads, dryRun: false), timeout: 1_800)
        guard run.status == 0 else { return (false, nil, errorLine(run.stderr) ?? "brew exited with status \(run.status)") }
        return (true, freed(run.stdout), nil)
    }

    struct Run {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs `brew` as the user, from `/`, with only what it needs in its environment (Homebrew rebuilds it anyway) and the three
    /// settings above. Killed after `timeout` seconds.
    static func run(_ brew: String, _ arguments: [String], timeout: TimeInterval) -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        var environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                           "HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1",
                           "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1"]
        for key in ["USER", "LOGNAME", "SHELL", "TMPDIR", "LANG"] { environment[key] = ProcessInfo.processInfo.environment[key] }
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // Read while it runs: a full pipe would stop it.
        let output = Collected()
        let reading = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            reading.enter()
            DispatchQueue.global().async {
                output.set(pipe.fileHandleForReading.readDataToEndOfFile(), out: isOut)
                reading.leave()
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            return Run(status: -1, stdout: "", stderr: "Error: \(error.localizedDescription)")
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
        }
        reading.wait()
        let (stdout, stderr) = output.get()
        return Run(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }

    /// What `brew` printed, filled by the two readers.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data(), stderr = Data()
        func set(_ data: Data, out: Bool) { lock.lock(); if out { stdout = data } else { stderr = data }; lock.unlock() }
        func get() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (stdout, stderr) }
    }
}
