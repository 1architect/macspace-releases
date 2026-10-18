import Foundation
import MacSpacePlatform
import MacSpaceSiriPrivileged
import MacSpaceSdk

/// What the Siri & Apple Intelligence screens are built from.
struct SiriSnapshot: Sendable {
    var status: AppleIntelligenceGuardStatus
    /// The plan for switching Apple Intelligence off, or why none can be made.
    var disablePlan: Result<SiriLanguageChangePlan, SiriPlanFailure>
    /// nil when the subscription database cannot be read.
    var accounts: AppleIntelligenceAccountsReport?
    var purgeableAssetsBytes: UInt64?
    var releaseBlockers: [String]
    var watch: AppleIntelligenceWatchRecord?
    var cliPath: String
    var takenAt: Date
    /// Running inside a virtual machine, where Apple Intelligence does not exist.
    var isVirtualMachine = false
    /// MacSpace is releasing leftover models by itself right now (`ModelAutoReleaser`).
    var releasingAutomatically = false
    /// What the Apple Intelligence models take on disk now (the 3B base model and its adapters), from MobileAsset's records; nil if
    /// they cannot be read. System Settings shows more (19.89 GB against 11.35 GB on 26B5091g, 2026-10-06), from folders no app can
    /// open, even with Full Disk Access; releasing the models gained 9.48 GB on the volume (2026-10-05), in line with the records.
    var installedModelBytes: UInt64?
    /// The same figure, kept apart for what a purge works from.
    var recordedModelBytes: UInt64?
    /// What macOS is downloading for those models right now (its staging folder).
    var downloadingModelBytes: UInt64 = 0
    /// macOS kept the unused assets when asked; MacSpace is asking it again in the background (`PurgeRetrier`).
    var assetsRetrying = false
    /// MacSpace is deleting released models in the background right now (`ModelPurger`).
    var purgingModels = false
    /// The part of the installed models macOS still holds a lock on (`ModelDescriptors.Usage.lockedBytes`).
    var lockedModelBytes: UInt64 = 0
    /// Siri's iCloud sync is on (`SiriCloudSync.isEnabled`); nil when it cannot be read.
    var cloudSyncEnabled: Bool?
    /// The system-wide Phone gates, distinct from Apple Intelligence's language switch.
    var phoneFeatures: PhoneFeatureFlags.Status?
    var featureSettings: [ModelFeatureSettings.Feature: ModelFeatureSettings.Status] = [:]
    var cleaningFeatures = false
    var featureCleanupWaiting: Set<ModelFeatureSettings.Feature> = []
}

struct SiriPlanFailure: Error, Sendable, Equatable {
    var message: String
}

