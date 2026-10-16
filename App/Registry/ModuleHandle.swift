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
    /// The module is being read, as the user sees it (`isRefreshing`): since when, and how long it took last time. The page's button
    /// fills over that time (`LoadFill`), as it fills while an action runs.
    @Published public private(set) var loading: LoadFill?
    @Published public private(set) var progress: ActionProgress?
    @Published public private(set) var lastResult: ActionResult?
    /// An action the user started from a button (not a switch), or automatic cleanup, is running: the menu bar icon animates, and
    /// the page's charts pulse until the figures after it are in.
    @Published public private(set) var isCleaning = false
    /// The action the user started that is running, for its button's text (`Action.workingTitle`).
    @Published public private(set) var runningAction: Action?
    /// The rows the running action is done with (`ActionProgress.finished`): the page lets them go one after the other. Emptied once
    /// the page is read again after the action.
    @Published public private(set) var finishedRows: Set<String> = []
    /// Bumped when an action the user started succeeded (`ActionResult`): the page shows "All done" in its middle, then a page that
    /// lets the user choose goes back to the one under it.
    @Published public private(set) var allDone = 0
    /// What the action behind the latest `allDone` freed (`ActionResult.freedBytes`): the page counts up to it under "All done".
    public private(set) var allDoneFreed: UInt64?
    /// The group pages open over the module's page (`Row.children`), by id, the top one last; empty on the module's own page. A group
    /// opened from a group's page goes on top of it, and Back returns to the page under it, as everywhere else in the app.
    @Published public var groupPath: [String] = [] {
        // What was chosen on a page is forgotten once the page closes, however it closed (Back, Home, a refresh that dropped it).
        didSet {
            if chosen.keys.contains(where: { !groupPath.contains($0) }) { chosen = chosen.filter { groupPath.contains($0.key) } }
            if chosenAll.keys.contains(where: { !groupPath.contains($0) }) { chosenAll = chosenAll.filter { groupPath.contains($0.key) } }
        }
    }
    /// The group page on top, if any.
    public var openGroup: String? { groupPath.last }

    public func pushGroup(_ id: String) {
        if groupPath.last != id { groupPath.append(id) }
    }

    /// Back from the group page on top, to the one under it or to the module's page.
    public func popGroup() {
        if !groupPath.isEmpty { groupPath.removeLast() }
    }

    /// What the user checked on group pages that let them choose (`Row.selection`), by group id; nil until a box is clicked, when
    /// the module's suggestion (`Selection.checked`) stands.
    @Published public private(set) var chosen: [String: Set<String>] = [:]
    /// The sections whose header box the user turned on or off, by group id (`SelectionSection.all`); nil until one is clicked.
    @Published public private(set) var chosenAll: [String: Set<String>] = [:]

    /// The rows checked on a group's page: the user's choice, or the module's suggestion, among the rows that can still be chosen.
    public func checked(_ group: Row) -> Set<String> {
        guard let selection = group.selection else { return [] }
        return (chosen[group.id] ?? Set(selection.checked)).intersection(selection.choices.keys)
    }

    /// The sections of a group's page whose header box is on.
    public func allChecked(_ group: Row) -> Set<String> {
        guard let selection = group.selection else { return [] }
        return chosenAll[group.id] ?? Set(selection.sections.filter(\.all).map(\.id))
    }

    public func toggle(_ id: String, in group: Row) {
        var ids = checked(group)
        var all = allChecked(group)
        if ids.contains(id) {
            ids.remove(id)
            // A row cleared by hand turns its section's box off: new rows there are no longer checked by themselves.
            for section in group.selection?.sections ?? [] where section.rows.contains(id) { all.remove(section.id) }
        } else {
            ids.insert(id)
        }
        choose(ids, all: all, in: group)
    }

    /// The header box of a section: checks every row of it that can be chosen, or clears them.
    public func toggleAll(_ sectionID: String, in group: Row) {
        guard let selection = group.selection, let section = selection.sections.first(where: { $0.id == sectionID }) else { return }
        var ids = checked(group)
        var all = allChecked(group)
        let rows = Set(section.rows).intersection(selection.choices.keys)
        if all.contains(sectionID) || (!rows.isEmpty && rows.isSubset(of: ids)) {
            ids.subtract(rows)
            all.remove(sectionID)
        } else {
            ids.formUnion(rows)
            all.insert(sectionID)
        }
        choose(ids, all: all, in: group)
    }

    /// Keeps the choice for the page and, when the module keeps it (`Selection.save`), sends it, quietly.
    private func choose(_ ids: Set<String>, all: Set<String>, in group: Row) {
        chosen[group.id] = ids
        chosenAll[group.id] = all
        guard let save = group.selection?.save else { return }
        let parameters = ["ids": Selection.parameter(ids.sorted()), "all": Selection.parameter(all.sorted())]
        Task { await perform(save, extraParameters: parameters, quiet: true) }
    }

    private var preparingForUninstall = false

    func beginUninstall() {
        preparingForUninstall = true
        autoRefresh?.cancel()
        autoRefresh = nil
    }

    func cancelUninstall() { preparingForUninstall = false }

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
        guard !preparingForUninstall else { return }
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
        guard !preparingForUninstall, state == .ready, let module else { return }
        let context = context()
        refreshGeneration += 1
        let generation = refreshGeneration
        let started = Date()
        if !quiet {
            refreshes += 1
            if loading == nil {
                loading = LoadFill(started: started, expected: settings.loadDuration(module: id, reload: reload) ?? LoadFill.firstGuess)
            }
            updateBusy()
        }
        defer {
            if !quiet {
                refreshes -= 1
                if refreshes == 0 { loading = nil }
                updateBusy()
            }
        }
        if reload { await module.invalidate() }
        async let nextTile = module.tile(context: context)
        // What the module says of its progress fills the Loading… button (`LoadFill.reported`).
        let reports: LoadProgressSink = { [weak self] fraction in
            Task { @MainActor in
                guard let self, !quiet, generation == self.refreshGeneration, self.loading != nil,
                      fraction > self.loading?.reported ?? -1 else { return }
                self.loading?.reported = fraction
            }
        }
        async let nextScreen = module.screen(context: context, progress: reports)
        let (newTile, newScreen) = await (nextTile, nextScreen)
        guard generation == refreshGeneration, state == .ready else { return }
        if !quiet { settings.setLoadDuration(Date().timeIntervalSince(started), module: id, reload: reload) }
        lastRefreshed = Date()
        // Only what changed is published: each published value redraws the tile and the page, and the readings that follow the Mac
        // by themselves mostly find it unchanged.
        if tile != newTile {
            tile = newTile
            settings.setLastTile(newTile, module: id)
        }
        if tileIsStale { tileIsStale = false }
        if isWatched, screen != newScreen { screen = newScreen }
        if !isWatched { await module.invalidate() }
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
    /// The same while another app is in front, with MacSpace's window still on screen behind it: a glance at it does not need
    /// the minute's figures, and every module read again each minute (Debloat starts several processes to read the Mac) kept
    /// MacSpace at a few percent of CPU in the background. Coming back to MacSpace reads again the modules whose figures are older
    /// than a minute (`appBecameActive`).
    static let backgroundRefreshInterval: TimeInterval = 600
    static let fastestAutoRefresh: TimeInterval = 3
    /// Whether MacSpace is the app in front; injectable for tests.
    static var isAppActive: @MainActor () -> Bool = { NSApp?.isActive ?? true }
    private var autoRefresh: Task<Void, Never>?
    private var lastRefreshed: Date?
    /// Whether a window of MacSpace is on screen. Without one nobody sees the tile or the page, so the module is not read again by
    /// itself: with the window closed, those readings (a full scan of the disk for System Data, every two minutes) were what kept
    /// MacSpace at 30% CPU in the background.
    public private(set) var isWatched = true

    /// Called by the host when the last window goes away or the first one comes back. Back in view, the module is read again at
    /// once if its figures are old, which also starts the periodic readings again.
    public func setWatched(_ watched: Bool) {
        guard watched != isWatched else { return }
        isWatched = watched
        if !watched {
            autoRefresh?.cancel()
            autoRefresh = nil
            // Keep the compact tile for the menu bar, release the row trees and scan cache.
            screen = nil
            groupPath = []
            Task { [weak self] in
                guard let self, !self.isWatched, !self.performing else { return }
                await self.module?.invalidate()
            }
        } else if state == .ready {
            let age = lastRefreshed.map { Date().timeIntervalSince($0) } ?? .infinity
            if screen == nil || age >= Self.fastestAutoRefresh { Task { await refresh(quiet: true) } } else { scheduleAutoRefresh() }
        }
    }

    /// Back in front: figures older than the usual minute are read again now, and the readings go back to every minute.
    func appBecameActive() {
        guard state == .ready, isWatched else { return }
        let age = lastRefreshed.map { Date().timeIntervalSince($0) } ?? .infinity
        if age >= Self.autoRefreshInterval, !performing { Task { await refresh(quiet: true) } } else { scheduleAutoRefresh() }
    }

    /// Schedules the next quiet reading after the one that just finished.
    private func scheduleAutoRefresh() {
        autoRefresh?.cancel()
        guard state == .ready, isWatched else { return }
        let interval = Self.isAppActive() ? Self.autoRefreshInterval : Self.backgroundRefreshInterval
        // A tile that is changing (`Tile.refreshAfter`) is followed at its own pace, in front or not.
        let delay = max(min(tile?.refreshAfter ?? interval, interval), Self.fastestAutoRefresh)
        autoRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.state == .ready, self.isWatched else { return }
            // Not while an action runs: it reads the module again itself when it ends.
            if self.performing { self.scheduleAutoRefresh() } else { await self.refresh(quiet: true) }
        }
    }

    private func performNow(_ action: Action, extraParameters: [String: String], quiet: Bool) async -> ActionResult? {
        guard !preparingForUninstall, state == .ready, let module else { return nil }
        let missing = action.requires.filter { permissions.status(of: $0) == .missing }
        if !missing.isEmpty {
            // For a switch it counts as failed: nothing changed, so the switch goes back.
            let result = ActionResult(outcome: quiet ? .failed : .needsAttention,
                                      message: String(localized: "Needs \(ListFormatter.localizedString(byJoining: missing.map(\.title)))"),
                                      refresh: false)
            lastResult = result
            return result
        }
        performing = true
        let started = Date()
        if !quiet {
            updateBusy()
            isCleaning = true
            runningAction = action
            finishedRows = []
            progress = nil
        }
        defer {
            if !quiet {
                isCleaning = false
                runningAction = nil
            }
        }
        lastResult = nil
        actionGeneration += 1
        let generation = actionGeneration
        let request = ActionRequest(actionID: action.id, parameters: action.parameters.merging(extraParameters) { _, new in new })
        let result = await module.perform(request, context: context()) { [weak self] update in
            guard !quiet else { return }
            Task { @MainActor in
                guard let self, self.performing, self.actionGeneration == generation else { return }
                self.progress = update
                if !update.finished.isEmpty, Set(update.finished) != self.finishedRows { self.finishedRows = Set(update.finished) }
            }
        }
        // A success the user started is "All done" on the page (`ActionResult`), once its figures are in; anything else is the
        // button's text.
        let celebrates = !quiet && result.outcome == .succeeded && !result.restartRequired && (result.freedBytes != nil || !result.message.isEmpty)
        if (!quiet && !celebrates) || result.outcome != .succeeded || result.restartRequired { lastResult = result }
        // A long action that ends while the user is in another app says so in Notification Center.
        if !quiet { AppNotifications.shared.actionFinished(module: self, message: result.message, took: Date().timeIntervalSince(started)) }
        if let freed = result.freedBytes {
            CleanupHistory.shared.record(moduleID: id, moduleName: manifest.name, freedBytes: freed, trigger: .manual, summary: result.message)
        }
        performing = false
        // "All done" as soon as the work is: reading the Mac again takes seconds of its own (a full scan for System Data). Meanwhile
        // the button stays full and keeps saying what the action did, the charts keep pulsing (`isCleaning`), and the rows the action
        // finished stay gone, until the new figures are in.
        if !quiet {
            if celebrates {
                allDoneFreed = result.freedBytes
                allDone += 1
            }
            if result.refresh { progress = ActionProgress(fraction: 1, message: progress?.message ?? "", finished: progress?.finished ?? []) }
        }
        if result.refresh { await refresh(quiet: true) }
        if !quiet {
            updateBusy()
            progress = nil
            finishedRows = []
        }
        return result
    }

    /// Disabled modules may still own settings from an earlier session.
    func prepareForUninstall() async -> ActionResult {
        guard !isBusy else { return .failed(String(localized: "Working…")) }
        do {
            if module == nil { module = try loader(descriptor) }
            guard let module else { return .failed(manifest.name) }
            return await module.prepareForUninstall(context: context())
        } catch { return .failed(error.localizedDescription) }
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
        guard !preparingForUninstall, state == .ready, manifest.autoClean == true, let module, !performing else { return nil }
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
        guard !preparingForUninstall, state == .ready, let module else { return }
        await module.runBackgroundTask(taskID, context: context())
        // A task may have changed something (the Debloat watch switching a feature off again): the tile and page show it.
        await refresh(quiet: true)
    }
}

/// How far a module's reading has come: what the module says (`MacSpaceModule.screen(context:progress:)`), or, from a module that
/// does not say, the time it took last time.
public struct LoadFill: Equatable, Sendable {
    public var started: Date
    /// How long the module last took to be read.
    public var expected: TimeInterval
    /// What the module reported, 0...1; nil until it does.
    public var reported: Double?
    /// A module never read before.
    static let firstGuess: TimeInterval = 2

    /// What the module reported; or else 0 to just under 1 over the time expected: quick at first, slowing as it nears that time
    /// (about 80% there), never full while the module is still being read, however long it takes.
    public func fraction(at date: Date) -> Double {
        if let reported { return min(max(reported, 0), 1) }
        let elapsed = max(0, date.timeIntervalSince(started)) / max(expected, 0.1)
        return 0.95 * (1 - exp(-1.8 * elapsed))
    }
}
