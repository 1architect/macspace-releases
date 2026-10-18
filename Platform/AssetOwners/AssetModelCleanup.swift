import Foundation
import AssetOwnerBridge

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
        public var error: String? { owners.error }
    }

    /// Unknown eligibility never authorizes owner mutation. Existing CacheDelete callers retain their established guard.
    public static func refusal(_ scope: Scope, available: Bool?, supported: Bool, virtualMachine: Bool,
                               settings: [ModelFeatureSettings.Feature: ModelFeatureSettings.Status], phone: PhoneFeatureFlags.Status) -> String? {
        guard supported, !virtualMachine else { return "Model controls are not verified on this macOS build." }
        guard available == false else { return SystemAssetGuard.heldMessage }
        switch scope {
        case .siri: guard settings[.siri]?.managedOff == true else { return "Siri is not managed off by MacSpace." }
        case .phone: guard settings[.phone]?.managedOff == true, phone.managedOff else { return "Phone changes have not been verified after restart." }
        case .spatialPhotos: guard settings[.spatialPhotos]?.managedOff == true else { return "Spatial Photos is not managed off by MacSpace." }
        case .released: break
        }
        return nil
    }
    public static func refusal(_ scope: Scope) -> String? {
        refusal(scope, available: SystemAssetGuard.reviewedAvailability, supported: PhoneFeatureFlags.supported.value,
                virtualMachine: Machine.isVirtualMachine,
                settings: Dictionary(uniqueKeysWithValues: ModelFeatureSettings.Feature.allCases.map { ($0,ModelFeatureSettings().status($0)) }),
                phone: PhoneFeatureFlags().status())
    }
    public static func hasSavedOwners(_ scope: Scope) -> Bool {
        FileManager.default.fileExists(atPath: journal(scope).path)
    }
    static func journal(_ scope: Scope) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacSpace/asset-owners/\(scope.rawValue).plist")
    }
    static func child(_ scope: Scope, mode: String) -> OwnerResult {
        guard let cli = ToolLocator.cli() else { return OwnerResult(pending: true,error: "MacSpace's model cleanup tool is unavailable.") }
        let run = CacheDeleteClient.runSubprocess(cli,["asset-owners",scope.rawValue,mode],timeout: 180)
        guard run.status == 0, run.signal == nil, let result = try? JSONDecoder().decode(OwnerResult.self,from:run.data) else {
            return OwnerResult(pending:true,error:"The model cleanup tool did not finish. Saved owner state will be reconciled before another request.")
        }
        return result
    }
    public static func releaseOwners(_ scope: Scope) -> OwnerResult {
        if let reason = refusal(scope) { return OwnerResult(pending:true,error:reason) }
        if scope == .spatialPhotos { return OwnerResult(details:["Spatial Photos releases its owners through its disabled preference."]) }
        return child(scope,mode:"release")
    }
    public static func restoreOwners(_ scope: Scope) -> OwnerResult {
        guard hasSavedOwners(scope) else { return OwnerResult() }
        guard PhoneFeatureFlags.supported.value else {
            // Restore feature preferences even after an OS update. Never replay a private archived request against an unreviewed ABI;
            // the enabled Apple features recreate their requests as needed.
            return OwnerResult(details: ["Feature settings can be restored; macOS will recreate model requests on this macOS version."])
        }
        return child(scope,mode:"restore")
    }
    /// The child repeats the control gates rather than trusting its caller. No private owner API runs in the UI process.
    public static func runInChild(scope: String, mode: String) -> Data {
        guard let scope = Scope(rawValue:scope), scope != .spatialPhotos, ["release","restore","inspect"].contains(mode) else {
            return try! JSONEncoder().encode(OwnerResult(error:"Unknown model cleanup command."))
        }
        if mode == "release", let reason = refusal(scope) { return try! JSONEncoder().encode(OwnerResult(pending:true,error:reason)) }
        return MSAssetOwners(scope.rawValue,mode)
    }
    public static func clean(_ scope: Scope, freedLater: @escaping @Sendable (UInt64) async -> Void = { _ in }) -> Result {
        clean([scope], freedLater: freedLater)[0]
    }
    static func clean(_ scopes: [Scope], freedLater: @escaping @Sendable (UInt64) async -> Void) -> [Result] {
        var results = scopes.map { Result(scope: $0, owners: releaseOwners($0)) }
        for index in results.indices where results[index].error == nil {
            if let reason = refusal(results[index].scope) { results[index].owners.error = reason; results[index].owners.pending = true }
            results[index].remainingAssets = inventory(results[index].scope)
        }
        guard let first = results.firstIndex(where: { $0.error == nil }) else { return results }
        // All features share one CacheDelete service. Withdraw their owners first, then reclaim once and count that gain once.
        let permittedScopes = results.filter { $0.error == nil }.map(\.scope)
        if !needsReclaim(results) { return results }
        let fresh = PurgeRun(service: CacheDeleteService.mobileAsset).estimate()
        guard fresh.map({ $0 > 0 }) == true else {
            for index in results.indices where results[index].error == nil {
                results[index].owners.pending = results[index].remainingAssets != 0 || results[index].owners.releasedOwners > 0
            }
            if !PurgeRetrier.shared.isRetrying(CacheDeleteService.mobileAsset) {
                PurgeRetrier.shared.schedule(service: CacheDeleteService.mobileAsset, urgency: 1, purge: {
                    let reason = permittedScopes.compactMap { refusal($0) }.first
                    let estimate = reason == nil ? PurgeRun(service: CacheDeleteService.mobileAsset).estimate() : nil
                    guard reason == nil, estimate.map({ $0 > 0 }) == true else {
                        return CacheDeletePurgeResult(services: [CacheDeleteService.mobileAsset], purgedBytes: nil,
                                                      freeBytesBefore: nil, freeBytesAfter: nil, elapsedSeconds: nil,
                                                      error: reason ?? "Waiting for a fresh positive model cleanup estimate.")
                    }
                    return PurgeRun.purgeOnce(service: CacheDeleteService.mobileAsset, urgency: 1)
                }) { freed in
                    if freed > 0 { PurgeHoldouts.shared.clear(CacheDeleteService.mobileAsset) }
                    await freedLater(freed)
                }
            }
            return results
        }
        let purge = PurgeRun(service: CacheDeleteService.mobileAsset, extraRefusal: {
            permittedScopes.compactMap { refusal($0) }.first
        }).run(freedLater: freedLater)
        results[first].freedBytes = purge.freed
        for index in results.indices where results[index].error == nil {
            results[index].owners.details += PurgeRun.details(purge)
            results[index].owners.pending = purge.removedNothing
            if let error = purge.error { results[index].owners.error = error; results[index].owners.pending = true }
            results[index].remainingAssets = inventory(results[index].scope)
        }
        return results
    }

    static func needsReclaim(_ results: [Result]) -> Bool {
        results.contains { $0.error == nil && $0.remainingAssets != 0 }
    }
    /// Target presence, without walking protected payload contents or interpreting the service-wide purge count as target bytes.
    static func inventory(_ scope: Scope, root: String = "/System/Library/AssetsV2", fileManager: FileManager = .default) -> Int? {
        let tokens: [String]
        switch scope {
        case .siri: tokens=["UAF_Siri_Understanding","UAF_Siri_UnderstandingASRHammer","UAF_Siri_TextToSpeech"]
        case .phone: tokens=["UAF_Speech_AutomaticSpeechRecognition","UAF_Siri_TextToSpeech"]
        case .spatialPhotos: tokens=["UAF_Photos_SpatialPhotosRelive"]
        case .released: tokens=["LinguisticData"]
        }
        guard let families=try? fileManager.contentsOfDirectory(atPath:root) else{return nil}
        var count=0
        for family in families where tokens.contains(where:family.contains) {
            let folder=(root as NSString).appendingPathComponent(family)
            guard let names=try? fileManager.contentsOfDirectory(atPath:folder) else{return nil}
            count += names.filter{$0.hasSuffix(".asset")}.count
            if names.contains("purpose_auto") {
                guard let assets=try? fileManager.contentsOfDirectory(atPath:(folder as NSString).appendingPathComponent("purpose_auto")) else{return nil}
                count += assets.filter{$0.hasSuffix(".asset")}.count
            }
        }
        return count
    }
}

