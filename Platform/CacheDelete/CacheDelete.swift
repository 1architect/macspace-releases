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
    /// The only services MacSpace asks to purge.
    public static let purgeable: Set<String> = [mobileAsset, appContainerCaches, fsPurgeableData]
    /// Documents marked purgeable; 633 MB at urgency 3 on the development Mac.
    public static let fsPurgeableDocument = "com.apple.fspurgeable_document"
    /// Quick Look thumbnails; 330 MB at urgency 3 on the development Mac.
    public static let quickLookThumbnails = "com.apple.quicklook.ThumbnailsAgent.CacheDelete"
    /// Services under measurement: purged only from the CLI with `--experiment`, never from the app, until a measured purge shows
    /// what they free and what they take away.
    public static let experimental: Set<String> = [fsPurgeableDocument, quickLookThumbnails]
}

/// Whether MacSpace may call CacheDelete on this system. The purge uses a private function whose signature was taken
/// from disassembly; a wrong signature crashes the calling process (seen as SIGBUS while probing on 26B5091g).
public enum CacheDeleteSupport: String, Codable, Sendable {
    /// Signatures checked on this build (a passed self-test, or a build validated by hand).
    case validated
    /// The functions exist but this build was not checked yet; run `CacheDeleteClient.validate(executable:)`.
    case unverified
    /// The self-test failed or crashed on this build; CacheDelete stays off until the next macOS build.
    case failedSelfTest
    /// The framework or a function is missing.
    case unavailable
}

/// The result of exercising both private calls on one macOS build without deleting anything (checked on 26B5091g):
/// - a read-only query of the Data volume;
/// - the same query restricted to mobileassetd, which must answer for that service only. A build that ignored the
///   services filter would make a purge clear every service, so it fails the test;
/// - a purge aimed at a volume that does not exist, which CacheDelete answers with "Bad volume" through the same
///   completion block a real purge uses.
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

