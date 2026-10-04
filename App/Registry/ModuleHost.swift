import Foundation
import MacSpaceSdk
import MacSpacePlatform
import Combine
import SwiftUI

/// Finds the installed modules and keeps them in step with the user's settings.
@MainActor
public final class ModuleHost: ObservableObject {
    @Published public private(set) var handles: [ModuleHandle] = []
    @Published public private(set) var problems: [ModuleProblem] = []
    /// The modules folder has been read, so `dashboardHandles` is final even if the modules are still loading.
    @Published public private(set) var hasScanned = false
    /// What each module's tile says it can free, by module id. The dashboard gives the large tile to the most, so it must redraw when a
    /// module's figure arrives or changes; it does not observe each handle.
    @Published public private(set) var reclaimable: [String: UInt64] = [:]
    /// What each module purges through macOS, by module id then CacheDelete service (`Tile.purgeableByService`), for the disk tile.
    @Published public private(set) var purgeable: [String: [String: UInt64]] = [:]

    /// The disk tile's "purgeable": every service once (the largest figure any module gives for it), summed.
    public var purgeableTotal: UInt64 {
        var byService: [String: UInt64] = [:]
        for services in purgeable.values {
            for (service, bytes) in services { byService[service] = max(byService[service] ?? 0, bytes) }
        }
        return byService.values.reduce(0, +)
    }

    public let settings: SettingsStore
    public let permissions: any PermissionChecker
    public let modulesDirectory: URL?
    private let loader: ModuleHandle.Loader
    private let privileged: (any PrivilegedChannel)?
    public let scheduler = BackgroundScheduler()

    /// `MACSPACE_MODULES_DIR` points a development build at another folder of modules.
    public static func defaultModulesDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = environment["MACSPACE_MODULES_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return Bundle.main.builtInPlugInsURL
    }

    /// The folder of a built app next to the command-line tool, for `macspace modules`.
    public nonisolated static func defaultModulesDirectoryForCli() -> URL {
        if let override = ProcessInfo.processInfo.environment["MACSPACE_MODULES_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return URL(fileURLWithPath: "/Applications/MacSpace.app/Contents/PlugIns", isDirectory: true)
    }

    public init(modulesDirectory: URL? = ModuleHost.defaultModulesDirectory(), settings: SettingsStore = SettingsStore(),
                permissions: any PermissionChecker = LivePermissionChecker(helper: { PrivilegedHelperInstaller.permissionStatus() }),
                privileged: (any PrivilegedChannel)? = LazyPrivilegedChannel(),
                loader: @escaping ModuleHandle.Loader = ModuleLoader.load) {
        self.modulesDirectory = modulesDirectory
        self.settings = settings
        self.permissions = permissions
        self.privileged = privileged
        self.loader = loader
    }

    private var checkedHelper = false
    private var startTask: Task<Void, Never>?
    private var stateObservers: [AnyCancellable] = []
    private var tileObservers: [AnyCancellable] = []
    private var purgeableObservers: [AnyCancellable] = []

    /// `activeHandles` depends on each handle's state, which changes after the handles are created (off → ready). The views that list
    /// the active modules observe the host, so a module becoming ready must announce itself through the host too; without this the
    /// dashboard and sidebar stayed empty until something else (opening Settings) redrew them.
    private func observeStates() {
        stateObservers = handles.map { handle in
            handle.$state.dropFirst().removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() }
        }
        reclaimable = reclaimable.filter { id, _ in handles.contains { $0.id == id } }
        purgeable = purgeable.filter { id, _ in handles.contains { $0.id == id } }
        purgeableObservers = handles.map { handle in
            let id = handle.id
            return handle.$tile.map { $0?.purgeableByService ?? [:] }.removeDuplicates().sink { [weak self] services in
                MainActor.assumeIsolated {
                    guard let self, self.purgeable[id] != services else { return }
                    self.purgeable[id] = services
                }
            }
        }
        tileObservers = handles.map { handle in
            let id = handle.id
            // Handles publish their tiles on the main actor.
            return handle.$tile.map { $0?.reclaimableBytes }.removeDuplicates().sink { [weak self] bytes in
                MainActor.assumeIsolated {
                    guard let self, self.reclaimable[id] != bytes else { return }
                    self.reclaimable[id] = bytes
                }
            }
        }
    }

    /// Loads the modules once, whoever asks first: the app at launch, the window, or the menu bar item. Later callers wait for the same
    /// load instead of starting another.
    public func start() async {
        if startTask == nil { startTask = Task { await self.reload() } }
        await startTask?.value
    }

    /// Scans the modules folder and activates every enabled module.
    public func reload() async {
        guard let modulesDirectory else { handles = []; problems = []; hasScanned = true; return }
        // The modules are listed first, so the dashboard can lay out its tiles before anything slow happens.
        let found = ModuleScanner.scan(directory: modulesDirectory)
        problems = found.problems
        let existing = Dictionary(uniqueKeysWithValues: handles.map { ($0.id, $0) })
        handles = found.modules.map { descriptor in
            if let known = existing[descriptor.id], known.descriptor == descriptor { return known }
            return ModuleHandle(descriptor: descriptor, settings: settings, permissions: permissions, privileged: privileged, loader: loader)
        }
        observeStates()
        hasScanned = true
        if !checkedHelper, let privileged {
            checkedHelper = true
            await PrivilegedHelperInstaller.restartIfStale(channel: privileged)
        }
        // Modules load side by side: a slow scan in one must not hold back the others, and each page appears as soon as it is ready.
        let loading = handles.map { handle in Task { await handle.activate() } }
        for task in loading { await task.value }
        applySchedule()
    }

    public func setEnabled(_ enabled: Bool, module id: String) async {
        settings.setEnabled(enabled, module: id)
        if let handle = handles.first(where: { $0.id == id }) { await handle.activate() }
        applySchedule()
    }

    public func setBackgroundTask(_ enabled: Bool, _ taskID: String, module id: String) {
        settings.setBackgroundTask(enabled, taskID, module: id)
        applySchedule()
    }

    public func handle(for id: String) -> ModuleHandle? { handles.first { $0.id == id } }

    public var activeHandles: [ModuleHandle] { handles.filter { $0.state == .ready } }

    /// The modules the dashboard shows: the ready ones and those that are switched on and still loading.
    public var dashboardHandles: [ModuleHandle] { handles.filter { $0.state == .ready || ($0.state == .off && $0.isEnabled) } }

    func applySchedule() { scheduler.apply(handles: handles) }
}