/// Rechecks explicitly managed off controls while MacSpace is open. No launch agent or system-service suppression.
public actor ManagedModelCleanup {
    public static let shared = ManagedModelCleanup()
    private var task: Task<Void,Never>?
    private var changing = false
    private var lastAttempt = Date.distantPast
    public private(set) var waiting: Set<ModelFeatureSettings.Feature> = []
    public var isRunning: Bool { task != nil }
    public func beginChange() async -> Bool {
        guard !changing else { return false }
        changing=true
        if let task { await task.value }
        return true
    }
    public func endChange() { changing=false;lastAttempt = .distantPast }
    public func waitForCurrent() async { if let task { await task.value } }
    public func check(force: Bool = false, finished: @escaping @Sendable (AssetModelCleanup.Result) async -> Void) {
        guard !changing,task == nil,force || Date().timeIntervalSince(lastAttempt)>=300 else{return}
        let scopes = [AssetModelCleanup.Scope.siri,.phone,.spatialPhotos].filter{AssetModelCleanup.refusal($0)==nil}
        guard !scopes.isEmpty else{return}
        lastAttempt=Date()
        task=Task.detached(priority:.utility) {
            let results = AssetModelCleanup.clean(scopes, freedLater: { freed in
                    var later=AssetModelCleanup.Result(scope:scopes[0],owners:AssetModelCleanup.OwnerResult())
                    later.freedBytes=freed;await finished(later)
                })
            for result in results {
                await self.record(result)
                await finished(result)
            }
            await self.complete()
        }
    }
    private func record(_ result: AssetModelCleanup.Result) {
        guard let feature=ModelFeatureSettings.Feature(rawValue:result.scope.rawValue) else{return}
        if result.error != nil || result.owners.pending {waiting.insert(feature)} else {waiting.remove(feature)}
    }
    private func complete() {task=nil}
}