actor SiriStore {
    typealias Builder = @Sendable (LoadProgressRelay) -> SiriSnapshot

    private let reading: SharedReading<SiriSnapshot>

    init(builder: @escaping Builder = SiriStore.liveSnapshot) {
        reading = SharedReading { builder($0) }
    }

    func snapshot(maxAge: TimeInterval = 4, now: Date = Date(), progress: LoadProgressSink? = nil) async -> SiriSnapshot {
        await reading.value(maxAge: maxAge, now: now, progress: progress)
    }

    /// The assets and models again, after a purge: the rest of the reading stays.
    func reconcileAssets() async -> SiriSnapshot? {
        await reading.reconcile { cached in
            var updated = cached
            let raw = PurgeRun(service: CacheDeleteService.mobileAsset).estimate()
            updated.purgeableAssetsBytes = SystemAssetGuard.holdsAssets ? nil : raw.map { PurgeHoldouts.shared.freeable(CacheDeleteService.mobileAsset, estimate: $0) }
            let models = SiriStore.modelBytes()
            updated.recordedModelBytes = models.installed
            updated.installedModelBytes = models.installed
            updated.downloadingModelBytes = models.downloading
            updated.lockedModelBytes = models.locked
            updated.assetsRetrying = PurgeRetrier.shared.isRetrying(CacheDeleteService.mobileAsset)
            return updated
        }
    }

    /// The feature switches again, after one changed: the rest of the reading stays.
    func reconcilePhoneFeatures(read: @escaping @Sendable () -> PhoneFeatureFlags.Status = { PhoneFeatureFlags().status() }) async -> SiriSnapshot? {
        await reading.reconcile { cached in
            var updated = cached
            updated.phoneFeatures = read()
            updated.featureSettings = Dictionary(uniqueKeysWithValues: ModelFeatureSettings.Feature.allCases.map { ($0, ModelFeatureSettings().status($0)) })
            return updated
        }
    }

    func invalidate() async { await reading.invalidate() }

    static func liveSnapshot(progress: LoadProgressRelay) -> SiriSnapshot {
        var snapshot = liveSnapshotOnThisMac(progress: progress)
        snapshot.isVirtualMachine = Machine.isVirtualMachine
        return snapshot
    }

    private static func liveSnapshotOnThisMac(progress: LoadProgressRelay) -> SiriSnapshot {
        let guardian = AppleIntelligenceLanguageGuard()
        let environment = LiveSiriLanguageEnvironment()
        let status = guardian.status()
        let plan: Result<SiriLanguageChangePlan, SiriPlanFailure>
        do {
            plan = .success(try guardian.plan(.disable, context: environment.context(), scope: .thisMacOnly, saved: environment.loadSavedSettings()))
        } catch {
            plan = .failure(SiriPlanFailure(message: "\(error)"))
        }
        progress.report(0.15)
        let accounts = AppleIntelligenceAccountsReport.live()
        progress.report(0.3)
        let cli = ToolLocator.cli()
        var purgeable = PurgeRun(service: CacheDeleteService.mobileAsset).estimate()
        progress.report(0.65)
        // Without what macOS estimates but would not delete when asked (`PurgeHoldouts`). Not offered at all while Apple Intelligence
        // is on: MacSpace leaves the system assets alone then (`SystemAssetGuard`).
        purgeable = SystemAssetGuard.holdsAssets ? nil : purgeable.map { PurgeHoldouts.shared.freeable(CacheDeleteService.mobileAsset, estimate: $0) }
        let release = AppleIntelligenceModelRelease(environment: environment, accounts: { accounts })
        var snapshot = SiriSnapshot(status: status, disablePlan: plan, accounts: accounts, purgeableAssetsBytes: purgeable,
                                    releaseBlockers: release.blockers(), watch: AppleIntelligenceWatchStore().load(),
                                    cliPath: cli?.path ?? "/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli", takenAt: Date())
        let models = modelBytes()
        progress.report(0.9)
        snapshot.recordedModelBytes = models.installed
        snapshot.installedModelBytes = models.installed
        snapshot.downloadingModelBytes = models.downloading
        snapshot.lockedModelBytes = models.locked
        snapshot.assetsRetrying = PurgeRetrier.shared.isRetrying(CacheDeleteService.mobileAsset)
        snapshot.cloudSyncEnabled = SiriCloudSync.isEnabled()
        snapshot.phoneFeatures = PhoneFeatureFlags().status()
        snapshot.featureSettings = Dictionary(uniqueKeysWithValues: ModelFeatureSettings.Feature.allCases.map { ($0, ModelFeatureSettings().status($0)) })
        return snapshot
    }

    /// Where MobileAsset puts a download until it is complete (`<family>.<hash>.auto.<uuid>`, measured in the research: 5.8 GB there
    /// while the 3B model came back).
    static let stagingFolder = "/System/Library/AssetsV2/staging"

    /// What the models take now, installed and still downloading, from MobileAsset's own records (`ModelDescriptors`). The staging
    /// folder also shows a download whose records have not caught up. `installed` is nil only when the records cannot be read.
    static func modelBytes(fileManager: FileManager = .default) -> (installed: UInt64?, downloading: UInt64, locked: UInt64) {
        let usage = ModelDescriptors.usage(fileManager: fileManager)
        let staged = ((try? fileManager.contentsOfDirectory(atPath: stagingFolder)) ?? [])
            .filter { name in ModelDescriptors.families.contains { name.hasPrefix($0.replacingOccurrences(of: ".", with: "_") + ".") } }
            .compactMap { FileTreeSizer().size(at: URL(fileURLWithPath: "\(stagingFolder)/\($0)"))?.bytes }.reduce(0, +)
        return (usage?.installedBytes, max(usage?.downloadingBytes ?? 0, staged), usage?.lockedBytes ?? 0)
    }
}
