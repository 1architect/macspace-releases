import Foundation

/// Receipt manifests describe installation history, never current exclusive ownership.
public struct AppReceiptManifest: Codable, Equatable, Sendable {
    public var identifier: String
    public var paths: [String]
    public var complete: Bool
    public var reason: String
    public init(identifier: String, paths: [String], complete: Bool, reason: String) {
        self.identifier = identifier; self.paths = Array(Set(paths)).sorted(); self.complete = complete; self.reason = reason
    }
}
public struct AppReceiptCatalog: Sendable {
    public var manifests: [AppReceiptManifest] = []
    public var complete = false
    public var reason = "Receipt inventory has not been read."
    fileprivate var stamps: [String: [Date]] = [:]
    public init() {}
    public func claims(owners: [AppOwner]) -> [String: [DiskOwnershipClaim]] {
        let installed = Set(owners.map(\.path))
        var result: [String: [DiskOwnershipClaim]] = [:]
        for receipt in manifests {
            var matches = Set<String>()
            for path in receipt.paths {
                var ancestor = (path as NSString).deletingLastPathComponent
                while ancestor != "/" && !ancestor.isEmpty {
                    if installed.contains(ancestor) { matches.insert(ancestor); break }
                    ancestor = (ancestor as NSString).deletingLastPathComponent
                }
            }
            guard !matches.isEmpty else { continue }
            // Small per-path records keep hashing/interning linear in manifest size.
            let claims = receipt.paths.map { DiskOwnershipClaim(paths: [$0], ownerPaths: Array(matches), confidence: .unknown,
                source: "receiptManifest:" + receipt.identifier,
                reason: "Installation history is not exclusive ownership. " + receipt.reason + (complete ? "" : " Receipt discovery is incomplete.")) }
            for path in matches { result[path, default: []].append(contentsOf: claims) }
        }
        return result
    }
}
public enum AppReceiptReader {
    /// Pure parser also used by fixtures. Absolute, traversing and ambiguous manifest records are rejected.
    public static func manifest(identifier: String, installPrefix: String, listing: String, complete: Bool) -> AppReceiptManifest {
        let prefixParts = installPrefix.split(separator: "/", omittingEmptySubsequences: true)
        guard !prefixParts.contains(".."), !installPrefix.contains("\n"), !installPrefix.contains("\t") else {
            return AppReceiptManifest(identifier: identifier, paths: [], complete: false, reason: "Invalid receipt install prefix.")
        }
        let prefix = "/" + prefixParts.filter { $0 != "." }.joined(separator: "/")
        var paths: [String] = [], valid = complete
        for raw in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            guard paths.count < 10_000 else { valid = false; break }
            let line = String(raw)
            let parts = line.split(separator: "/", omittingEmptySubsequences: false)
            guard !line.hasPrefix("/"), !line.contains("\t"), !line.contains("\r"), !parts.contains(".."), !parts.contains("") else { valid = false; continue }
            let relative = parts.filter { $0 != "." }.joined(separator: "/")
            guard !relative.isEmpty else { continue }
            let path = (prefix == "/" ? "" : prefix) + "/" + relative
            guard URL(fileURLWithPath: path).standardizedFileURL.path == path else { valid = false; continue }
            paths.append(path)
        }
        return AppReceiptManifest(identifier: identifier, paths: paths, complete: valid,
            reason: valid ? "Read-only BOM file manifest; files may have changed or be shared since installation." : "Manifest is incomplete, malformed or truncated; preserve all uncertain data.")
    }
    /// Bounded read-only adapter for the startup-volume receipt database. No pkgutil mutation commands.
    public static func read(previous: AppReceiptCatalog? = nil, directory: String = "/var/db/receipts", budget: TimeInterval = 2) -> AppReceiptCatalog {
        var result = AppReceiptCatalog()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { result.reason = "Receipt database is unreadable."; return result }
        let receipts = names.filter { $0.hasSuffix(".plist") }.sorted()
        let started = Date(), cached = Dictionary((previous?.manifests ?? []).map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        result.complete = true
        var retainedPaths = 0
        for name in receipts {
            guard Date().timeIntervalSince(started) < budget, result.manifests.count < 256, retainedPaths < 20_000 else { result.complete = false; break }
            let plist = directory + "/" + name, bom = String(plist.dropLast(6)) + ".bom"
            guard let info = NSDictionary(contentsOfFile: plist), let id = info["PackageIdentifier"] as? String,
                  let prefix = info["InstallPrefixPath"] as? String else { result.complete = false; continue }
            let stamps = [plist, bom].compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
            guard stamps.count == 2 else { result.complete = false; continue }
            if previous?.stamps[id] == stamps, let old = cached[id] {
                guard retainedPaths + old.paths.count <= 20_000 else { result.complete = false; break }
                result.manifests.append(old); retainedPaths += old.paths.count; result.stamps[id] = stamps; if !old.complete { result.complete = false }; continue
            }
            let output = listing(bom, timeout: max(0.05, budget - Date().timeIntervalSince(started)))
            var record = manifest(identifier: id, installPrefix: prefix, listing: output.text, complete: output.complete)
            if retainedPaths + record.paths.count > 20_000 {
                record.paths = Array(record.paths.prefix(20_000 - retainedPaths)); record.complete = false
                record.reason = "Receipt manifest exceeded the retained-path limit; preserve uncertain data."
            }
            result.manifests.append(record); retainedPaths += record.paths.count; result.stamps[id] = stamps
            if !record.complete { result.complete = false }
        }
        result.reason = result.complete ? "Startup-volume receipt manifests read; historical evidence only." : "Receipt inventory bounded or incomplete; no ownership exclusivity established."
        return result
    }
    private static func listing(_ bom: String, timeout: TimeInterval) -> (text: String, complete: Bool) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsbom")
        process.arguments = ["-s", "-f", bom]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return ("", false) }
        let timeoutWork = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        defer { timeoutWork.cancel(); try? pipe.fileHandleForReading.close() }
        let limit = 2 * 1024 * 1024
        var data = Data(), complete = true
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                if data.count + chunk.count > limit { complete = false; process.terminate(); break }
                data.append(chunk)
            }
        } catch { complete = false; if process.isRunning { process.terminate() } }
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return ("", false) }
        return (text, complete && process.terminationStatus == 0)
    }
}