/// Self-test results per build, so each macOS build is tested once.
public struct CacheDeleteValidationStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static let standard = CacheDeleteValidationStore(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSpace/cachedelete-validation.json"))

    public func load() -> [String: CacheDeleteSelfTest] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: CacheDeleteSelfTest].self, from: data)) ?? [:]
    }

    public func record(for build: String?) -> CacheDeleteSelfTest? { build.flatMap { load()[$0] } }

    public func save(_ result: CacheDeleteSelfTest) {
        guard let build = result.build else { return }
        var all = load()
        all[build] = result
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(all).write(to: url, options: .atomic)
    }
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
    /// Builds checked by hand (disassembly plus a live query and purge). Other builds validate themselves with the self-test.
    public static let validatedBuilds: Set<String> = ["26B5091g"]
    /// A volume that cannot exist; the self-test purge targets it so nothing is deleted.
    static let selfTestVolume = "/nonexistent-macspace-cachedelete-self-test"

    /// The OS build this client gates on; injectable for tests.
    public let build: String?
    /// Allow calls on a build that has not been validated yet (never after a failed self-test).
    public let allowUnverified: Bool
    public let store: CacheDeleteValidationStore

    public init(build: String? = CacheDeleteClient.currentBuild(), allowUnverified: Bool = false,
                store: CacheDeleteValidationStore = .standard) {
        self.build = build
        self.allowUnverified = allowUnverified
        self.store = store
    }

    public static func currentBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    public var support: CacheDeleteSupport {
        guard Self.symbol(Self.querySymbol) != nil, Self.symbol(Self.purgeSymbol) != nil else { return .unavailable }
        if build.map(Self.validatedBuilds.contains) == true { return .validated }
        switch store.record(for: build)?.passed {
        case true?: return .validated
        case false?: return .failedSelfTest
        case nil: return .unverified
        }
    }

    /// Why a call is refused, or nil when it may proceed.
    public var refusal: String? {
        switch support {
        case .validated: return nil
        case .unavailable: return "CacheDelete is not available on this system."
        case .failedSelfTest:
            return "CacheDelete's self-test failed on build \(build ?? "unknown") (\(store.record(for: build)?.detail ?? "no detail")); it stays off until the next macOS update."
        case .unverified:
            return allowUnverified ? nil : "CacheDelete has not been validated on build \(build ?? "unknown") yet; run the self-test (CacheDeleteClient.validate(executable:))."
        }
    }

    // MARK: Self-test

    /// Exercises both calls in this process without deleting anything. Run it only in a disposable process
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

    /// Runs the self-test in `executable` (the `MacSpaceCli` tool) and records the result for this build.
    /// A crash is recorded as a failure, which keeps CacheDelete off until the next build.
    @discardableResult
    public func validate(executable: URL, now: Date = Date()) -> CacheDeleteSelfTest {
        let output = Self.runSubprocess(executable, ["purge-assets", "--self-test", "--json"], timeout: 90)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result = (try? decoder.decode(CacheDeleteSelfTest.self, from: output.data))
            ?? CacheDeleteSelfTest(build: build, testedAt: now, queryAnswered: false, serviceFilterHonored: false, purgeAnswered: false,
                                   detail: output.signal.map { "self-test process crashed (signal \($0))" } ?? "self-test process exited with status \(output.status)")
        if result.build != build {
            result = CacheDeleteSelfTest(build: build, testedAt: result.testedAt, queryAnswered: false, serviceFilterHonored: false, purgeAnswered: false,
                                         detail: "self-test ran on build \(result.build ?? "unknown"), expected \(build ?? "unknown")")
        }
        store.save(result)
        return result
    }

    /// Validates on first use of a build; returns the support afterwards.
    @discardableResult
    public func ensureValidated(executable: URL) -> CacheDeleteSupport {
        if support == .unverified { validate(executable: executable) }
        return support
    }

    /// Per-service purgeable bytes at `urgency` (1 = lowest, what a service gives up most readily; 4 = highest).
    /// Read-only. nil if the framework or symbol is unavailable, or the build is not validated and `allowUnverified` is off.
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
        let info: [String: Any] = ["CACHE_DELETE_VOLUME": volume, "CACHE_DELETE_URGENCY": urgency,
                                   "CACHE_DELETE_AMOUNT": Int64(clamping: amount), "CACHE_DELETE_SERVICES": services]
        let run = Self.rawPurge(info, timeout: timeout)
        let parsed = run.result.map(Self.parsePurgeResult)
        let serviceError = run.result?["CACHE_DELETE_ERROR"].map { "CacheDelete: \($0)" }
        return CacheDeletePurgeResult(services: services, purgedBytes: parsed?.purged, freeBytesBefore: before, freeBytesAfter: freeSpace(),
                                      elapsedSeconds: parsed?.elapsed,
                                      error: !run.answered ? "CacheDelete did not answer within \(Int(timeout)) s." : (run.result == nil ? "CacheDelete returned no result." : serviceError),
                                      answer: run.result.map { $0.mapValues { String(describing: $0).prefix(300).description } })
    }

    // MARK: Crash isolation

    /// Runs the query in `executable` (the `macspace` CLI, e.g. embedded in the app bundle) so that an unexpected ABI
    /// change crashes that process, not the caller. nil on any failure.
    public static func purgeableInSubprocess(executable: URL, allowUnverified: Bool = false) -> UInt64? {
        let output = runSubprocess(executable, ["purge-assets", "--json"] + (allowUnverified ? ["--allow-unverified"] : []))
        guard output.status == 0, let object = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any] else { return nil }
        return (object["purgeableBytes"] as? NSNumber)?.uint64Value
    }

    /// Per-service purgeable bytes, asked in `executable`. nil on any failure.
    public static func purgeableByServiceInSubprocess(executable: URL, allowUnverified: Bool = false, urgency: Int = 1) -> [String: UInt64]? {
        let output = runSubprocess(executable, ["purge-assets", "--all-services", "--json", "--urgency", "\(urgency)"] + (allowUnverified ? ["--allow-unverified"] : []))
        guard output.status == 0, let object = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any] else { return nil }
        return object.compactMapValues { ($0 as? NSNumber)?.uint64Value }
    }

    /// Runs the purge of one service (mobileassetd by default) in `executable`; a crash is reported as an error result.
    public static func purgeInSubprocess(executable: URL, allowUnverified: Bool = false, service: String = CacheDeleteService.mobileAsset,
                                         urgency: Int = 1, freeSpace: () -> UInt64? = DataVolume.freeBytes) -> CacheDeletePurgeResult {
        let before = freeSpace()
        let output = runSubprocess(executable, ["purge-assets", "--execute", "--json", "--service", service, "--urgency", "\(urgency)"]
                                   + (allowUnverified ? ["--allow-unverified"] : []))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let result = try? decoder.decode(CacheDeletePurgeResult.self, from: output.data) { return result }
        let reason = output.signal.map { "the purge process crashed (signal \($0)); CacheDelete's private interface may have changed" }
            ?? "the purge process exited with status \(output.status) and no result"
        return CacheDeletePurgeResult(services: [service], purgedBytes: nil, freeBytesBefore: before,
                                      freeBytesAfter: freeSpace(), elapsedSeconds: nil, error: reason.prefix(1).uppercased() + reason.dropFirst() + ".")
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

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else { return nil }
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

    public static func parsePurgeResult(_ result: [String: Any]) -> (purged: UInt64?, elapsed: Double?) {
        ((result["CACHE_DELETE_AMOUNT"] as? NSNumber)?.uint64Value, (result["CACHE_DELETE_ELAPSED_TIME"] as? NSNumber)?.doubleValue)
    }
}
