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

    init(builder: @escaping Builder = DebloatStore.liveSnapshot) {
        self.builder = builder
    }

    func snapshot(maxAge: TimeInterval = 15, now: Date = Date()) async -> DebloatSnapshot {
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

    static func liveEngine() -> DebloatEngine {
        DebloatEngine(system: LiveDebloatSystem(), journal: DebloatJournalStore(targetUser: DebloatTargetUser.resolve()))
    }

    static func liveSnapshot() -> DebloatSnapshot {
        let engine = liveEngine()
        let statuses = engine.status()
        return DebloatSnapshot(controls: engine.controls, statuses: Dictionary(uniqueKeysWithValues: statuses.map { ($0.controlID, $0) }),
                               environment: engine.system.environment(),
                               cannotTakeEffect: Set(engine.controls.filter(engine.cannotTakeEffect).map(\.id)), takenAt: Date())
    }
}
