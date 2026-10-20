import Foundation

/// Shared owner withdrawal and physical reclaim. The UI never receives private objects or arbitrary mutation parameters.
public enum AssetModelCleanup {
    public enum Scope: String, CaseIterable, Sendable { case siri, phone, spatialPhotos, released }
    public struct OwnerResult: Codable, Sendable {
        public var releasedOwners: Int
        public var details: [String]
        public var pending: Bool
        public var error: String?
        public init(releasedOwners: Int = 0, details: [String] = [], pending: Bool = false, error: String? = nil) {
            self.releasedOwners = releasedOwners; self.details = details; self.pending = pending; self.error = error
        }
    }
    public struct Result: Sendable {
        public var scope: Scope
        public var owners: OwnerResult
        public var freedBytes: UInt64 = 0
        public var remainingAssets: Int?
        /// The purge was held back on purpose (MobileAsset downloading, `SystemAssetGuard.refusal`): nothing was tried, so this run says
        /// nothing about whether macOS keeps the models.
        public var held = false
        public var error: String? { owners.error }
    }

    /// Unknown eligibility never authorizes owner mutation. A feature's owners go whether Apple Intelligence is on or off: they are the
    /// feature's own, and Apple Intelligence keeps its models through its own owners. The language data (`released`) goes only while
    /// it is off, since Apple Intelligence reads it. The purge that follows has its own gate (`SystemAssetGuard.refusal`).
    public static func refusal(_ scope: Scope, available: Bool?, supported: Bool, virtualMachine: Bool,
                               settings: [ModelFeatureSettings.Feature: ModelFeatureSettings.Status], phone: PhoneFeatureFlags.Status) -> String? {
        guard supported, !virtualMachine else { return "Model controls are not verified on this macOS build." }
        guard let available else { return "MacSpace could not read whether Apple Intelligence is on." }
        if scope == .released, available { return SystemAssetGuard.heldMessage }
        switch scope {
        case .siri: guard settings[.siri]?.managedOff == true else { return "Siri is not managed off by MacSpace." }
        case .phone: guard settings[.phone]?.managedOff == true, phone.managedOff else { return "Phone changes have not been verified after restart." }
        case .spatialPhotos: guard settings[.spatialPhotos]?.managedOff == true else { return "Spatial Photos is not managed off by MacSpace." }
        case .released: break
        }
        return nil
    }
    public static func refusal(_ scope: Scope) -> String? {
        let features = ModelFeatureSettings()
        return refusal(scope, available: SystemAssetGuard.reviewedAvailability, supported: PhoneFeatureFlags.supported.value,
                       virtualMachine: Machine.isVirtualMachine,
                       settings: Dictionary(uniqueKeysWithValues: ModelFeatureSettings.Feature.allCases.map { ($0, features.status($0)) }),
                       phone: PhoneFeatureFlags().status())
    }
    public static func hasSavedOwners(_ scope: Scope) -> Bool { FileManager.default.fileExists(atPath: journal(scope).path) }
    /// MacSpace's withdrawal of the scope's owners is in effect: its journal has owners removed and not given back. The feature's
    /// shared families (speech recognition, voices) count while it is, not only in the run that withdrew them (`families`): counted
    /// only then, every recheck after the first found nothing to delete, said it was freeing, and never purged again (2026-10-19).
    static func hasWithdrawnOwners(_ scope: Scope) -> Bool {
        guard let data = try? Data(contentsOf: journal(scope)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entries = plist["entries"] as? [[String: Any]] else { return false }
        return entries.contains { $0["phase"] as? String == "removed" }
    }
    /// A feature with less than this left on disk, as its switch measures it (`modelBytes`), is done: the switch shows no size, and
    /// what is left (catalogs, the models Dictation keeps in the shared families) is not purged for again and again.
    public static let doneBelow: UInt64 = 50_000_000

    /// The model assets left for `scope` to delete; 0 once its feature is under `doneBelow`.
    static func remaining(_ scope: Scope, releasedNow: Bool) -> Int? {
        if let feature = ModelFeatureSettings.Feature(rawValue: scope.rawValue), let bytes = modelBytes(feature).bytes, bytes < doneBelow { return 0 }
        return inventory(scope, withdrew: releasedNow || hasWithdrawnOwners(scope))
    }
    static func journal(_ scope: Scope) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacSpace/asset-owners/\(scope.rawValue).plist")
    }
    static func child(_ scope: Scope, mode: String) -> OwnerResult {
        guard let cli = ToolLocator.cli() else { return OwnerResult(pending: true, error: "MacSpace's model cleanup tool is unavailable.") }
        let run = CacheDeleteClient.runSubprocess(cli, ["asset-owners", scope.rawValue, mode], timeout: 180)
        guard run.status == 0, run.signal == nil, let result = try? JSONDecoder().decode(OwnerResult.self, from: run.data) else {
            return OwnerResult(pending: true, error: "The model cleanup tool did not finish. Saved owner state will be reconciled before another request.")
        }
        return result
    }
    public static func releaseOwners(_ scope: Scope) -> OwnerResult {
        if let reason = refusal(scope) { return OwnerResult(pending: true, error: reason) }
        if scope == .spatialPhotos { return OwnerResult(details: ["Spatial Photos releases its owners through its disabled preference."]) }
        return child(scope, mode: "release")
    }
    public static func restoreOwners(_ scope: Scope) -> OwnerResult {
        guard hasSavedOwners(scope) else { return OwnerResult() }
        guard PhoneFeatureFlags.supported.value else {
            // Restore feature preferences even after an OS update. Never replay a private archived request against an unreviewed ABI;
            // the enabled Apple features recreate their requests as needed.
            return OwnerResult(details: ["Feature settings can be restored; macOS will recreate model requests on this macOS version."])
        }
        return child(scope, mode: "restore")
    }
    /// The child repeats the control gates rather than trusting its caller. No private owner API runs in the UI process.
    public static func runInChild(scope: String, mode: String) -> Data {
        guard let scope = Scope(rawValue: scope), scope != .spatialPhotos, ["release", "restore", "inspect"].contains(mode) else {
            return try! JSONEncoder().encode(OwnerResult(error: "Unknown model cleanup command."))
        }
        if mode == "release", let reason = refusal(scope) { return try! JSONEncoder().encode(OwnerResult(pending: true, error: reason)) }
        return AssetOwners.run(scope: scope.rawValue, mode: mode)
    }
    public static func clean(_ scope: Scope, freedLater: @escaping @Sendable (UInt64) async -> Void = { _ in }) -> Result {
        clean([scope], freedLater: freedLater)[0]
    }
    /// All features share one CacheDelete service: their owners are withdrawn first, then one reclaim runs and its gain counts once.
    static func clean(_ scopes: [Scope], freedLater: @escaping @Sendable (UInt64) async -> Void) -> [Result] {
        var results = scopes.map { Result(scope: $0, owners: releaseOwners($0)) }
        for index in results.indices where results[index].error == nil {
            if let reason = refusal(results[index].scope) { results[index].owners.error = reason; results[index].owners.pending = true }
            results[index].remainingAssets = remaining(results[index].scope, releasedNow: results[index].owners.releasedOwners > 0)
        }
        guard let first = results.firstIndex(where: { $0.error == nil }), needsReclaim(results) else { return results }
        let permitted = results.filter { $0.error == nil }.map(\.scope)
        let service = CacheDeleteService.mobileAsset
        let refusal: @Sendable () -> String? = { permitted.compactMap { Self.refusal($0) }.first }
        // No estimate is asked first, as for the page's Free (`PurgeRun.run`): it lags behind what macOS can delete. Gated on it,
        // the switch's cleanup never purged while the estimate read 0, kept waiting, and asked for a restart, when the Free button's
        // purge then removed all 371 MB of Call transcription's models with none (2026-10-19). If macOS keeps everything, `run`
        // asks again in the background.
        let purge = PurgeRun(service: service, extraRefusal: refusal, featureCleanup: true).run(freedLater: freedLater)
        results[first].freedBytes = purge.freed
        for index in results.indices where results[index].error == nil {
            results[index].owners.details += PurgeRun.details(purge)
            // Held: Apple Intelligence is on and MobileAsset is downloading; the next recheck tries again.
            if let error = purge.error { results[index].owners.error = error; results[index].owners.pending = true }
            results[index].held = purge.held
            results[index].remainingAssets = remaining(results[index].scope, releasedNow: results[index].owners.releasedOwners > 0)
            // The purge's gain is service-wide: the feature waits until its own models are gone, not until anything was freed.
            results[index].owners.pending = results[index].owners.pending || purge.removedNothing || purge.held
                || results[index].remainingAssets != 0
        }
        return results
    }

