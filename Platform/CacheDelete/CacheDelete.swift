import Foundation

/// macOS's purgeable-space service (the private CacheDelete framework, what `deleted` uses when space runs low).
///
/// Each system daemon registers a CacheDelete service and reports what it can give back. mobileassetd reports the
/// MobileAsset bundles no subscription locks any more, including SIP-restricted families such as the Apple
/// Intelligence models, which nothing else can measure or delete. Purging only that service is Apple's own
/// garbage collection, run now instead of when the disk fills: on 26B5091g it removed 12.04 GB (245 unlocked assets,
/// including the 3B model) in 4.6 s, as a normal user (`results/ai-orphan-subscriptions-2026-09-30/`).
public enum CacheDeleteService {
    public static let mobileAsset = "com.apple.mobileassetd.cache-delete"
    /// Caches inside apps' sandbox containers (1.15 GB purgeable on 26B5091g); macOS purges them itself when space runs low.
    public static let appContainerCaches = "com.apple.cache_delete_app_container_caches"
    /// Files apps marked purgeable (APFS); 4.89 GB at urgency 3, 339 MB at urgency 1-2, on the development Mac (2026-10-02). Purging
    /// it at urgency 3 freed 4.66 GB, measured on the volume, as a normal user. Asked at `fsPurgeableDataUrgency`.
    public static let fsPurgeableData = "com.apple.fspurgeable_data"
    public static let fsPurgeableDataUrgency = 3
    /// The urgency macOS uses when the disk is critically full. On 2026-10-03, after a purge at urgency 3 had removed 111 MB, asking
    /// again at 3 removed nothing within a millisecond while the estimate still said 911.7 MB; removing then goes on at this urgency.
    public static let fsPurgeableDataForceUrgency = 4
    /// The only services MacSpace asks to purge.
    public static let purgeable: Set<String> = [mobileAsset, appContainerCaches, fsPurgeableData]
    /// Documents marked purgeable; 633 MB at urgency 3 on the development Mac.
    public static let fsPurgeableDocument = "com.apple.fspurgeable_document"
    /// The part of the Spotlight index macOS may drop and rebuild (0.76 GB on the development Mac, 2026-10-06).
    public static let spotlightIndex = "com.apple.metadata.mds.cachedelete"
    /// Quick Look thumbnails; 330 MB at urgency 3 on the development Mac.
    public static let quickLookThumbnails = "com.apple.quicklook.ThumbnailsAgent.CacheDelete"
    /// Services under measurement: purged only from the CLI with `--experiment`, never from the app, until a measured purge shows
    /// what they free and what they take away.
    public static let experimental: Set<String> = [fsPurgeableDocument, quickLookThumbnails]
}

/// Whether CacheDelete's functions exist on this system. MacSpace calls it on any macOS build that has them: the calls that could
/// crash on a changed private interface run in the CLI child process (`…InSubprocess`), so a crash ends that process and is reported
/// as an error, and a purge checks first that the service filter is honored (`CacheDeleteClient.purge`).
public enum CacheDeleteSupport: String, Codable, Sendable {
    case available
    /// The framework or a function is missing.
    case unavailable
}

/// A diagnostic run of both private calls without deleting anything (`MacSpaceCli purge-assets --self-test`):
/// - a read-only query of the Data volume;
/// - the same query restricted to mobileassetd, which must answer for that service only;
/// - a purge aimed at a volume that does not exist, which CacheDelete answers with "Bad volume" through the same
///   completion block a real purge uses.
/// It gates nothing: an empty answer only means that nothing was reported yet (a VM just after it started).
public struct CacheDeleteSelfTest: Codable, Equatable, Sendable {
    public let build: String?
    public let testedAt: Date
    public let queryAnswered: Bool
    public let serviceFilterHonored: Bool
    public let purgeAnswered: Bool
    public let detail: String

    public init(build: String?, testedAt: Date, queryAnswered: Bool, serviceFilterHonored: Bool, purgeAnswered: Bool, detail: String) {
        self.build = build
        self.testedAt = testedAt
        self.queryAnswered = queryAnswered
        self.serviceFilterHonored = serviceFilterHonored
        self.purgeAnswered = purgeAnswered
        self.detail = detail
    }

    public var passed: Bool { queryAnswered && serviceFilterHonored && purgeAnswered }
}

public struct CacheDeletePurgeResult: Codable, Equatable, Sendable {
    public let services: [String]
    /// Bytes the services report they removed.
    public let purgedBytes: UInt64?
    public let freeBytesBefore: UInt64?
    public let freeBytesAfter: UInt64?
    public let elapsedSeconds: Double?
    public let error: String?
    /// CacheDelete's whole answer, each value as text: what to look at when a purge removes nothing.
    public let answer: [String: String]?

