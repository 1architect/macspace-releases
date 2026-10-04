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
    /// Siri's iCloud sync: on now (nil when unreadable), and whether the user chose to keep it (`SiriCloudSync`).
    var cloudSyncOn: Bool?
    var keepsCloudSync = false
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
        let offerable = PurgeLedger().offerable(CacheDeleteService.mobileAsset, estimate: purgeable)
        let release = AppleIntelligenceModelRelease(environment: environment, accounts: { accounts })
        var snapshot = SiriSnapshot(status: status, disablePlan: plan, accounts: accounts, purgeableAssetsBytes: offerable,
                                    releaseBlockers: release.blockers(), watch: AppleIntelligenceWatchStore().load(),
                                    cliPath: cli?.path ?? "/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli", takenAt: Date())
        let models = modelBytes()
        snapshot.installedModelBytes = models.installed
        snapshot.downloadingModelBytes = models.downloading
        let sync = SiriCloudSync()
        snapshot.cloudSyncOn = sync.isEnabled()
        snapshot.keepsCloudSync = sync.userChoice() == true
        return snapshot
    }

    /// The asset families that hold Apple Intelligence's models: the language models, their overrides, the image models and the
    /// planner. Measured together: the 3B model alone left out what macOS downloads first.
    static let modelFamilies = ["com_apple_MobileAsset_UAF_FM_GenerativeModels", "com_apple_MobileAsset_UAF_FM_Overrides",
                                "com_apple_MobileAsset_UAF_FM_Visual", "com_apple_MobileAsset_UAF_IF_Planner",
                                "com_apple_MobileAsset_UAF_IF_PlannerOverrides"]
    static let assetsRoot = "/System/Library/AssetsV2"
    /// Where MobileAsset puts a download until it is complete (`<family>.<hash>.auto.<uuid>`, measured in the research: 5.8 GB there
    /// while the 3B model came back).
    static let stagingFolder = "/System/Library/AssetsV2/staging"

    /// What the models take now, installed and still downloading. `installed` is nil when a family's folder could not be read: macOS
    /// keeps them closed without Full Disk Access, and an unreadable folder must not read as "no model".
    static func modelBytes(fileManager: FileManager = .default) -> (installed: UInt64?, downloading: UInt64) {
        let sizer = FileTreeSizer()
        var installed: UInt64 = 0
        var unreadable = false
        for family in modelFamilies {
            let url = URL(fileURLWithPath: "\(assetsRoot)/\(family)")
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard let size = sizer.size(at: url) else { unreadable = true; continue }
            if size.unreadableFolders > 0 { unreadable = true }
            installed += size.bytes
        }
        let staged = ((try? fileManager.contentsOfDirectory(atPath: stagingFolder)) ?? [])
            .filter { name in modelFamilies.contains { name.hasPrefix($0 + ".") } }
        let downloading = staged.compactMap { sizer.size(at: URL(fileURLWithPath: "\(stagingFolder)/\($0)"))?.bytes }.reduce(0, +)
        return (unreadable && installed == 0 ? nil : installed, downloading)
    }
}
