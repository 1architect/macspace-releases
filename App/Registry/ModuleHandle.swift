import Foundation
import MacSpacePlatform
import MacSpaceSdk
import SwiftUI

/// One module as the app sees it: its manifest, whether it is running, and the latest screen it produced.
@MainActor
public final class ModuleHandle: ObservableObject, Identifiable {
    public enum State: Equatable {
        case off
        case incompatible(String)
        case failed(String)
        case ready
    }

    public typealias Loader = (ModuleDescriptor) throws -> any MacSpaceModule

    public let descriptor: ModuleDescriptor
    public nonisolated var id: String { descriptor.id }
    public var manifest: ModuleManifest { descriptor.manifest }

    @Published public private(set) var state: State
    @Published public private(set) var screen: Screen?
    @Published public private(set) var tile: Tile?
    /// The tile is last session's, shown until the module has read the Mac again.
    @Published public private(set) var tileIsStale = false
    @Published public private(set) var isBusy = false
    /// The module is reading the Mac again (Refresh, or after an action): the tile's and the page's charts pulse as while loading.
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var progress: ActionProgress?
    @Published public private(set) var lastResult: ActionResult?
    /// An action the user started from a button (not a switch), or automatic cleanup, is running: the menu bar icon animates.
    @Published public private(set) var isCleaning = false
    /// The group pages open over the module's page (`Row.children`), by id, the top one last; empty on the module's own page. A group
    /// opened from a group's page goes on top of it, and Back returns to the page under it, as everywhere else in the app.
    @Published public var groupPath: [String] = []
    /// The group page on top, if any.
    public var openGroup: String? { groupPath.last }

    public func pushGroup(_ id: String) {
        if groupPath.last != id { groupPath.append(id) }
    }

    /// Back from the group page on top, to the one under it or to the module's page.
    public func popGroup() {
        if !groupPath.isEmpty { groupPath.removeLast() }
    }

    private var module: (any MacSpaceModule)?
    /// Refreshes under way, and whether an action is running: both make the module busy.
    private var refreshes = 0
    private var performing = false
    /// Bumped by each refresh: a slower, older one that finishes last must not put back figures older than the newest.
    private var refreshGeneration = 0
    /// Bumped by each action: a progress message that arrives after its action finished must not show again.
    private var actionGeneration = 0
    private let settings: SettingsStore
    private let permissions: any PermissionChecker
    private let privileged: (any PrivilegedChannel)?
    private let loader: Loader

    public init(descriptor: ModuleDescriptor, settings: SettingsStore, permissions: any PermissionChecker,
                privileged: (any PrivilegedChannel)? = nil, loader: @escaping Loader = ModuleLoader.load) {
        self.descriptor = descriptor
        self.settings = settings
        self.permissions = permissions
        self.privileged = privileged
        self.loader = loader
        if case let .incompatible(reason) = descriptor.compatibility {
            state = .incompatible(reason)
        } else {
            state = .off
            tile = settings.lastTile(module: descriptor.id)
            tileIsStale = tile != nil
        }
    }

    public var isEnabled: Bool { settings.isEnabled(module: id) }

    public func context() -> ModuleContext {
        ModuleContext(manifest: manifest, options: settings.optionStore(for: manifest), permissions: permissions, privileged: privileged)
    }

    public func missingPermissions() -> [Permission] {
        manifest.permissions.filter { permissions.status(of: $0) == .missing }
    }

    /// Loads the module (once) when it is enabled and compatible, then fetches its tile and screen.
    public func activate() async {
        if case .incompatible = state { return }
        guard isEnabled else { deactivate(); return }
        if module == nil {
            do { module = try loader(descriptor) } catch {
                state = .failed(error.localizedDescription)
                // Last session's tile stays, but nothing will refresh it: it must not show as loading (and animate) forever.
                tileIsStale = false
                return
            }
        }
        state = .ready
        await refresh()
    }

    /// Drops the module's UI state. The loaded code stays in memory (bundles cannot be unloaded safely); it is simply not called.
    public func deactivate() {
        if case .incompatible = state { return }
        state = .off
        autoRefresh?.cancel()
        autoRefresh = nil
        screen = nil
        tile = nil
        tileIsStale = false
        lastResult = nil
        groupPath = []
    }

    /// `reload` asks the module to forget what it cached first (the Refresh button); after an action the module already did.
    /// `quiet` reads the module again without showing it: the charts do not pulse and Refresh does not spin (after a switch, whose
    /// row already shows the change).
    public func refresh(reload: Bool = false, quiet: Bool = false) async {
        guard state == .ready, let module else { return }
        let context = context()
        refreshGeneration += 1
        let generation = refreshGeneration
        if !quiet {
            refreshes += 1
            updateBusy()
        }
        defer {
            if !quiet {
                refreshes -= 1
                updateBusy()
            }
        }
        if reload { await module.invalidate() }
        async let nextTile = module.tile(context: context)
        async let nextScreen = module.screen(context: context)
        let (newTile, newScreen) = await (nextTile, nextScreen)
        guard generation == refreshGeneration, state == .ready else { return }
        tile = newTile
        tileIsStale = false
        settings.setLastTile(newTile, module: id)
        screen = newScreen
        scheduleAutoRefresh()
    }

