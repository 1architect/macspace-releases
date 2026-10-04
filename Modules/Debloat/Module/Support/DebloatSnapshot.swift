import Foundation
import MacSpacePlatform
import MacSpaceDebloatPrivileged

/// What the Debloat screens are built from.
struct DebloatSnapshot: Sendable {
    var controls: [DebloatControl]
    var statuses: [String: ControlStatus]
    var environment: DebloatEnvironment
    /// Controls macOS ignores on this Mac, by id (see `DebloatEngine.cannotTakeEffect`).
    var cannotTakeEffect: Set<String>
    var takenAt: Date

    func status(_ id: String) -> ControlStatus? { statuses[id] }
}

actor DebloatStore {
    typealias Builder = @Sendable () -> DebloatSnapshot

    private var cached: DebloatSnapshot?
    private var inflight: Task<DebloatSnapshot, Never>?
    private let builder: Builder
    /// Bumped by `invalidate`: a scan that started before it (before an action) is not kept or handed out after it, or the page
    /// came back with the figures from before the action.
    private var generation = 0

    init(builder: @escaping Builder = DebloatStore.liveSnapshot) {
        self.builder = builder
    }

    func snapshot(maxAge: TimeInterval = 15, now: Date = Date()) async -> DebloatSnapshot {
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

    static func liveEngine() -> DebloatEngine {
        DebloatEngine(system: LiveDebloatSystem(), journal: DebloatJournalStore(targetUser: DebloatTargetUser.resolve()))
    }

    static func liveSnapshot() -> DebloatSnapshot {
        let engine = liveEngine()
        let environment = engine.system.environment()
        // Only the controls meant for this build (the analytics switch on a release build, its profile on a beta).
        let controls = engine.controls.filter { $0.isOffered(in: environment) }
        let statuses = controls.map(engine.status(of:))
        return DebloatSnapshot(controls: controls, statuses: Dictionary(uniqueKeysWithValues: statuses.map { ($0.controlID, $0) }),
                               environment: environment,
                               cannotTakeEffect: Set(controls.filter(engine.cannotTakeEffect).map(\.id)), takenAt: Date())
    }
}