    public init(services: [String], purgedBytes: UInt64?, freeBytesBefore: UInt64?, freeBytesAfter: UInt64?,
                elapsedSeconds: Double?, error: String?, answer: [String: String]? = nil) {
        self.services = services
        self.purgedBytes = purgedBytes
        self.freeBytesBefore = freeBytesBefore
        self.freeBytesAfter = freeBytesAfter
        self.elapsedSeconds = elapsedSeconds
        self.error = error
        self.answer = answer
    }

    /// Measured change in free space on the volume (what the user gets).
    public var freedBytes: UInt64? {
        guard let before = freeBytesBefore, let after = freeBytesAfter else { return nil }
        return after > before ? after - before : 0
    }
}

public struct CacheDeleteClient {
    public static let dataVolume = "/System/Volumes/Data"
    static let frameworkPath = "/System/Library/PrivateFrameworks/CacheDelete.framework/CacheDelete"
    static let querySymbol = "CacheDeleteCopyItemizedPurgeableSpaceWithInfo"
    static let purgeSymbol = "CacheDeletePurgeSpaceWithInfoSync"
    /// A volume that cannot exist; the self-test purge targets it so nothing is deleted.
    static let selfTestVolume = "/nonexistent-macspace-cachedelete-self-test"

    /// The OS build, reported by the self-test; injectable for tests.
    public let build: String?

    public init(build: String? = CacheDeleteClient.currentBuild()) {
        self.build = build
    }

    public static func currentBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    public var support: CacheDeleteSupport {
        Self.symbol(Self.querySymbol) != nil && Self.symbol(Self.purgeSymbol) != nil ? .available : .unavailable
    }

    /// Why a call is refused, or nil when it may proceed.
    public var refusal: String? {
        support == .available ? nil : "CacheDelete is not available on this system."
    }

    // MARK: Self-test

    /// Exercises both calls in this process without deleting anything, for diagnosis. Run it only in a disposable process
    /// (`MacSpaceCli purge-assets --self-test`): a changed signature crashes the caller.
    public func runSelfTest(now: Date = Date()) -> CacheDeleteSelfTest {
        guard support != .unavailable else {
            return CacheDeleteSelfTest(build: build, testedAt: now, queryAnswered: false, serviceFilterHonored: false, purgeAnswered: false,
                                       detail: "CacheDelete is not available.")
        }
        let query = Self.rawQuery(volume: Self.dataVolume, urgency: 1)
        let queryOK = query.map { $0["CACHE_DELETE_VOLUME"] != nil && !Self.parseItemized($0).isEmpty } ?? false
        let filtered = Self.rawQuery(volume: Self.dataVolume, urgency: 1, services: [CacheDeleteService.mobileAsset]).map(Self.parseItemized)
        let filterOK = filtered.map { Set($0.keys) == [CacheDeleteService.mobileAsset] } ?? false
        let purge = Self.rawPurge(["CACHE_DELETE_VOLUME": Self.selfTestVolume, "CACHE_DELETE_URGENCY": 1, "CACHE_DELETE_AMOUNT": Int64(1),
                                   "CACHE_DELETE_SERVICES": [CacheDeleteService.mobileAsset]], timeout: 30)
        let purgeOK = purge.answered && purge.result?["CACHE_DELETE_ERROR"] != nil
        let detail = "query: \(queryOK ? "\(Self.parseItemized(query ?? [:]).count) services" : "no valid answer"); "
            + "filtered query: \(filterOK ? "mobileassetd only" : "\(filtered?.count ?? 0) services (filter not honored)"); "
            + "purge probe: \(purge.answered ? (purge.result?["CACHE_DELETE_ERROR"].map { "\($0)" } ?? "answered without the expected error") : "no answer")"
        return CacheDeleteSelfTest(build: build, testedAt: now, queryAnswered: queryOK, serviceFilterHonored: filterOK, purgeAnswered: purgeOK, detail: detail)
    }

    /// Per-service purgeable bytes at `urgency` (1 = lowest, what a service gives up most readily; 4 = highest).
    /// Read-only. nil if the framework or a function is unavailable.
    public func purgeableByService(volume: String = dataVolume, urgency: Int = 1) -> [String: UInt64]? {
        guard refusal == nil else { return nil }
        return Self.rawQuery(volume: volume, urgency: urgency).map(Self.parseItemized)
    }

