import Foundation
import MacSpacePlatform

/// Deletes Apple Intelligence models macOS has released, by itself and in the background.
///
/// Once Apple Intelligence is unavailable, mobileassetd drops its locks on the models within seconds (5 s observed), and they are
/// then deleted only under disk pressure. Purging mobileassetd's CacheDelete service deletes them now: 12.04 GB in 4.6 s
/// (2026-09-30), 11.08 GB in 4.7 s (2026-10-04). MacSpace does it after switching Apple Intelligence off, and whenever it finds
/// released models still on disk (switched off in System Settings, or a purge that came too early), without the user asking.
actor ModelPurger {
    static let shared = ModelPurger()
    /// Only the app purges by itself; the CLI loads modules too and exits as soon as it has printed.
    static let runsHere = ProcessInfo.processInfo.processName == "MacSpace"
    /// Between two purges started because released models were found on disk.
    static let minimumInterval: TimeInterval = 10 * 60

    private var running: Task<Void, Never>?
    private var lastStarted: Date?

    var isRunning: Bool { running != nil }

    /// Purges after `delay` (the time mobileassetd takes to drop its locks); if macOS keeps the models, `PurgeRetrier` asks again.
    /// `done` lets the module read the Mac again.
    func purge(after delay: TimeInterval, force: Bool, now: Date = Date(), done: @escaping @Sendable () async -> Void) {
        guard Self.runsHere, running == nil else { return }
        if !force, let lastStarted, now.timeIntervalSince(lastStarted) < Self.minimumInterval { return }
        lastStarted = now
        running = Task.detached(priority: .utility) {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let outcome = PurgeRun(service: CacheDeleteService.mobileAsset).run { freed in
                SiriModule.recordBackground(freed, summary: loc("Released Apple Intelligence models"))
                await done()
            }
            SiriModule.recordBackground(outcome.freed, summary: loc("Released Apple Intelligence models"))
            await self.finish()
            await done()
        }
    }

    private func finish() { running = nil }
}
