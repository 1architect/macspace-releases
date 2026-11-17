import Foundation
import MacSpacePlatform
import MacSpaceDebloatPrivileged
import MacSpaceSdk

/// What the Debloat screens are built from.
struct DebloatSnapshot: Sendable {
    var controls: [DebloatControl]
    var statuses: [String: ControlStatus]
    var environment: DebloatEnvironment
    /// Controls macOS ignores on this Mac, by id (see `DebloatEngine.cannotTakeEffect`).
    var cannotTakeEffect: Set<String>
    var takenAt: Date
    /// What the background watch switched off again lately, newest first.
    var reapplied: [DebloatReapplied] = []
    /// What the one MacSpace profile needs: approval of a new version, or the helper removing profiles.
    var profileWork: ProfileWork = .none

    func status(_ id: String) -> ControlStatus? { statuses[id] }
}

actor DebloatStore {
    typealias Builder = @Sendable (LoadProgressRelay) -> DebloatSnapshot

    private let reading: SharedReading<DebloatSnapshot>

    init(builder: @escaping Builder = DebloatStore.liveSnapshot) {
        reading = SharedReading { builder($0) }
    }

    func snapshot(maxAge: TimeInterval = 15, now: Date = Date(), progress: LoadProgressSink? = nil) async -> DebloatSnapshot {
        await reading.value(maxAge: maxAge, now: now, progress: progress)
    }

    private var cleanedUp: Set<[String]> = []

    /// Whether these profiles have not been cleaned up yet in this run of the app.
    func firstCleanUp(_ identifiers: [String]) -> Bool {
        cleanedUp.insert(identifiers).inserted
    }

    func invalidate() async { await reading.invalidate() }

    static func liveEngine(system: LiveDebloatSystem = LiveDebloatSystem()) -> DebloatEngine {
        DebloatEngine(system: system, journal: DebloatJournalStore(targetUser: DebloatTargetUser.resolve()))
    }

    /// The states in which something of a control is applied.
    static let appliedStates: Set<ControlState> = [.debloated, .awaitingApproval, .partial, .drifted, .awaitingRemoval]

    /// Whether the page lists a control. A retired one is listed only while something of it is applied, so it can be switched back
    /// on and removed; once it is, it goes away.
    static func isShown(_ control: DebloatControl, in environment: DebloatEnvironment, status: () -> ControlStatus) -> Bool {
        guard control.isOffered(in: environment) else { return false }
        guard control.retired != nil else { return true }
        return appliedStates.contains(status().state)
    }

    private var undoneRetired: Set<[String]> = []

    /// Whether MacSpace has not tried yet, in this run of the app, to switch these retired controls back on.
    func firstRetiredUndo(_ ids: [String]) -> Bool {
        undoneRetired.insert(ids).inserted
    }

    static func liveSnapshot(progress: LoadProgressRelay) -> DebloatSnapshot {
        let system = LiveDebloatSystem()
        let engine = liveEngine(system: system)
        let profilesReady = DispatchGroup()
        let profiles = LockedArray<[InstalledProfile]?>(repeating: nil, count: 1)
        // The profile command has no dependency on the environment or on the process list.
        DispatchQueue.global(qos: LoadWorkPriority.current).async(group: profilesReady) {
            let result = ModuleLoadMetrics.measure("debloat", "installed-profiles") {
                LiveDebloatSystem(targetUser: nil).installedProfiles()
            }
            profiles.set(0, result)
        }
        var processes: [RunningProcess]?
        let environment = ModuleLoadMetrics.measure("debloat", "environment") {
            system.environment {
                let observed = ModuleLoadMetrics.measure("debloat", "processes") { system.processes() }
                processes = observed
                return observed
            }
        }
        progress.report(0.15)
        // Only the controls meant for this build (the analytics switch on a release build, its profile on a beta), and a retired
        // one only where it is still applied.
        let offered = engine.controls.filter { $0.isOffered(in: environment) }
        let inspection = ModuleLoadMetrics.measure("debloat", "inspection") {
            profilesReady.wait()
            return engine.inspection(of: offered, installedProfiles: profiles.values[0], processes: processes,
                                     progress: progress.part(0.15...0.85))
        }
        let statuses = Dictionary(inspection.statuses.map { ($0.controlID, $0) }, uniquingKeysWith: { first, _ in first })
        let controls = offered.filter { control in isShown(control, in: environment, status: { statuses[control.id] ?? engine.status(of: control) }) }
        progress.report(0.9)
        return DebloatSnapshot(controls: controls, statuses: statuses.filter { id, _ in controls.contains { $0.id == id } },
                               environment: environment,
                               cannotTakeEffect: Set(controls.filter(engine.cannotTakeEffect).map(\.id)), takenAt: Date(),
                               reapplied: DebloatWatchStore().recent(), profileWork: inspection.profileWork)
    }
}