    /// The whole answer of the query, for research. Read-only; nil when refused.
    public func rawPurgeable(volume: String = dataVolume, urgency: Int = 1) -> [String: Any]? {
        guard refusal == nil else { return nil }
        return Self.rawQuery(volume: volume, urgency: urgency)
    }

    static func rawQuery(volume: String, urgency: Int, services: [String]? = nil) -> [String: Any]? {
        typealias Copy = @convention(c) (CFDictionary) -> Unmanaged<CFTypeRef>?
        guard let symbol = symbol(querySymbol) else { return nil }
        var info: [String: Any] = ["CACHE_DELETE_VOLUME": volume, "CACHE_DELETE_URGENCY_LIMIT": urgency]
        if let services { info["CACHE_DELETE_SERVICES"] = services }
        return unsafeBitCast(symbol, to: Copy.self)(info as CFDictionary)?.takeRetainedValue() as? [String: Any]
    }

    /// Signature from disassembly on 26B5091g: (CFDictionaryRef info, void (^callback)(CFDictionaryRef result)) -> token.
    static func rawPurge(_ info: [String: Any], timeout: TimeInterval) -> (answered: Bool, result: [String: Any]?) {
        typealias Callback = @convention(block) (CFDictionary?) -> Void
        typealias Purge = @convention(c) (CFDictionary, Callback) -> Unmanaged<CFTypeRef>?
        guard let symbol = symbol(purgeSymbol) else { return (false, nil) }
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        // An explicit block value is an escaping closure: some services (app container caches) keep the callback and answer after
        // the call returns, and a trailing closure would trap with "non-escaping closure has escaped" (seen on 26B5091g).
        let callback: Callback = { result in
            box.value = result as? [String: Any]
            done.signal()
        }
        _ = unsafeBitCast(symbol, to: Purge.self)(info as CFDictionary, callback)?.takeRetainedValue()
        let answered = done.wait(timeout: .now() + timeout) == .success
        return (answered, box.value)
    }

    /// Asks only `services` to purge up to `amount` bytes at `urgency`, waiting up to `timeout` seconds.
    public func purge(services: [String], volume: String = dataVolume, urgency: Int = 1, amount: UInt64 = 100_000_000_000,
                      timeout: TimeInterval = 600, freeSpace: () -> UInt64? = DataVolume.freeBytes) -> CacheDeletePurgeResult {
        let before = freeSpace()
        if let refusal {
            return CacheDeletePurgeResult(services: services, purgedBytes: nil, freeBytesBefore: before, freeBytesAfter: before,
                                          elapsedSeconds: nil, error: refusal)
        }
        // The purge clears every service when the filter is ignored. Before purging, the same filter is tried on a read-only query:
        // an answer naming other services stops the purge. (An empty answer names none and lets it go on.)
        if let answered = Self.rawQuery(volume: volume, urgency: urgency, services: services).map(Self.parseItemized),
           !Set(answered.keys).isSubset(of: Set(services)) {
            return CacheDeletePurgeResult(services: services, purgedBytes: nil, freeBytesBefore: before, freeBytesAfter: before, elapsedSeconds: nil,
                                          error: "CacheDelete ignored the service filter on this macOS (it answered for \(answered.count) services); nothing was purged.")
        }
        // QUERY_AFTER_PURGE: CacheDelete keeps an estimate of what it could purge, and answered it unchanged right after purging
        // (911.7 MB after removing 111 MB); its answer echoes this key as 0, so it is asked to measure again once done.
        let info: [String: Any] = ["CACHE_DELETE_VOLUME": volume, "CACHE_DELETE_URGENCY": urgency,
                                   "CACHE_DELETE_AMOUNT": Int64(clamping: amount), "CACHE_DELETE_SERVICES": services,
                                   "CACHE_DELETE_QUERY_AFTER_PURGE": true]
        let run = Self.rawPurge(info, timeout: timeout)
        let parsed = run.result.map(Self.parsePurgeResult)
        let serviceError = run.result?["CACHE_DELETE_ERROR"].map { "CacheDelete: \($0)" }
        // Read once the freed blocks are back with the volume: a reading right after the call could show nothing freed.
        let after = DataVolume.settledFreeBytes(read: freeSpace)
        return CacheDeletePurgeResult(services: services, purgedBytes: parsed?.purged, freeBytesBefore: before, freeBytesAfter: after,
                                      elapsedSeconds: parsed?.elapsed,
                                      error: !run.answered ? "CacheDelete did not answer within \(Int(timeout)) s." : (run.result == nil ? "CacheDelete returned no result." : serviceError),
                                      answer: run.result.map { $0.mapValues { String(describing: $0).prefix(300).description } })
    }