    static func needsReclaim(_ results: [Result]) -> Bool { results.contains { $0.error == nil && $0.remainingAssets != 0 } }

    /// The model families a scope's cleanup looks at. Speech recognition and voices are shared with Dictation, VoiceOver and other
    /// voices, so they count only in a run that `withdrew` one of the feature's owners: counted on every five-minute recheck, the
    /// models other features keep there had the Phone cleanup purging and retrying in the background without end (2026-10-18).
    static func families(_ scope: Scope, withdrew: Bool) -> [String] {
        let shared = ["UAF_Speech_AutomaticSpeechRecognition", "UAF_Siri_TextToSpeech"]
        switch scope {
        case .siri: return ["UAF_Siri_Understanding"] + (withdrew ? shared.suffix(1) : [])
        case .phone: return withdrew ? shared : []
        case .spatialPhotos: return ["UAF_Photos_SpatialPhotosRelive"]
        case .released: return ["LinguisticData"]
        }
    }

    /// The folders in AssetsV2 a feature's models are in, as its switch shows them: Siri's understanding models and voices, the Photos
    /// spatial models, and speech recognition for the Phone features. No folder is in two features, so their sizes add up.
    static func shownFamilies(_ feature: ModelFeatureSettings.Feature) -> [String] {
        switch feature {
        case .siri: return ["UAF_Siri_Understanding", "UAF_Siri_TextToSpeech"]
        case .spatialPhotos: return ["UAF_Photos_SpatialPhotosRelive"]
        case .phone: return ["UAF_Speech_AutomaticSpeechRecognition"]
        }
    }

