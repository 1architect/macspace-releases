import Foundation
import MacSpacePlatform
import MacSpaceSiriPrivileged

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
    /// What the Apple Intelligence models take on disk now (the 3B base model and its adapters); nil if it cannot be read.
    var installedModelBytes: UInt64?
    /// What macOS is downloading for those models right now (its staging folder).
    var downloadingModelBytes: UInt64 = 0
    /// macOS kept the unused assets when asked; MacSpace is asking it again in the background (`PurgeRetrier`).
    var assetsRetrying = false
    /// MacSpace is deleting released models in the background right now (`ModelPurger`).
    var purgingModels = false
    /// The part of the installed models macOS still holds a lock on (`ModelDescriptors.Usage.lockedBytes`).
    var lockedModelBytes: UInt64 = 0
}

struct SiriPlanFailure: Error, Sendable, Equatable {
    var message: String
}

actor SiriStore {
    typealias Builder = @Sendable () -> SiriSnapshot

    private var cached: SiriSnapshot?
    private var inflight: Task<SiriSnapshot, Never>?
    private let builder: Builder
    /// Bumped by `invalidate`: a scan that started before it (before an action) is not kept or handed out after it, or the page
    /// came back with the figures from before the action.
    private var generation = 0

    init(builder: @escaping Builder = SiriStore.liveSnapshot) {
        self.builder = builder
    }

    func snapshot(maxAge: TimeInterval = 20, now: Date = Date()) async -> SiriSnapshot {
        if let cached, now.timeIntervalSince(cached.takenAt) < maxAge { return cached }
        // A caller that waited on a scan an `invalidate` made obsolete (an action finished meanwhile) asks again instead of taking
        // the figures from before the action.
        if let inflight {
            let waitedFor = generation
            let fresh = await inflight.value
            return waitedFor == generation ? fresh : await snapshot(maxAge: maxAge)
        }
        let builder = self.builder
        let task = Task.detached(priority: .utility) { builder() }
        let started = generation
        inflight = task
        let fresh = await task.value
        guard started == generation else { return await snapshot(maxAge: maxAge) }
        cached = fresh
        inflight = nil
        return fresh
    }

    func invalidate() {
        cached = nil
        inflight = nil
        generation += 1
    }

    static func liveSnapshot() -> SiriSnapshot {
        var snapshot = liveSnapshotOnThisMac()
        snapshot.isVirtualMachine = Machine.isVirtualMachine
        return snapshot
    }

    private static func liveSnapshotOnThisMac() -> SiriSnapshot {
        let guardian = AppleIntelligenceLanguageGuard()
        let environment = LiveSiriLanguageEnvironment()
        let status = guardian.status()
        let plan: Result<SiriLanguageChangePlan, SiriPlanFailure>
        do {
            plan = .success(try guardian.plan(.disable, context: environment.context(), scope: .thisMacOnly, saved: environment.loadSavedSettings()))
        } catch {
            plan = .failure(SiriPlanFailure(message: "\(error)"))
        }
        let accounts = AppleIntelligenceAccountsReport.live()
        let cli = ToolLocator.cli()
        let purgeable: UInt64?
        if let cli { purgeable = CacheDeleteClient.purgeableInSubprocess(executable: cli) }
        else { purgeable = CacheDeleteClient().purgeableByService()?[CacheDeleteService.mobileAsset] }
        let release = AppleIntelligenceModelRelease(environment: environment, accounts: { accounts })
        var snapshot = SiriSnapshot(status: status, disablePlan: plan, accounts: accounts, purgeableAssetsBytes: purgeable,
                                    releaseBlockers: release.blockers(), watch: AppleIntelligenceWatchStore().load(),
                                    cliPath: cli?.path ?? "/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli", takenAt: Date())
        let models = modelBytes()
        snapshot.installedModelBytes = models.installed
        snapshot.downloadingModelBytes = models.downloading
        snapshot.lockedModelBytes = models.locked
        snapshot.assetsRetrying = PurgeRetrier.shared.isRetrying(CacheDeleteService.mobileAsset)
        return snapshot
    }

    /// Where MobileAsset puts a download until it is complete (`<family>.<hash>.auto.<uuid>`, measured in the research: 5.8 GB there
    /// while the 3B model came back).
    static let stagingFolder = "/System/Library/AssetsV2/staging"

    /// What the models take now, installed and still downloading, from MobileAsset's own records (`ModelDescriptors`), as System
    /// Settings' Storage counts them. The staging folder also shows a download whose records have not caught up. `installed` is nil
    /// only when the records cannot be read.
    static func modelBytes(fileManager: FileManager = .default) -> (installed: UInt64?, downloading: UInt64, locked: UInt64) {
        let usage = ModelDescriptors.usage(fileManager: fileManager)
        let staged = ((try? fileManager.contentsOfDirectory(atPath: stagingFolder)) ?? [])
            .filter { name in ModelDescriptors.families.contains { name.hasPrefix($0.replacingOccurrences(of: ".", with: "_") + ".") } }
            .compactMap { FileTreeSizer().size(at: URL(fileURLWithPath: "\(stagingFolder)/\($0)"))?.bytes }.reduce(0, +)
        return (usage?.installedBytes, max(usage?.downloadingBytes ?? 0, staged), usage?.lockedBytes ?? 0)
    }
}