    // MARK: Crash isolation

    /// Runs the query in `executable` (the `macspace` CLI, e.g. embedded in the app bundle) so that an unexpected ABI
    /// change crashes that process, not the caller. nil on any failure.
    public static func purgeableInSubprocess(executable: URL) -> UInt64? {
        let output = runSubprocess(executable, ["purge-assets", "--json"])
        guard output.status == 0, let object = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any] else { return nil }
        return (object["purgeableBytes"] as? NSNumber)?.uint64Value
    }

    /// Per-service purgeable bytes, asked in `executable`. nil on any failure.
    public static func purgeableByServiceInSubprocess(executable: URL, urgency: Int = 1) -> [String: UInt64]? {
        let output = runSubprocess(executable, ["purge-assets", "--all-services", "--json", "--urgency", "\(urgency)"])
        guard output.status == 0, let object = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any] else { return nil }
        return object.compactMapValues { ($0 as? NSNumber)?.uint64Value }
    }

    /// Runs the purge of one service (mobileassetd by default) in `executable`; a crash is reported as an error result.
    public static func purgeInSubprocess(executable: URL, service: String = CacheDeleteService.mobileAsset,
                                         urgency: Int = 1, freeSpace: () -> UInt64? = DataVolume.freeBytes) -> CacheDeletePurgeResult {
        let before = freeSpace()
        let output = runSubprocess(executable, ["purge-assets", "--execute", "--json", "--service", service, "--urgency", "\(urgency)"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let result = decodeResult(output.data, decoder: decoder) { return result }
        // No answer to read, but the purge may still have run: what the volume gained is still the truth for the user.
        let after = DataVolume.settledFreeBytes(read: freeSpace)
        let gained = (before.flatMap { b in after.map { $0 > b ? $0 - b : 0 } }) ?? 0
        let reason = output.signal.map { "the purge process crashed (signal \($0)); CacheDelete's private interface may have changed" }
            ?? (gained > 0 ? nil : "macOS gave no answer to the purge and the volume gained no space")
        return CacheDeletePurgeResult(services: [service], purgedBytes: nil, freeBytesBefore: before, freeBytesAfter: after, elapsedSeconds: nil,
                                      error: reason.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." })
    }

    /// The result in the child's output. Only the JSON object is read: anything else the child printed around it (a framework's own
    /// logging) made the whole output unreadable.
    static func decodeResult(_ data: Data, decoder: JSONDecoder) -> CacheDeletePurgeResult? {
        if let result = try? decoder.decode(CacheDeletePurgeResult.self, from: data) { return result }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return try? decoder.decode(CacheDeletePurgeResult.self, from: Data(text[start...end].utf8))
    }

    static func runSubprocess(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 660) -> (status: Int32, signal: Int32?, data: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, nil, Data()) }
        let deadline = DispatchTime.now() + timeout
        let box = DataBox()
        let done = DispatchSemaphore(value: 0)
        let handle = output.fileHandleForReading
        DispatchQueue.global().async {
            box.value = handle.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut { process.terminate(); _ = done.wait(timeout: .now() + 5) }
        process.waitUntilExit()
        let signal = process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
        return (process.terminationStatus, signal, box.value)
    }

    private final class DataBox: @unchecked Sendable {
        var value = Data()
    }

    private final class ResultBox: @unchecked Sendable {
        var value: [String: Any]?
    }

    /// Opened once: `support` is read on every snapshot, and each read opened the framework again.
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = dlopen(frameworkPath, RTLD_NOW)

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }

    /// Service entries are the non-`CACHE_DELETE_*` keys with a number value.
    public static func parseItemized(_ result: [String: Any]) -> [String: UInt64] {
        var services: [String: UInt64] = [:]
        for (key, value) in result where !key.hasPrefix("CACHE_DELETE_") {
            if let number = value as? NSNumber { services[key] = number.uint64Value }
        }
        return services
    }

    /// A time that is not a finite number is dropped: JSON cannot hold it, and the child then wrote no result at all.
    public static func parsePurgeResult(_ result: [String: Any]) -> (purged: UInt64?, elapsed: Double?) {
        let elapsed = (result["CACHE_DELETE_ELAPSED_TIME"] as? NSNumber)?.doubleValue
        return ((result["CACHE_DELETE_AMOUNT"] as? NSNumber)?.uint64Value, elapsed.flatMap { $0.isFinite ? $0 : nil })
    }
}