    /// What a feature's models take on disk now, and whether MobileAsset is downloading one of them (a folder of that family in its
    /// staging folder, `SystemAssetGuard.stagingFolder`). `bytes` is nil when AssetsV2 cannot be read (no Full Disk Access).
    public static func modelBytes(_ feature: ModelFeatureSettings.Feature, root: String = "/System/Library/AssetsV2",
                                  fileManager: FileManager = .default) -> (bytes: UInt64?, downloading: Bool) {
        let tokens = shownFamilies(feature)
        let staged = ((try? fileManager.contentsOfDirectory(atPath: (root as NSString).appendingPathComponent("staging"))) ?? [])
            .contains { name in !name.hasSuffix(".xml") && tokens.contains(where: name.contains) }
        guard let families = try? fileManager.contentsOfDirectory(atPath: root) else { return (nil, staged) }
        let sizer = FileTreeSizer()
        let bytes = families.filter { family in tokens.contains(where: family.contains) }
            .compactMap { sizer.size(at: URL(fileURLWithPath: (root as NSString).appendingPathComponent($0))) }
            .map { $0.allocatedBytesEstimate ?? $0.logicalBytes }.reduce(0, +)
        return (bytes, staged)
    }

    /// How many of a feature's assets a process still holds a lock on (`ModelDescriptors.lockDirectory`). A purge leaves those, and the
    /// lock goes only when its process stops or the Mac restarts: on 26B5112a (2026-10-19) every Siri owner was withdrawn and the set
    /// asked for nothing, yet Siri's services, which macOS keeps running with Siri off, still held 1.4 GB of its English models.
    public static func lockedAssets(_ feature: ModelFeatureSettings.Feature, lockDirectory: String = ModelDescriptors.lockDirectory,
                                    fileManager: FileManager = .default) -> Int {
        let prefixes = shownFamilies(feature).map { "AutoAssetLocker_Entry_com.apple.MobileAsset." + $0.replacingOccurrences(of: "_", with: ".") + "_" }
        return ((try? fileManager.contentsOfDirectory(atPath: lockDirectory)) ?? []).filter { name in prefixes.contains(where: name.hasPrefix) }.count
    }

    /// Assets smaller than this are the set's own catalog records (`….uaf.metadata`, 8 KB), which macOS keeps with no owner: counted,
    /// they kept Siri's cleanup waiting, and purging every five minutes, after its models were gone (2026-10-19).
    static let modelAssetBytes: UInt64 = 1_000_000

    /// Target presence, without reading protected payload contents or interpreting the service-wide purge count as target bytes: the
    /// model assets (`modelAssetBytes`) left in the scope's families. nil is unreadable, never zero.
    static func inventory(_ scope: Scope, withdrew: Bool = true, root: String = "/System/Library/AssetsV2",
                          fileManager: FileManager = .default) -> Int? {
        let tokens = families(scope, withdrew: withdrew)
        guard !tokens.isEmpty else { return 0 }
        let sizer = FileTreeSizer()
        func assets(_ folder: String) -> Int? {
            (try? fileManager.contentsOfDirectory(atPath: folder)).map { names in
                names.filter { name in
                    guard name.hasSuffix(".asset") else { return false }
                    let size = sizer.size(at: URL(fileURLWithPath: (folder as NSString).appendingPathComponent(name)))
                    return size.map { ($0.allocatedBytesEstimate ?? $0.logicalBytes) >= modelAssetBytes } ?? true
                }.count
            }
        }
        guard let families = try? fileManager.contentsOfDirectory(atPath: root) else { return nil }
        var count = 0
        for family in families where tokens.contains(where: family.contains) {
            let folder = (root as NSString).appendingPathComponent(family)
            guard let direct = assets(folder) else { return nil }
            count += direct
            let auto = (folder as NSString).appendingPathComponent("purpose_auto")
            if fileManager.fileExists(atPath: auto) {
                guard let nested = assets(auto) else { return nil }
                count += nested
            }
        }
        return count
    }
}

