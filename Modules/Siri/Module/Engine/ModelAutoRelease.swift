import Foundation

/// Releases leftover Apple Intelligence models by itself, instead of asking the user to press a button.
///
/// macOS normally removes the model a few minutes after Apple Intelligence becomes unavailable (`releasing`). When it stays in that
/// state, the models are locked and only an available → unavailable transition frees them (`AppleIntelligenceModelRelease`). After
/// `settleTime` in that state MacSpace runs the release once, and again only after `retryAfter`, so a Mac where macOS keeps the
/// models anyway does not have its Siri language flipped over and over.
enum ModelAutoRelease {
    static let settleTime: TimeInterval = 10 * 60
    static let retryAfter: TimeInterval = 12 * 60 * 60

    static func shouldRun(state: AppleIntelligenceGuardState, blockers: [String], isVirtualMachine: Bool,
                          releasingSince: Date?, lastRun: Date?, now: Date) -> Bool {
        guard !isVirtualMachine, state == .releasing, blockers.isEmpty, let since = releasingSince else { return false }
        guard now.timeIntervalSince(since) >= settleTime else { return false }
        if let lastRun, now.timeIntervalSince(lastRun) < retryAfter { return false }
        return true
    }
}

/// Runs `ModelAutoRelease` against the live Mac: remembers since when the models have been releasing and when it last ran, and runs
/// one release at a time, off the caller's task.
actor ModelAutoReleaser {
    static let shared = ModelAutoReleaser()
    /// Only the app releases models by itself. The CLI also loads modules (`MacSpaceCli screen`) and exits as soon as it has printed:
    /// a release started there would be cut off with the Siri language still changed, on the Mac and, through iCloud, on the iPhone.
    static let runsHere = ProcessInfo.processInfo.processName == "MacSpace"

    private static let releasingSinceKey = "siri.modelsReleasingSince"
    private static let lastRunKey = "siri.modelsAutoReleasedAt"
    private var defaults: UserDefaults { .standard }
    private(set) var isRunning = false

    /// Looks at the state just read and starts the release when it is due. `release` runs the release and its purge; `finished`
    /// is called afterwards so the module reads the Mac again. Returns the running release, for a caller that must not end before
    /// it does (a background run: the release changes the Siri language for a minute and restores it at the end).
    @discardableResult
    func check(_ snapshot: SiriSnapshot, now: Date = Date(), release: @escaping @Sendable () -> Void,
               finished: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        guard Self.runsHere, !isRunning else { return nil }
        if snapshot.status.state == .releasing {
            if defaults.object(forKey: Self.releasingSinceKey) == nil { defaults.set(now, forKey: Self.releasingSinceKey) }
        } else {
            defaults.removeObject(forKey: Self.releasingSinceKey)
        }
        let due = ModelAutoRelease.shouldRun(state: snapshot.status.state, blockers: snapshot.releaseBlockers,
                                             isVirtualMachine: snapshot.isVirtualMachine,
                                             releasingSince: defaults.object(forKey: Self.releasingSinceKey) as? Date,
                                             lastRun: defaults.object(forKey: Self.lastRunKey) as? Date, now: now)
        guard due else { return nil }
        isRunning = true
        defaults.set(now, forKey: Self.lastRunKey)
        return Task.detached(priority: .utility) {
            release()
            await self.done()
            await finished()
        }
    }

    private func done() { isRunning = false }
}
