import Foundation
import MacSpacePlatform

/// Erases the unified log, what Console shows (`/private/var/db/diagnostics`), and the format strings its entries are read with
/// (`/private/var/db/uuidtext`), with Apple's own `log erase`: logd deletes its own files, so nothing it is writing is taken away from
/// under it. 2.9 GB on the development Mac (1.6 GB of entries, 1.3 GB of format strings, 26B5101f, 2026-10-13).
///
/// `log erase --all` empties every store (Persist, Special, Signpost, HighVolume). `log erase --uuidtext` then prunes the format
/// strings no remaining entry needs: the same purge logd runs for CacheDelete ("Purging UUID Cache"), which reports nothing as
/// purgeable at any urgency, so macOS never frees them by itself. logd copies the strings of a program again the next time it logs
/// (`_logd_uuiddb_harvest`). Only the history goes: logging goes on, and the history starts again from the moment of the erase.
/// macOS's own Diagnostic and Usage data and crash reports are elsewhere and stay.
public struct UnifiedLogResult: Codable, Equatable, Sendable {
    public let executed: Bool
    /// The two folders together, before and after.
    public let bytesBefore: UInt64?
    public let bytesAfter: UInt64?
    /// The format strings were pruned too (`log erase --uuidtext`).
    public let prunedFormatStrings: Bool
    public let error: String?

    public init(executed: Bool, bytesBefore: UInt64?, bytesAfter: UInt64?, prunedFormatStrings: Bool, error: String?) {
        self.executed = executed
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
        self.prunedFormatStrings = prunedFormatStrings
        self.error = error
    }
}

public struct UnifiedLogCleaner {
    public static let storePath = "/private/var/db/diagnostics"
    public static let formatStringsPath = "/private/var/db/uuidtext"
    public static let tool = "/usr/bin/log"

    let paths: [String]
    let runner: any CommandRunning

    public init(paths: [String] = [UnifiedLogCleaner.storePath, UnifiedLogCleaner.formatStringsPath],
                runner: any CommandRunning = ProcessCommandRunner(defaultTimeout: 120)) {
        self.paths = paths
        self.runner = runner
    }

    func size() -> UInt64? {
        let sizes = paths.compactMap { FileTreeSizer().size(at: URL(fileURLWithPath: $0))?.bytes }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    /// The command's own words when it fails.
    private func erase(_ arguments: [String]) -> String? {
        do {
            let result = try runner.run(Self.tool, ["erase"] + arguments)
            guard result.exitCode != 0 else { return nil }
            let words = String(decoding: result.stderr + result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return "log erase \(arguments.joined(separator: " ")) failed (\(result.exitCode))\(words.isEmpty ? "" : ": \(words)")."
        } catch {
            return "log erase \(arguments.joined(separator: " ")) did not run: \(error.localizedDescription)"
        }
    }

    public func execute() -> UnifiedLogResult {
        let before = size()
        if let failure = erase(["--all"]) {
            return UnifiedLogResult(executed: false, bytesBefore: before, bytesAfter: before, prunedFormatStrings: false, error: failure)
        }
        // The entries are gone either way; a prune that fails only leaves the format strings.
        let pruneFailure = erase(["--uuidtext"])
        return UnifiedLogResult(executed: true, bytesBefore: before, bytesAfter: size(), prunedFormatStrings: pruneFailure == nil, error: pruneFailure)
    }
}
