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
        if let inflight { return await inflight.value }
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
        snapshot.installedModelBytes = installedModelBytes()
        return snapshot
    }

    /// The Apple Intelligence models' folder (every purpose), measured.
    static func installedModelBytes() -> UInt64? {
        let folder = URL(fileURLWithPath: AppleIntelligenceLanguageGuard.generativeModelsAssetDirectory).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path) else { return 0 }
        guard let size = FileTreeSizer().size(at: folder) else { return nil }
        return size.allocatedBytesEstimate ?? size.logicalBytes
    }
}
