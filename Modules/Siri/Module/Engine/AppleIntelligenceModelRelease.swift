import Foundation
import MacSpaceSiriPrivileged
import MacSpacePlatform

/// Releases and deletes Apple Intelligence models that stay installed although this account's off-switch holds.
///
/// Measured on 26B5091g (`results/ai-orphan-subscriptions-2026-09-30/`):
/// - The models stay locked ("never remove") until this account's Apple Intelligence goes available → unavailable.
///   A switch between two ineligible Siri languages does not release them.
/// - Setting the Siri language to the system language made ModelCatalog take the models (23 decisions, nothing downloaded).
///   Setting it back made 6 decisions, and mobileassetd removed the lock entries within 5 s.
/// - mobileassetd then deletes them only under disk pressure, so the release ends with a CacheDelete purge.
/// The original Siri language and voice are restored on every path.
public struct ModelReleaseStep: Codable, Equatable, Sendable {
    public let at: Date
    public let name: String
    public let detail: String
}

public struct ModelReleaseResult: Codable, Equatable, Sendable {
    public let executed: Bool
    public let blockers: [String]
    public let steps: [ModelReleaseStep]
    /// The Siri language after the run; always the original one.
    public let siriLanguageAfter: String?
    /// Whether eligibility could be read (Full Disk Access). Without it the steps run on fixed waits.
    public let eligibilityVerified: Bool
    public let purge: CacheDeletePurgeResult?
    public let error: String?
}

public struct ModelReleaseTiming: Sendable {
    public var eligibleTimeout: Double = 30
    /// Time for ModelCatalog to take the models after Apple Intelligence becomes available (5 s observed).
    public var ownershipWait: Double = 20
    public var ineligibleTimeout: Double = 30
    /// Time for mobileassetd to drop its locks after Apple Intelligence becomes unavailable (5 s observed).
    public var releaseWait: Double = 15
    public var pollInterval: Double = 1

    public init() {}
}

public struct AppleIntelligenceModelRelease {
    let environment: any SiriLanguageEnvironment
    let accounts: () -> AppleIntelligenceAccountsReport?
    let purge: () -> CacheDeletePurgeResult
    let timing: ModelReleaseTiming
    let now: () -> Date

    public init(environment: any SiriLanguageEnvironment = LiveSiriLanguageEnvironment(),
                accounts: @escaping () -> AppleIntelligenceAccountsReport? = { AppleIntelligenceAccountsReport.live() },
                purge: @escaping () -> CacheDeletePurgeResult = { CacheDeleteClient().purge(services: [CacheDeleteService.mobileAsset]) },
                timing: ModelReleaseTiming = ModelReleaseTiming(), now: @escaping () -> Date = Date.init) {
        self.environment = environment
        self.accounts = accounts
        self.purge = purge
        self.timing = timing
        self.now = now
    }

    /// Reasons the release cannot work now. Empty means it may run.
    public func blockers() -> [String] {
        var blockers: [String] = []
        let context = environment.context()
        guard let system = context.systemLanguage.map(AppleIntelligenceLanguageGuard.normalize),
              let siri = context.siriLanguage.map(AppleIntelligenceLanguageGuard.normalize) else {
            return [loc("The system or Siri language could not be read.")]
        }
        if AppleIntelligenceLanguageGuard.baseLanguage(siri) == AppleIntelligenceLanguageGuard.baseLanguage(system) {
            blockers.append(loc("Apple Intelligence is not switched off in this account (Siri language \(siri) matches the system language); switch it off in MacSpace first."))
        }
        let elsewhere = accounts()?.enabledElsewhere ?? []
        let existing = elsewhere.compactMap(\.name)
        if !existing.isEmpty {
            blockers.append(loc("Apple Intelligence is on in \(existing.joined(separator: ", ")); those accounts keep the models. Switch it off there or delete the accounts."))
        }
        if elsewhere.contains(where: { $0.name == nil }) {
            blockers.append(loc("Deleted accounts still subscribe to the models. Remove their leftovers in MacSpace (Siri & Apple Intelligence), restart, then try again."))
        }
        return blockers
    }

    /// `onStep` is called as each step completes, so a UI can show progress during the minute the release takes.
    public func run(onStep: (ModelReleaseStep) -> Void = { _ in }) -> ModelReleaseResult {
        let blockers = blockers()
        guard blockers.isEmpty else {
            return ModelReleaseResult(executed: false, blockers: blockers, steps: [], siriLanguageAfter: environment.context().siriLanguage,
                                      eligibilityVerified: false, purge: nil, error: nil)
        }
        var steps: [ModelReleaseStep] = []
        func log(_ name: String, _ detail: String) {
            let step = ModelReleaseStep(at: now(), name: name, detail: detail)
            steps.append(step)
            onStep(step)
        }
        let context = environment.context()
        let original = context.siriLanguage!
        let originalVoice = environment.outputVoice()
        var verified = environment.eligibilityAnswer() != nil

        func waitFor(eligible: Bool, timeout: Double) -> Bool? {
            var waited = 0.0
            while true {
                guard let answer = environment.eligibilityAnswer() else { return nil }
                if (answer == AppleIntelligenceLanguageGuard.eligibleAnswer) == eligible { return true }
                if waited >= timeout { return false }
                environment.sleep(seconds: timing.pollInterval)
                waited += timing.pollInterval
            }
        }
        func restore() throws {
            try environment.write(siriLanguage: original, outputVoice: originalVoice)
        }
        func finish(_ error: String?, purge: CacheDeletePurgeResult? = nil) -> ModelReleaseResult {
            ModelReleaseResult(executed: true, blockers: [], steps: steps, siriLanguageAfter: environment.context().siriLanguage,
                               eligibilityVerified: verified, purge: purge, error: error)
        }

        // 1. Make Apple Intelligence available: Siri language = system language.
        let target: String
        do {
            target = try AppleIntelligenceLanguageGuard().plan(.enable, context: context, scope: .thisMacOnly).targetSiriLanguage
            try environment.write(siriLanguage: target, outputVoice: nil)
        } catch {
            try? restore()
            return finish("Could not set the Siri language to the system language: \(error)")
        }
        log("available", "Siri language \(original) → \(target).")
        switch waitFor(eligible: true, timeout: timing.eligibleTimeout) {
        case false?:
            try? restore()
            log("restored", "Apple Intelligence did not become available; Siri language restored to \(original).")
            return finish("Apple Intelligence did not become available within \(Int(timing.eligibleTimeout)) s.")
        case nil:
            verified = false
            log("unverified", "Eligibility is unreadable (Full Disk Access); continuing on fixed waits.")
        case true?:
            log("eligible", "Apple Intelligence is available.")
        }
        environment.sleep(seconds: timing.ownershipWait)

        // 2. Make it unavailable again: the transition releases the models' locks.
        do { try restore() } catch {
            return finish("Could not restore the Siri language \(original): \(error). Apple Intelligence may still be available; switch Apple Intelligence off again in MacSpace.")
        }
        log("unavailable", "Siri language \(target) → \(original).")
        if waitFor(eligible: false, timeout: timing.ineligibleTimeout) == false {
            return finish("Siri language is \(original) again, but Apple Intelligence still reads as available; nothing was purged.")
        }
        environment.sleep(seconds: timing.releaseWait)

        // 3. Delete what is now unlocked.
        let result = purge()
        log("purged", result.error ?? "Freed \(result.freedBytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "an unknown amount").")
        return finish(result.error, purge: result)
    }
}