    private func updateBusy() {
        isBusy = performing || refreshes > 0
        isRefreshing = refreshes > 0
    }

    /// Runs an action. Missing permissions stop it before the module is called. Returns what the module answered (nil when it was not
    /// called).
    ///
    /// `quiet` is for a switch: its row has already moved, so the page shows no progress and is not held while the change runs, and
    /// it is read again quietly afterwards. Only a result the user must see is shown: a failure (the row then moves back) or something
    /// left to do.
    @discardableResult
    public func perform(_ action: Action, extraParameters: [String: String] = [:], quiet: Bool = false) async -> ActionResult? {
        // One action at a time, in the order asked: switches no longer wait for each other, and two changes running together could
        // both write the module's undo journal.
        let previous = lastAction
        let task = Task { @MainActor [weak self] () -> ActionResult? in
            _ = await previous?.value
            return await self?.performNow(action, extraParameters: extraParameters, quiet: quiet)
        }
        lastAction = task
        return await task.value
    }

    private var lastAction: Task<ActionResult?, Never>?

    /// How often a module is read again by itself, so its tile and page follow the Mac without Refresh; a tile that is changing
    /// asks for sooner (`Tile.refreshAfter`).
    static let autoRefreshInterval: TimeInterval = 60
    static let fastestAutoRefresh: TimeInterval = 3
    private var autoRefresh: Task<Void, Never>?

    /// Schedules the next quiet reading after the one that just finished.
    private func scheduleAutoRefresh() {
        autoRefresh?.cancel()
        guard state == .ready else { return }
        let delay = max(min(tile?.refreshAfter ?? Self.autoRefreshInterval, Self.autoRefreshInterval), Self.fastestAutoRefresh)
        autoRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.state == .ready else { return }
            // Not while an action runs: it reads the module again itself when it ends.
            if self.performing { self.scheduleAutoRefresh() } else { await self.refresh(quiet: true) }
        }
    }

    private func performNow(_ action: Action, extraParameters: [String: String], quiet: Bool) async -> ActionResult? {
        guard state == .ready, let module else { return nil }
        let missing = action.requires.filter { permissions.status(of: $0) == .missing }
        if !missing.isEmpty {
            // For a switch it counts as failed: nothing changed, so the switch goes back.
            let result = ActionResult(outcome: quiet ? .failed : .needsAttention,
                                      message: "Needs \(missing.map(\.title).joined(separator: ", "))",
                                      refresh: false)
            lastResult = result
            return result
        }
        performing = true
        let started = Date()
        if !quiet { updateBusy(); isCleaning = true }
        defer { if !quiet { isCleaning = false } }
        if !quiet { progress = nil }
        lastResult = nil
        actionGeneration += 1
        let generation = actionGeneration
        let request = ActionRequest(actionID: action.id, parameters: action.parameters.merging(extraParameters) { _, new in new })
        let result = await module.perform(request, context: context()) { [weak self] update in
            guard !quiet else { return }
            Task { @MainActor in
                guard let self, self.performing, self.actionGeneration == generation else { return }
                self.progress = update
            }
        }
        if !quiet { progress = nil }
        if !quiet || result.outcome != .succeeded || result.restartRequired { lastResult = result }
        // A long action that ends while the user is in another app says so in Notification Center.
        if !quiet { AppNotifications.shared.actionFinished(module: self, message: result.message, took: Date().timeIntervalSince(started)) }
        if let freed = result.freedBytes {
            CleanupHistory.shared.record(moduleID: id, moduleName: manifest.name, freedBytes: freed, trigger: .manual, summary: result.message)
        }
        performing = false
        if !quiet { updateBusy() }
        if result.refresh { await refresh(quiet: quiet) }
        return result
    }

    public func dismissResult() { lastResult = nil }

    /// Shows a state of the page's action pill without running anything, for development captures (`DebugRemote`).
    func previewPill(cleaning: Bool, progress: ActionProgress?, result: ActionResult?) {
        isCleaning = cleaning
        self.progress = progress
        lastResult = result
    }

    /// Background tasks the user switched on, for the scheduler.
    public func enabledBackgroundTasks() -> [BackgroundTaskDefinition] {
        guard state == .ready else { return [] }
        let options = settings.optionStore(for: manifest)
        return manifest.backgroundTasks.filter { options.isBackgroundTaskEnabled($0.id) }
    }

    /// Runs the module's automatic cleanup, records what it freed and reads the module again. nil when the module has nothing to
    /// clean, does not take part, or is not ready.
    @discardableResult
    func autoClean() async -> CleanupReport? {
        guard state == .ready, manifest.autoClean == true, let module, !performing else { return nil }
        isCleaning = true
        defer { isCleaning = false }
        let report = await module.autoClean(context: context())
        if let report {
            CleanupHistory.shared.record(moduleID: id, moduleName: manifest.name, freedBytes: report.freedBytes, trigger: .automatic, summary: report.summary)
        }
        await refresh(quiet: true)
        return report
    }

    func runBackgroundTask(_ taskID: String) async {
        guard state == .ready, let module else { return }
        await module.runBackgroundTask(taskID, context: context())
        // A task may have changed something (the Debloat watch switching a feature off again): the tile and page show it.
        await refresh(quiet: true)
    }
}
