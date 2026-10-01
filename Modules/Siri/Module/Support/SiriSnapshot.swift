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
}

struct SiriPlanFailure: Error, Sendable, Equatable {
    var message: String
}

actor SiriStore {
    typealias Builder = @Sendable () -> SiriSnapshot

    private var cached: SiriSnapshot?
    private var inflight: Task<SiriSnapshot, Never>?
    private let builder: Builder

    init(builder: @escaping Builder = SiriStore.liveSnapshot) {
        self.builder = builder
    }

    func snapshot(maxAge: TimeInterval = 20, now: Date = Date()) async -> SiriSnapshot {
        if let cached, now.timeIntervalSince(cached.takenAt) < maxAge { return cached }
        if let inflight { return await inflight.value }
        let builder = self.builder
        let task = Task.detached(priority: .utility) { builder() }
        inflight = task
        let fresh = await task.value
        cached = fresh
        inflight = nil
        return fresh
    }

    func invalidate() { cached = nil }

    static func liveSnapshot() -> SiriSnapshot {
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
        let client = CacheDeleteClient()
        var purgeable: UInt64?
        if let cli {
            client.ensureValidated(executable: cli)
            if client.support == .validated { purgeable = CacheDeleteClient.purgeableInSubprocess(executable: cli) }
        } else if client.support == .validated {
            purgeable = client.purgeableByService()?[CacheDeleteService.mobileAsset]
        }
        let release = AppleIntelligenceModelRelease(environment: environment, accounts: { accounts })
        return SiriSnapshot(status: status, disablePlan: plan, accounts: accounts, purgeableAssetsBytes: purgeable,
                            releaseBlockers: release.blockers(), watch: AppleIntelligenceWatchStore().load(),
                            cliPath: cli?.path ?? "/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli", takenAt: Date())
    }
}