/// Rechecks explicitly managed off controls while MacSpace is open. No launch agent or system-service suppression.
public actor ManagedModelCleanup {
    public static let shared = ManagedModelCleanup()
    private var task: Task<Void, Never>?
    private var changing = false
    private var lastAttempt = Date.distantPast
    private var visible = false
    public private(set) var waiting: Set<ModelFeatureSettings.Feature> = []
    /// Features whose cleanup kept waiting while none of their models went for `stallTime`: macOS holds them, and only a restart
    /// lets them go. Siri sat on Waiting for macOS with 498 MB left, recheck after recheck, and never asked for the restart that freed
    /// it (2026-10-19, issue 32). A lock alone never makes one: macOS's services usually let go within minutes.
    public private(set) var stalled: Set<ModelFeatureSettings.Feature> = []
    /// Features whose models stayed through `stallTime` of real deletions with no lock held: macOS keeps them, a restart would not
    /// change it, and MacSpace stops purging for them until the switch changes or the user asks again (`retryKept`). Purged on and
    /// on, the shared speech models Dictation keeps had the Phone cleanup purging without end (2026-10-18).
    public private(set) var kept: Set<ModelFeatureSettings.Feature> = []
    /// Features that have just started asking for a restart, for the module to notify about once (`takeRestartsAsked`).
    private var restartsAsked: Set<ModelFeatureSettings.Feature> = []
    /// Per waiting feature: the model assets it had left after the last cleanup, and since when cleanups have freed none of them.
    private var stalls: [ModelFeatureSettings.Feature: (remaining: Int?, since: Date)] = [:]
    /// Ten minutes of rechecks with nothing going: the cleanup the switch started and the five-minute rechecks after it, with a
    /// little room for a recheck that comes a few seconds early.
    static let stallTime: TimeInterval = 10 * 60 - 30
    /// When MacSpace first asked for a restart for a stalled feature: the Mac's boot time then, kept across the restart.
    static func restartAskedKey(_ feature: ModelFeatureSettings.Feature) -> String { "MacSpace.modelCleanup.restartAsked." + feature.rawValue }

    /// When the Mac last started, in seconds since 1970; 0 when it cannot be read.
    static func bootTime() -> TimeInterval {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return 0 }
        return TimeInterval(time.tv_sec)
    }
    public var isRunning: Bool { task != nil }
    /// A cleanup the user started by switching a feature off. The five-minute rechecks run quietly: shown, they made the switches
    /// say Freeing space every few minutes while nothing was being freed.
    public var isFreeingVisibly: Bool { task != nil && visible }

    /// An explicit feature change waits for a running cleanup and blocks new ones until `endChange`.
    public func beginChange() async -> Bool {
        guard !changing else { return false }
        changing = true
        if let task { await task.value }
        return true
    }
    public func endChange() { changing = false; lastAttempt = .distantPast }
    public func waitForCurrent() async { if let task { await task.value } }
    public func check(force: Bool = false, finished: @escaping @Sendable (AssetModelCleanup.Result) async -> Void) {
        let interval = heldBack || !waiting.isEmpty ? Self.heldRecheck : 300
        guard !changing, task == nil, force || Date().timeIntervalSince(lastAttempt) >= interval else { return }
        let permitted = [AssetModelCleanup.Scope.siri, .phone, .spatialPhotos].filter { AssetModelCleanup.refusal($0) == nil }
        // A feature switched back on is no longer waiting for its models to go: left in, it asked for a restart while on (2026-10-19).
        let managed = Set(permitted.compactMap { ModelFeatureSettings.Feature(rawValue: $0.rawValue) })
        waiting.formIntersection(managed)
        stalled.formIntersection(managed)
        kept.formIntersection(managed)
        stalls = stalls.filter { managed.contains($0.key) }
        let scopes = permitted.filter { scope in ModelFeatureSettings.Feature(rawValue: scope.rawValue).map { !kept.contains($0) } ?? true }
        guard !scopes.isEmpty else { return }
        lastAttempt = Date()
        visible = force
        // Switched off just now: waiting from this moment, so the switch says Freeing space and the page follows it at once, not
        // after the first run's end (`record` clears the ones with nothing left).
        if force { waiting.formUnion(scopes.compactMap { ModelFeatureSettings.Feature(rawValue: $0.rawValue) }) }
        task = Task.detached(priority: .utility) {
            let results = AssetModelCleanup.clean(scopes, freedLater: { freed in
                var later = AssetModelCleanup.Result(scope: scopes[0], owners: AssetModelCleanup.OwnerResult())
                later.freedBytes = freed
                await finished(later)
            })
            for result in results {
                await self.record(result)
                await finished(result)
            }
            await self.complete()
        }
    }
    /// The last cleanup's purge was held back while macOS downloaded, or a feature is still waiting for its models to go: the next
    /// one comes after 30 seconds, not five minutes. macOS lets go of a feature's models on its own time (Spatial Photos within
    /// five minutes of its switch, Research.md), and each purge before that frees nothing: rechecked every five minutes, the
    /// models stayed until the user pressed Free, which then freed nothing either (2026-10-19).
    private var heldBack = false
    static let heldRecheck: TimeInterval = 30

    private func record(_ result: AssetModelCleanup.Result) {
        heldBack = result.held
        guard let feature = ModelFeatureSettings.Feature(rawValue: result.scope.rawValue) else { return }
        if result.error != nil || result.owners.pending { waiting.insert(feature) } else { waiting.remove(feature) }
        stall(feature, result)
    }

    /// Times how long cleanups have left all of a feature's models in place (`stalled`). One held back on purpose (an error:
    /// Apple Intelligence downloading, a gate closed) neither counts nor starts the count again: a restart would not change it.
    private func stall(_ feature: ModelFeatureSettings.Feature, _ result: AssetModelCleanup.Result) {
        guard result.owners.pending || result.error != nil else {
            stalls[feature] = nil
            stalled.remove(feature)
            UserDefaults.standard.removeObject(forKey: Self.restartAskedKey(feature))
            return
        }
        guard result.error == nil else { return }
        // Held back while macOS downloads: a restart would not change that, so the stall starts again once the download is over.
        // Counted, ten minutes of downloading asked for a restart (2026-10-19).
        guard !result.held else { stalls[feature] = nil; stalled.remove(feature); return }
        let now = Date()
        let last = stalls[feature]
        let fewer = last.flatMap { last in last.remaining.flatMap { before in result.remainingAssets.map { $0 < before } } } ?? false
        let since = fewer ? now : last?.since ?? now
        stalls[feature] = (result.remainingAssets, since)
        guard now.timeIntervalSince(since) >= Self.stallTime else { stalled.remove(feature); return }
        // No lock held: deletion after deletion freed nothing, and a restart would not change that. The switch says Kept by macOS
        // and MacSpace stops asking. Asked for regardless, the restart ran while macOS was simply slow or kept the models for
        // Dictation, and the user restarted for nothing (2026-10-19).
        guard AssetModelCleanup.lockedAssets(feature) > 0 else {
            stalls[feature] = nil
            stalled.remove(feature)
            waiting.remove(feature)
            kept.insert(feature)
            return
        }
        // A restart is asked for once. Models still there after it are kept by macOS for its own reasons, and asking again would
        // only send the user round in circles: Siri's last speech model, which MobileAsset keeps until it has the next one, stayed
        // through the restart MacSpace asked for (2026-10-19, issue 32). The switch then says so (Kept by macOS) instead of
        // waiting, and the rechecks go on quietly.
        let key = Self.restartAskedKey(feature), boot = Self.bootTime()
        let asked = UserDefaults.standard.double(forKey: key)
        if asked == 0 { UserDefaults.standard.set(boot, forKey: key); restartsAsked.insert(feature) }
        if asked > 0, boot > asked + 1 {
            stalled.remove(feature)
            waiting.remove(feature)
        } else {
            stalled.insert(feature)
        }
    }
    private func complete() { task = nil }

    /// The user asked to free the models now (the page's Free): features given up on are tried again, at once.
    public func retryKept() {
        kept = []
        stalls = [:]
        lastAttempt = .distantPast
    }

    /// The features that started asking for a restart since the last call, each once: the module notifies the user about them.
    public func takeRestartsAsked() -> Set<ModelFeatureSettings.Feature> {
        defer { restartsAsked = [] }
        return restartsAsked
    }
}
