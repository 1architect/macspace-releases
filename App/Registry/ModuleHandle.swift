import Foundation
import MacSpacePlatform
import MacSpaceSdk
import SwiftUI
import OSLog

private final class FinishedChoiceProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = Set<String>()
    private let allowed: Set<String>?
    init(allowed: Set<String>? = nil) { self.allowed = allowed }
    func record(_ ids: [String]) { lock.withLock { finished.formUnion(allowed.map { Set(ids).intersection($0) } ?? Set(ids)) } }
    var ids: Set<String> { lock.withLock { finished } }
}

/// One module as the app sees it: its manifest, whether it is running, and the latest screen it produced.
@MainActor
public final class ModuleHandle: ObservableObject, Identifiable {
    #if MACSPACE_DEV
    private static let loadLogger = Logger(subsystem: "com.macspace", category: "LoadContinuity")
    #endif
    static func logLoad(_ event: @autoclosure () -> String) {
        #if MACSPACE_DEV
        let message = event()
        loadLogger.notice("\(message, privacy: .public)")
        #endif
    }
    func traceLoad(_ event: @autoclosure () -> String) {
        #if MACSPACE_DEV
        guard id == "com.macspace.disk-map" else { return }
        Self.logLoad("\(event()) gen=\(refreshGeneration) flight=\(readFlight != nil) watched=\(isWatched) windowVisible=\(windowIsVisible) pageVisible=\(screenIsVisible) screen=\(screen != nil) reloading=\(isReloading) refreshing=\(isRefreshing) progress=\(loading?.reported ?? -1)")
        #endif
    }
    public enum State: Equatable {
        case off
        case incompatible(String)
        case failed(String)
        case ready
    }

    public typealias Loader = @Sendable (ModuleDescriptor) throws -> any MacSpaceModule

    public let descriptor: ModuleDescriptor
    public nonisolated var id: String { descriptor.id }
    public var manifest: ModuleManifest { descriptor.manifest }

    @Published public private(set) var state: State
    @Published public private(set) var screen: Screen? { didSet { if oldValue != screen { contractRevision &+= 1 } } }
    @Published public private(set) var tile: Tile? { didSet { if oldValue != tile { contractRevision &+= 1 } } }
    /// The tile is last session's, shown until the module has read the Mac again.
    @Published public private(set) var tileIsStale = false
    @Published public private(set) var isBusy = false
    /// Visible scan feedback; cached navigation verifies without restarting loading effects.
    @Published public private(set) var isRefreshing = false
    /// Only the first page load hides details. Manual and automatic refreshes retain the current page.
    @Published public private(set) var isReloading = false
    /// The module is being read, as the user sees it (`isRefreshing`): since when, and how long it took last time. The page's button
    /// fills over that time (`LoadFill`), as it fills while an action runs.
    @Published public private(set) var loading: LoadFill?
    /// The user asked for the figures again (Refresh): the charts close and open again with the reading (`ChartMotion`).
    @Published public private(set) var isRereading = false
    private var rereadGeneration: Int?
    @Published public private(set) var progress: ActionProgress?
    @Published public private(set) var lastResult: ActionResult?
    /// An action the user started from a page button, or automatic cleanup, is running: the menu bar icon animates, and
    /// block charts use `ChartMotion` until the figures after it are in.
    @Published public private(set) var isCleaning = false
    /// The action the user started that is running, for its button's text (`Action.workingTitle`).
    @Published public private(set) var runningAction: Action?
    @Published public private(set) var runningRowID: String?
    /// Rows whose action waits for the one running: actions run one at a time, and a row clicked meanwhile shows it is taken.
    @Published public private(set) var queuedRows: [String: Action] = [:]
    private var queuedRequestIDs: [String: UUID] = [:]
    /// Each row's result until it is dismissed: another row's action starting no longer clears it.
    @Published public private(set) var rowResults: [String: ActionResult] = [:]
    /// The row given a result last, and that result.
    @Published public private(set) var resultRowID: String?
    public var rowResult: ActionResult? { resultRowID.flatMap { rowResults[$0] } }
    /// The rows the running action is done with (`ActionProgress.finished`): the page lets them go one after the other. Emptied once
    /// the page is read again after the action.
    @Published public private(set) var finishedRows: Set<String> = []
    /// Bumped when an action the user started succeeded (`ActionResult`): the page shows "All done" in its middle, then a page that
    /// lets the user choose goes back to the one under it.
    @Published public private(set) var allDone = 0
    @Published public private(set) var isShowingCompletion = false

    public func dismissCompletion() { isShowingCompletion = false }
    /// What the action behind the latest `allDone` freed (`ActionResult.freedBytes`): the page counts up to it under "All done".
    public private(set) var allDoneFreed: UInt64?
    public private(set) var allDoneRemoved: UInt64?
    /// The group pages open over the module's page (`Row.children`), by id, the top one last; empty on the module's own page. A group
    /// opened from a group's page goes on top of it, and Back returns to the page under it, as everywhere else in the app.
    @Published public var groupPath: [String] = [] {
        // Page-local choices close with their page; explicit session scopes survive navigation.
        didSet {
            cancelRequestedPage()
            invalidatePendingSelections()
            let scopes = [screen?.selection?.scope].compactMap { $0 } + groupPath.compactMap { id in
                pages[id]?.selection?.scope ?? navigationRow(id)?.selection?.scope
            }
            let retained = Set(groupPath + scopes).union(sessionScopes).union(chosen.keys.filter { id in
                screen.flatMap { ScreenView.row(id, in: $0) }?.selection?.save != nil
            })
            chosen = chosen.filter { retained.contains($0.key) }
            chosenAll = chosenAll.filter { retained.contains($0.key) }
            scopedChoices = scopedChoices.filter { retained.contains($0.key) }
            scopedReviewed = scopedReviewed.filter { retained.contains($0.key) }
            scopedOrigins = scopedOrigins.filter { retained.contains($0.key) }
            ephemeralScopes.formIntersection(retained)
        }
    }
    /// The group page on top, if any.
    public var openGroup: String? { groupPath.last }

    private var durableChoiceScopes: Set<String> = []
    @Published public private(set) var pages: [String: Screen] = [:] { didSet { if oldValue != pages { contractRevision &+= 1 } } }
    private var contractRevision: UInt64 = 0
    private var moduleEpoch = UUID()
    private var openingPage: Task<Void, Never>?
    private var pageIDs: [String: String] = [:]
    private var pageUse: [String] = []
    private var viewStates: [String: ModulePageViewState] = [:]
    private var viewStateUse: [String] = []

    func pageViewState(_ id: String) -> ModulePageViewState {
        let value = viewStates[id] ?? ModulePageViewState()
        viewStates[id] = value
        viewStateUse.removeAll { $0 == id }; viewStateUse.append(id)
        while viewStates.count > max(12, groupPath.count + 1),
              let oldest = viewStateUse.first(where: { $0 != "screen:root" && $0 != id && !groupPath.contains($0) }) {
            viewStates[oldest] = nil; viewStateUse.removeAll { $0 == oldest }
        }
        return value
    }

    private func retainPage(_ id: String) {
        pageUse.removeAll { $0 == id }; pageUse.append(id)
        while pages.count > max(12, groupPath.count + 1), let oldest = pageUse.first(where: { !groupPath.contains($0) && $0 != id }) {
            pageUse.removeAll { $0 == oldest }; pages.removeValue(forKey: oldest); pageIDs.removeValue(forKey: oldest)
        }
    }
    private func invalidateClosedPages() {
        let active = Set(groupPath)
        pages = pages.filter { active.contains($0.key) }
        pageIDs = pageIDs.filter { active.contains($0.key) }
        pageUse.removeAll { !active.contains($0) }
    }

    /// Resolve synthetic folder maps through the existing stack; their segments always keep module destinations.
    public func graphPage(_ id: String) -> Screen? {
        guard id.hasPrefix("graph:"), id.hasSuffix(":" + BlockLayout.foldersID), let screen else { return nil }
        var sources = [screen]
        for key in groupPath {
            if let found = sources.lazy.compactMap({ ScreenView.graphPage(id, in: $0) }).first { return found }
            if let page = pages[key] { sources.append(page) }
            else if let page = sources.lazy.compactMap({ ScreenView.graphPage(key, in: $0) }).first { sources.append(page) }
        }
        return sources.lazy.compactMap { ScreenView.graphPage(id, in: $0) }.first
    }

    public func navigationRow(_ id: String) -> Row? {
        if let graph = graphPage(id) { return Row(id: id, title: graph.title) }
        if let page = pages[id] { return Row(id: id, title: page.title, pageID: pageIDs[id] ?? id) }
        if let screen, let row = ScreenView.row(id, in: screen) { return row }
        if let row = pages.values.lazy.compactMap({ ScreenView.row(id, in: $0) }).first { return row }
        return groupPath.lazy.compactMap { self.graphPage($0) }.compactMap { ScreenView.row(id, in: $0) }.first
    }

    @Published public private(set) var pageLoading: LoadFill?
    private var pageLoadGeneration = 0
    private var pageRequests = Set<Int>()
    private func loadPage(_ id: String) async -> Screen? {
        guard let module else { return nil }
        pageLoadGeneration += 1
        let generation = pageLoadGeneration
        let started = Date()
        pageRequests.insert(generation)
        defer {
            pageRequests.remove(generation)
            if generation == pageLoadGeneration { pageLoadGeneration += 1; pageLoading = nil; updateBusy() }
            requestModuleActivityUpdate()
            scheduleAutoRefresh()
        }
        await syncModuleActivity()
        guard generation == pageLoadGeneration, state == .ready, !Task.isCancelled else { return nil }
        let reports = LoadProgressRelay()
        reports.attach { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.pageLoadGeneration == generation, self.screenIsVisible else { return }
                if fraction < 1, self.pageLoading == nil {
                    self.pageLoading = LoadFill(started: started, expected: LoadFill.firstGuess)
                    self.updateBusy()
                }
                guard fraction > self.pageLoading?.reported ?? -1 else { return }
                self.pageLoading?.reported = fraction
            }
        }
        return await module.page(id: id, context: context(), progress: { if $0.isFinite { reports.report($0) } })
    }
    private var requestedPage: String?
    private var requestedPageGeneration = 0
    private func cancelRequestedPage() { requestedPageGeneration += 1; requestedPage = nil }
    public func requestPage(_ id: String) {
        cancelRequestedPage()
        invalidatePendingSelections()
        requestedPage = id
        if screen != nil && screenIsVisible { Task { await openRequestedPage() } }
    }
    private func openRequestedPage() async {
        guard let id = requestedPage, let module, screenIsVisible, state == .ready else { return }
        let generation = requestedPageGeneration, parent = groupPath, action = actionGeneration, reading = refreshGeneration
        guard let page = await preparedPage(await loadPage(id)), requestedPage == id,
              generation == requestedPageGeneration, parent == groupPath, state == .ready, screenIsVisible,
              action == actionGeneration, reading == refreshGeneration else { return }
        reconcileSelection(page)
        requestedPage = nil; pages[id] = page; pageIDs[id] = id; retainPage(id)
        withAnimation(Theme.push) { groupPath.append(id) }
        scheduleAutoRefresh()
    }
    @Published public private(set) var focusedRowID: String?
    public func pushGroup(_ id: String) {
        if id.hasPrefix("focus:") {
            openingPage?.cancel()
            let parent = groupPath
            openingPage = Task { [weak self] in
                guard let self, let page = await self.preparedPage(await self.loadPage(id)), !Task.isCancelled,
                      self.groupPath == parent, self.state == .ready, self.screenIsVisible else { return }
                self.reconcileSelection(page)
                if let current = parent.last { self.pages[current] = page; self.pageIDs[current] = id } else { self.screen = page }
                self.scheduleAutoRefresh()
                self.focusedRowID = nil
                if let data = Data(base64Encoded: String(id.dropFirst("focus:browse:".count))),
                   let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let path = payload["focusPath"] as? String {
                    self.focusedRowID = "file:" + Data(path.utf8).base64EncodedString()
                }
            }
            return
        }
        guard groupPath.last != id else { return }
        cancelRequestedPage()
        invalidatePendingSelections()
        guard let row = navigationRow(id), let pageID = row.pageID else { groupPath.append(id); return }
        let replacement = row.replacesPage ? groupPath.last : nil
        if pageID.hasPrefix("module:") {
            let parts = pageID.dropFirst(7).split(separator: "/", maxSplits: 1).map(String.init)
            if let module = parts.first { AppRouter.shared.open(.module(module), page: parts.count == 2 ? parts[1] : nil) }
            return
        }
        openingPage?.cancel()
        if replacement == nil, pages[id] != nil {
            retainPage(id)
            withAnimation(Theme.push) { groupPath.append(id) }
            return
        }
        let parent = groupPath, action = actionGeneration, navigation = requestedPageGeneration
        // Rows and graph are prepared together before the existing page transition starts.
        openingPage = Task { [weak self] in
            guard let self, let page = await self.preparedPage(await self.loadPage(pageID)),
                  !Task.isCancelled, self.groupPath == parent, self.actionGeneration == action,
                  self.requestedPageGeneration == navigation, self.state == .ready, self.screenIsVisible else { return }
            self.reconcileSelection(page)
            self.pageIDs[id] = pageID
            self.pages[id] = page
            self.retainPage(id)
            withAnimation(Theme.push) {
                if replacement != nil { self.groupPath[self.groupPath.count - 1] = id }
                else { self.groupPath.append(id) }
            }
            self.scheduleAutoRefresh()
        }
    }

    private func preparedPage(_ page: Screen?) async -> Screen? {
        guard var page, let selection = page.selection, let scope = selection.scope,
              let prefix = selection.bulkResolver, let bulk = sessionBulk[scope], let module else { return page }
        let request = SelectionBulkRequest(token: bulk.token, operation: "membership", visible: selection.choices.keys.sorted(), sections: selection.sections.compactMap(\.pageID))
        guard let resolved = await module.page(id: requestPageID(request, prefix: prefix), context: context()), let resolvedSnapshot = resolved.selection?.bulk else { return nil }
        guard sessionBulk[scope]?.token == bulk.token else { return await preparedPage(page) }
        var snapshot = resolvedSnapshot
        snapshot.unavailableReason = bulk.unavailableReason
        snapshot.issues = bulk.issues
        if let issues = snapshot.issues, !issues.isEmpty {
            var extra: [Row] = []
            for issue in issues {
                page.selection?.choices[issue.id] = issue.bytes
                if !snapshot.checked.contains(issue.id) { snapshot.checked.append(issue.id) }
                if ScreenView.row(issue.id, in: page) == nil {
                    extra.append(Row(id: issue.id, title: issue.title, trailing: ByteFormat.string(issue.bytes), paths: [issue.path], unavailableReason: issue.reason))
                }
            }
            if !extra.isEmpty { page.widgets.insert(.list(ListWidget(id: "selection-issues", title: String(localized: "Selected files need review"), rows: extra)), at: 0) }
        }
        page.selection?.bulk = snapshot
        return page
    }

    private func refreshPages(all: Bool = false) async {
        guard let module else { return }
        let reading = refreshGeneration, action = actionGeneration, navigation = requestedPageGeneration
        for id in (all ? groupPath : Array(groupPath.suffix(1))) where pages[id] != nil {
            let destination = pageIDs[id] ?? id
            let page = await preparedPage(await module.page(id: destination, context: context()))
            guard state == .ready, reading == refreshGeneration, action == actionGeneration,
                  navigation == requestedPageGeneration, (pageIDs[id] ?? id) == destination else { return }
            if let position = groupPath.firstIndex(of: id), page == nil {
                pages.removeValue(forKey: id)
                groupPath = Array(groupPath.prefix(position))
                break
            }
            if let page { reconcileSelection(page) }
            if groupPath.contains(id), pages[id] != page { pages[id] = page }
        }
    }

    /// Back from the group page on top, to the one under it or to the module's page.
    public func popGroup() {
        cancelRequestedPage()
        openingPage?.cancel()
        if !groupPath.isEmpty { groupPath.removeLast() }
    }

    /// A breadcrumb names an ancestor already in the stack; retain its page and choices.
    public func navigateToAncestor(depth: Int) {
        guard depth >= 0, depth < groupPath.count else { return }
        cancelRequestedPage()
        openingPage?.cancel()
        withAnimation(Theme.push) { groupPath = Array(groupPath.prefix(depth)) }
    }

    /// What the user checked on group pages that let them choose (`Row.selection`), by group id; nil until a box is clicked, when
    /// the module's suggestion (`Selection.checked`) stands.
    @Published public private(set) var chosen: [String: Set<String>] = [:]
    /// The sections whose header box the user turned on or off, by group id (`SelectionSection.all`); nil until one is clicked.
    @Published public private(set) var chosenAll: [String: Set<String>] = [:]
    private var scopedChoices: [String: [String: UInt64]] = [:]
    private var ephemeralScopes = Set<String>()
    /// Per-visit overrides for cleanup operations whose consent is never stored in preferences.
    var transientCleanupChoices: [String: (selected: Bool, defaultSelected: Bool)] = [:]
    private var sessionScopes = Set<String>()
    private var scopedReviewed: [String: [String: String]] = [:]
    private var scopedOrigins: [String: [String: String]] = [:]
    @Published private var sessionBulk: [String: SelectionBulk] = [:]
    private var bulkVisible: [String: Set<String>] = [:]
    @Published private var bulkMembershipRevision = 0
    private var bulkSections: [String: Set<String>] = [:]
    private var bulkEdit: Task<Void, Never>?
    private var sessionGroup: Row?
    @Published private var selectingSections = Set<String>()
    public var isSelectingFiles: Bool { !selectingSections.isEmpty }
    private struct PendingFileToggle {
        var key: UUID
        var id: String
        var bytes: UInt64
    }
    @Published private var pendingFileToggles: [String: [PendingFileToggle]] = [:]
    public var isEditingSelection: Bool { isSelectingFiles || pendingFileToggles.values.contains { !$0.isEmpty } }
    private var selectionGeneration = 0
    private func invalidatePendingSelections() {
        selectionGeneration += 1
        selectingSections.removeAll()
        pendingFileToggles.removeAll()
    }
    private var sessionSections: [String: [String: Set<String>]] = [:]
    private var sessionSectionPages: [String: [String: String]] = [:]

    /// A page-wide selection and a legacy choosing group share one renderer and action dock.
    public func pageSelection(_ page: Screen, id: String) -> Row? {
        guard var selection = page.selection ?? cleanupSelection(page.cleanupTargets) else { return nil }
        func addHeaders(_ widgets: [ScreenWidget]) {
            for widget in widgets {
                if case let .list(list) = widget, list.title != nil,
                   !selection.sections.contains(where: { $0.id == list.id }),
                   list.rows.contains(where: { selection.choices[$0.id] != nil }) {
                    selection.sections.append(.init(id: list.id, title: list.title ?? page.title, rows: list.rows.map(\.id)))
                }
                if case let .section(section) = widget { addHeaders(section.widgets) }
            }
        }
        addHeaders(page.widgets)
        func rows(_ widgets: [ScreenWidget]) -> [Row] {
            widgets.flatMap { widget -> [Row] in
                if case let .list(list) = widget { return list.rows }
                if case let .section(section) = widget { return rows(section.widgets) }
                return []
            }
        }
        return selectionGroup(Row(id: id, title: page.title, children: rows(page.widgets), selection: selection))
    }
    public func selectionGroup(_ group: Row) -> Row {
        var group = group
        if group.selection == nil { group.selection = cleanupSelection(cleanupTargets(in: group.children)) }
        guard var selection = group.selection else { return group }
        if let key = selection.persistenceKey {
            selection.scope = selection.scope ?? "persistent:" + id + ":" + key
            group.selection = selection
        }
        if selection.save != nil || selection.persistenceKey != nil { durableChoiceScopes.insert(selection.scope ?? group.id) }
        guard let scope = selection.scope else { return group }
        group.id = scope
        if selection.partial || selection.session {
            let visible = Set(group.children.map(\.id))
            let retained = (scopedChoices[scope] ?? [:]).filter { !visible.contains($0.key) || selection.choices[$0.key] != nil }
            let session = selection.session
            selection.choices.merge(retained) { current, original in session ? original : current }
            selection.reviewed.merge(scopedReviewed[scope] ?? [:]) { _, original in original }
            selection.origins.merge(scopedOrigins[scope] ?? [:]) { _, original in original }
        }
        if let bulk = sessionBulk[scope] { selection.bulk = bulk }
        if let pending = pendingFileToggles[scope], !pending.isEmpty {
            let explicit = chosen[scope] ?? []
            var display = selection.bulk ?? SelectionBulk(token: "", count: UInt64(explicit.count),
                bytes: explicit.compactMap { selection.choices[$0] }.reduce(0, +), checked: Array(explicit))
            var checked = Set(display.checked)
            for edit in pending {
                if checked.remove(edit.id) != nil {
                    display.count -= min(display.count, 1); display.bytes -= min(display.bytes, edit.bytes)
                } else {
                    checked.insert(edit.id); display.count += 1; display.bytes += edit.bytes
                }
            }
            display.checked = checked.sorted(); display.all = []
            selection.bulk = display
        }
        group.selection = selection
        return group
    }
    public var activeSelection: Row? {
        if let id = groupPath.last {
            if let page = pages[id], let selection = pageSelection(page, id: id) { return selection }
            if let group = navigationRow(id), group.selection != nil || !cleanupTargets(in: group.children).isEmpty { return selectionGroup(group) }
        } else if let screen, let selection = pageSelection(screen, id: "screen:root") { return selection }
        return sessionGroup.map { group in
            var group = group
            group.children = []
            group.selection?.choices = scopedChoices[group.id] ?? [:]
            group.selection?.reviewed = scopedReviewed[group.id] ?? [:]
            group.selection?.origins = scopedOrigins[group.id] ?? [:]
            return selectionGroup(group)
        }
    }
    public func clearPageSelections() {
        transientCleanupChoices.removeAll()
        for scope in ephemeralScopes where !sessionScopes.contains(scope) {
            chosen.removeValue(forKey: scope); chosenAll.removeValue(forKey: scope); scopedChoices.removeValue(forKey: scope)
        }
        ephemeralScopes.removeAll()
        for page in ([screen].compactMap { $0 } + Array(pages.values)) {
            if let selection = page.selection, selection.save == nil, !selection.session, let scope = selection.scope {
                chosen.removeValue(forKey: scope); chosenAll.removeValue(forKey: scope)
                scopedChoices.removeValue(forKey: scope)
            }
        }
    }

    /// The rows checked on a group's page: the user's choice, or the module's suggestion, among the rows that can still be chosen.
    public func checked(_ group: Row) -> Set<String> {
        guard let selection = group.selection else { return [] }
        if let key = selection.persistenceKey {
            let preferences = settings.cleanupChoices(module: id)
            if key == "cleanup" {
                let targets = currentCleanupTargets
                return Set(targets.filter { selection.choices[$0.id] != nil && cleanupIsSelected($0, preferences: preferences) }.map(\.id))
            }
            return Set(selection.choices.keys.filter { preferences[CleanupTarget.preferenceKey(scope: key, id: $0)] ?? selection.checked.contains($0) })
        }
        if let bulk = selection.bulk { return Set(bulk.checked).intersection(selection.choices.keys) }
        return selection.effectiveIDs(storedChecked(group))
    }

    private func storedChecked(_ group: Row) -> Set<String> {
        guard let selection = group.selection else { return [] }
        if selection.persistenceKey != nil { return checked(group) }
        return (chosen[group.id] ?? (selection.session ? [] : Set(selection.checked))).intersection(selection.choices.keys)
    }

    /// The sections of a group's page whose header box is on.
    public func allChecked(_ group: Row) -> Set<String> {
        guard let selection = group.selection else { return [] }
        if let bulk = selection.bulk {
            return Set(selection.sections.filter { $0.pageID.map(Set(bulk.all).contains) == true }.map(\.id))
        }
        guard selection.session else {
            let all = chosenAll[group.id] ?? Set(selection.sections.filter(\.all).map(\.id))
            guard !selection.parents.isEmpty else { return all }
            let checked = checked(group)
            return Set(selection.sections.filter { all.contains($0.id) && Set($0.rows).intersection(selection.choices.keys).isSubset(of: checked) }.map(\.id))
        }
        let ids = checked(group)
        return Set(selection.sections.compactMap { section in
            guard let pageID = section.pageID,
                  sessionSectionPages[group.id]?[section.id] == pageID,
                  let rows = sessionSections[group.id]?[section.id], !rows.isEmpty,
                  rows.isSubset(of: ids) else { return nil }
            return section.id
        })
    }

    public func toggle(_ id: String, in group: Row) {
        guard group.selection?.choices[id] != nil else { return }
        if group.selection?.bulkResolver != nil {
            queueBulkChange("toggle", in: group, toggledID: id)
            return
        }
        var ids = storedChecked(group)
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
        guard section.unavailableReason == nil else { return }
        if selection.bulkResolver != nil {
            queueBulkChange("toggleAll", in: group, scopePageID: section.pageID, ids: section.pageID == nil ? section.rows : [])
            return
        }
        if let pageID = section.pageID {
            let key = group.id + ":" + sectionID
            let cancel = selectingSections.contains(key)
            invalidatePendingSelections()
            guard !cancel else { return }
            selectingSections.insert(key)
            let generation = selectionGeneration
            Task { [weak self] in
                guard let self else { return }
                defer { if self.selectionGeneration == generation { self.selectingSections.remove(key) } }
                guard let page = await self.module?.page(id: pageID, context: self.context()),
                      let inventory = page.selection, inventory.scope == selection.scope else {
                    if self.state == .ready, self.selectionGeneration == generation {
                        self.lastResult = .failed(String(localized: "This selection is unavailable. Refresh and try again."))
                    }
                    return
                }
                guard self.state == .ready, self.screenIsVisible, self.selectionGeneration == generation else { return }
                var resolved = selection
                resolved.choices = inventory.choices
                resolved.reviewed = inventory.reviewed
                resolved.origins = inventory.origins
                resolved.sections = [.init(id: sectionID, title: section.title, rows: Array(inventory.choices.keys))]
                self.sessionSections[group.id, default: [:]][sectionID] = Set(inventory.choices.keys)
                self.sessionSectionPages[group.id, default: [:]][sectionID] = pageID
                var complete = group; complete.children = []; complete.selection = resolved
                self.toggleAll(sectionID, in: self.selectionGroup(complete))
            }
            return
        }
        var ids = storedChecked(group)
        var all = allChecked(group)
        let rows = Set(section.rows).intersection(selection.choices.keys)
        let previous = ids
        if (!selection.session && all.contains(sectionID)) || (!rows.isEmpty && rows.isSubset(of: ids)) {
            ids.subtract(rows)
            all.remove(sectionID)
        } else {
            ids.formUnion(rows)
            all.insert(sectionID)
        }
        // Clearing a nested category also clears overlapping select-all flags.
        // Otherwise its app heading stays checked and the next click cannot select all.
        let removed = previous.subtracting(ids)
        if !removed.isEmpty {
            for section in selection.sections where !Set(section.rows).isDisjoint(with: removed) { all.remove(section.id) }
        }
        choose(ids, all: all, in: group)
    }

    /// Visible checkbox membership comes from the frozen snapshot, never from a live category predicate.
    public func choosableIDs(_ group: Row) -> Set<String> {
        guard let selection = group.selection else { return [] }
        let ids = Set(selection.choices.keys)
        guard group.selection?.bulk != nil else { return ids }
        return ids
    }

    public var bulkMembershipKey: [String] {
        guard !performing, !isCleaning, !isEditingSelection else { return [] }
        guard let group = activeSelection, let bulk = group.selection?.bulk else { return [] }
        return [bulk.token, String(bulkMembershipRevision)] + groupPath + (group.selection?.choices.keys.sorted() ?? [])
    }

    public func refreshBulkMembership() async {
        guard !performing, !isCleaning, !isEditingSelection else { return }
        guard let group = activeSelection, let selection = group.selection,
              let bulk = selection.bulk, let prefix = selection.bulkResolver else { return }
        let visible = Set(selection.choices.keys), sections = Set(selection.sections.compactMap(\.pageID))
        guard !visible.isSubset(of: bulkVisible[group.id] ?? []) || !sections.isSubset(of: bulkSections[group.id] ?? []) else { return }
        let generation = selectionGeneration
        let request = SelectionBulkRequest(token: bulk.token, visible: visible.sorted(), sections: sections.sorted())
        guard let page = await module?.page(id: requestPageID(request, prefix: prefix), context: context()),
              let snapshot = page.selection?.bulk else {
            if selectionGeneration == generation, state == .ready {
                lastResult = .failed(String(localized: "This selection is unavailable. Refresh and try again."))
            }
            return
        }
        guard snapshot.token == bulk.token, selectionGeneration == generation,
              sessionBulk[group.id]?.token == bulk.token, state == .ready, !performing, !isCleaning else { return }
        bulkVisible[group.id] = visible; bulkSections[group.id] = sections
        sessionBulk[group.id] = snapshot
    }

    private func requestPageID(_ request: SelectionBulkRequest, prefix: String) -> String {
        prefix + String(request.pageID.dropFirst("selection:".count))
    }

    /// Serial edits use the last accepted token. Navigation and actions invalidate their whole pending generation.
    private func queueBulkChange(_ operation: String, in group: Row, scopePageID: String? = nil,
                                 toggledID: String? = nil, ids: [String] = []) {
        guard let selection = group.selection, let prefix = selection.bulkResolver else { return }
        let key = group.id + ":" + (scopePageID ?? toggledID ?? ids.joined(separator: "\n"))
        if operation == "toggleAll" {
            let cancel = selectingSections.contains(key)
            invalidatePendingSelections()
            guard !cancel else { return }
            selectingSections.insert(key)
        } else if !selectingSections.isEmpty { invalidatePendingSelections() }
        let pendingKey = UUID()
        if operation == "toggle", let id = toggledID, let bytes = selection.choices[id] {
            pendingFileToggles[group.id, default: []].append(.init(key: pendingKey, id: id, bytes: bytes))
        }
        let generation = selectionGeneration, previous = bulkEdit
        bulkEdit = Task { [weak self] in
            await previous?.value
            guard let self, self.selectionGeneration == generation, self.state == .ready else { return }
            defer {
                if self.selectionGeneration == generation { self.selectingSections.remove(key) }
                self.pendingFileToggles[group.id]?.removeAll { $0.key == pendingKey }
            }
            let current = self.sessionBulk[group.id]
            let explicit = current == nil ? Array(self.chosen[group.id] ?? []).sorted() : ids
            let request = SelectionBulkRequest(token: current?.token, operation: operation, scopePageID: scopePageID,
                toggledID: toggledID, ids: explicit.isEmpty ? ids : explicit,
                reviewed: selection.reviewed, origins: selection.origins,
                visible: selection.choices.keys.sorted(), sections: selection.sections.compactMap(\.pageID))
            guard let page = await self.module?.page(id: self.requestPageID(request, prefix: prefix), context: self.context()),
                  let snapshot = page.selection?.bulk, page.selection?.scope == selection.scope else {
                if self.selectionGeneration == generation, self.state == .ready {
                    self.lastResult = .failed(String(localized: "This selection is unavailable. Refresh and try again."))
                }
                return
            }
            guard self.selectionGeneration == generation, self.state == .ready, self.screenIsVisible else { return }
            self.sessionScopes.insert(group.id)
            var template = group; template.children = []
            template.selection?.choices = [:]; template.selection?.reviewed = [:]; template.selection?.origins = [:]
            template.selection?.sections = []; template.selection?.bulk = snapshot
            self.sessionGroup = template
            self.chosen[group.id] = []; self.scopedChoices[group.id] = [:]
            self.scopedReviewed[group.id] = [:]; self.scopedOrigins[group.id] = [:]
            self.bulkVisible[group.id] = Set(request.visible); self.bulkSections[group.id] = Set(request.sections)
            self.sessionBulk[group.id] = snapshot
        }
    }

    /// Keeps the choice for the page and, when the module keeps it (`Selection.save`), sends it, quietly.
    private func choose(_ ids: Set<String>, all: Set<String>, in group: Row) {
        invalidatePendingSelections()
        if let selection = group.selection, let key = selection.persistenceKey {
            var visible = Set(selection.choices.keys)
            if key == "cleanup" {
                for target in currentCleanupTargets where visible.contains(target.id) && !target.remembersSelection {
                    transientCleanupChoices[target.id] = (ids.contains(target.id), target.defaultSelected)
                    visible.remove(target.id)
                }
            }
            settings.saveCleanupChoices(module: id, scope: key, visible: visible, selected: ids)
            settings.saveCleanupChoices(module: id, scope: key + ":sections", visible: Set(selection.sections.map(\.id)), selected: all)
            durableChoiceScopes.insert(group.id)
            chosen[group.id] = ids; chosenAll[group.id] = all
            if selection.save == nil { return }
        }
        if let selection = group.selection, selection.scope != nil, selection.save == nil {
            if selection.session {
                sessionScopes.insert(group.id)
                var template = group; template.children = []
                template.selection?.choices = [:]; template.selection?.reviewed = [:]; template.selection?.origins = [:]
                template.selection?.sections = []
                sessionGroup = template
            }
            else { ephemeralScopes.insert(group.id) }
            if selection.partial || selection.session {
                scopedChoices[group.id] = selection.choices.filter { ids.contains($0.key) }
                scopedReviewed[group.id] = selection.reviewed.filter { ids.contains($0.key) }
                scopedOrigins[group.id] = selection.origins.filter { ids.contains($0.key) }
            }
        }
        chosen[group.id] = ids
        chosenAll[group.id] = group.selection?.session == true ? [] : all
        guard let save = group.selection?.save else { return }
        let parameters = ["ids": Selection.parameter(ids.sorted()), "all": Selection.parameter(all.sorted())]
        Task { await perform(save, extraParameters: parameters, quiet: true) }
    }

    /// A refreshed visible row that loses eligibility cannot reappear in the retained selection later.
    private func reconcileSelection(_ page: Screen) {
        if let selection = page.selection, let scope = selection.scope, let bulk = selection.bulk {
            sessionBulk[scope] = bulk
            bulkVisible[scope] = Set(selection.choices.keys)
            bulkSections[scope] = Set(selection.sections.compactMap(\.pageID))
        }
        func reconcile(_ selection: Selection?, rows: [Row]) {
            guard let selection, selection.session, let scope = selection.scope else { return }
            let invalid = Set(rows.map(\.id)).subtracting(selection.choices.keys)
            guard !invalid.isEmpty else { return }
            scopedChoices[scope] = scopedChoices[scope]?.filter { !invalid.contains($0.key) }
            scopedReviewed[scope] = scopedReviewed[scope]?.filter { !invalid.contains($0.key) }
            scopedOrigins[scope] = scopedOrigins[scope]?.filter { !invalid.contains($0.key) }
            chosen[scope]?.subtract(invalid)
        }
        func rows(_ widgets: [ScreenWidget]) -> [Row] {
            widgets.flatMap { widget -> [Row] in
                if case let .list(list) = widget { return list.rows }
                if case let .section(section) = widget { return rows(section.widgets) }
                return []
            }
        }
        reconcile(page.selection, rows: rows(page.widgets))
        for segment in page.hero?.segments ?? [] { reconcile(segment.selection, rows: segment.items) }
    }

    private func forgetFinishedChoices(_ ids: Set<String>) {
        for target in currentCleanupTargets where ids.contains(target.id) && !target.remembersSelection {
            transientCleanupChoices[target.id] = (target.defaultSelected, target.defaultSelected)
        }
        if !ids.isEmpty {
            bulkMembershipRevision += 1
            for scope in sessionBulk.keys {
                bulkVisible[scope] = []; bulkSections[scope] = []
            }
        }
        for scope in Array(scopedChoices.keys) {
            scopedChoices[scope] = scopedChoices[scope]?.filter { !ids.contains($0.key) }
        }
        for scope in Array(chosen.keys) where !durableChoiceScopes.contains(scope) {
            chosen[scope]?.subtract(ids)
        }
        for scope in Array(scopedReviewed.keys) { scopedReviewed[scope] = scopedReviewed[scope]?.filter { !ids.contains($0.key) } }
        for scope in Array(scopedOrigins.keys) { scopedOrigins[scope] = scopedOrigins[scope]?.filter { !ids.contains($0.key) } }
    }

    private var preparingForUninstall = false

    func beginUninstall() {
        cancelHiddenReadGrace()
        invalidatePendingSelections()
        preparingForUninstall = true
        autoRefresh?.cancel()
        autoRefresh = nil
    }

    func cancelUninstall() { preparingForUninstall = false }

    private var module: (any MacSpaceModule)?
    private var activityTask: Task<Void, Never>?
    private var activityGeneration = 0
    private var appliedModuleActivity: Bool?
    private var hasCurrentRefresh: Bool { readFlight != nil || refreshRequests.contains(refreshGeneration) }
    private var hasPendingReads: Bool { hasCurrentRefresh || !pageRequests.isEmpty }
    private var needsModuleActivity: Bool {
        !preparingForUninstall && state == .ready && isEnabled && (actionNeedsModuleActivity || performing ||
            (windowIsVisible && (Self.isAppActive() || hasPendingReads)) || (finishingHiddenRead && hasPendingReads))
    }

    /// Module visibility controls polling; window visibility controls backend lifetime and in-flight reads.
    /// Serialize/coalesce updates so a queued old suspension cannot cancel a newer foreground read.
    private func syncModuleActivity() async {
        if finishingHiddenRead, !hasPendingReads {
            traceLoad("hidden-read-finished")
            cancelHiddenReadGrace()
        }
        guard let module else { return }
        activityGeneration += 1
        let generation = activityGeneration, previous = activityTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.activityGeneration == generation else { return }
            let active = self.needsModuleActivity
            guard self.appliedModuleActivity != active else { return }
            self.traceLoad("activity active=\(active) appActive=\(Self.isAppActive())")
            await module.setActive(active)
            self.appliedModuleActivity = active
        }
        activityTask = task
        while let pending = activityTask {
            let observed = activityGeneration
            await pending.value
            if observed == activityGeneration { activityTask = nil }
        }
    }
    private func requestModuleActivityUpdate() {
        Task { @MainActor [weak self] in await self?.syncModuleActivity() }
    }
    /// Refreshes under way, and whether an action is running: both make the module busy.
    private var refreshes: Set<Int> = []
    private var blockingRefreshes: Set<Int> = []
    private var refreshRequests: Set<Int> = []
    private var loadingGeneration: Int?
    private var performing = false
    private var actionNeedsModuleActivity = false
    /// Bumped by each refresh: a slower, older one that finishes last must not put back figures older than the newest.
    private var refreshGeneration = 0
    /// Bumped by each action: a progress message that arrives after its action finished must not show again.
    private var actionGeneration = 0
    let settings: SettingsStore
    private let permissions: any PermissionChecker
    private let privileged: (any PrivilegedChannel)?
    private let loader: Loader
    private struct ModuleLoad {
        let id = UUID()
        let task: Task<any MacSpaceModule, Error>
    }
    private var moduleLoad: ModuleLoad?
    /// Opens a System Settings pane; the tests keep System Settings closed.
    private let openPane: @Sendable (URL) -> Void
    private let confirm: @MainActor (Action) -> Bool

    public init(confirm: @escaping @MainActor (Action) -> Bool = ConfirmationAlert.ask, descriptor: ModuleDescriptor, settings: SettingsStore, permissions: any PermissionChecker,
                privileged: (any PrivilegedChannel)? = nil, loader: @escaping Loader = ModuleLoader.load,
                openPane: @escaping @Sendable (URL) -> Void = SettingsPane.open) {
        self.confirm = confirm
        self.descriptor = descriptor
        self.settings = settings
        self.permissions = permissions
        self.privileged = privileged
        self.loader = loader
        self.openPane = openPane
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
        ModuleContext(manifest: manifest, options: settings.optionStore(for: manifest), permissions: permissions, privileged: privileged,
                      services: AppModuleServices(module: id, openPane: openPane), cleanupChoices: settings.cleanupChoices(module: id))
    }

    public func missingPermissions() -> [Permission] {
        manifest.permissions.filter { permissions.status(of: $0) != .granted }
    }

    private func loadModule() async throws {
        guard module == nil else { return }
        // Bundle loading and module initialization can touch disk and Keychain. Keep that work off the UI thread,
        // and let concurrent activations join it rather than constructing separate stores and observers.
        if moduleLoad == nil {
            let loader = self.loader, descriptor = self.descriptor
            moduleLoad = ModuleLoad(task: Task.detached(priority: .userInitiated) { try loader(descriptor) })
        }
        let pending = moduleLoad!
        do {
            let loaded = try await pending.task.value
            if module == nil { module = loaded; moduleEpoch = UUID() }
            if moduleLoad?.id == pending.id { moduleLoad = nil }
        } catch {
            if moduleLoad?.id == pending.id { moduleLoad = nil }
            throw error
        }
    }

    /// Loads the module (once) when it is enabled and compatible, then fetches its tile and screen.
    public func activate() async {
        guard !preparingForUninstall else { return }
        if case .incompatible = state { return }
        guard isEnabled else { deactivate(); return }
        do { try await loadModule() }
        catch {
            guard isEnabled, !preparingForUninstall, module == nil, moduleLoad == nil else { return }
            state = .failed(error.localizedDescription)
            // Last session's tile stays, but nothing will refresh it: it must not show as loading (and animate) forever.
            tileIsStale = false
            return
        }
        guard isEnabled, !preparingForUninstall, !Task.isCancelled else { return }
        state = .ready
        if isWatched, !deferDashboardWarmup() { await refresh() }
    }

    /// Drops the module's UI state. The loaded code stays in memory (bundles cannot be unloaded safely); it is simply not called.
    public func deactivate() {
        cancelRequestedPage()
        invalidatePendingSelections()
        if case .incompatible = state { return }
        cancelHiddenReadGrace()
        requestModuleActivityUpdate()
        pageLoadGeneration += 1; pageLoading = nil
        readFlight = nil
        dashboardWarmup?.cancel(); dashboardWarmup = nil
        refreshGeneration += 1; clearRefreshPresentation()
        state = .off
        queuedRows.removeAll(); queuedRequestIDs.removeAll()
        autoRefresh?.cancel()
        autoRefresh = nil
        screen = nil
        tile = nil
        tileIsStale = false
        lastResult = nil
        isShowingCompletion = false
        openingPage?.cancel()
        pages = [:]
        pageIDs = [:]
        pageUse = []
        viewStates = [:]; viewStateUse = []
        lastRefreshed = nil; lastScreenRefreshed = nil
        groupPath = []
        sessionScopes = []; sessionGroup = nil; scopedReviewed = [:]; scopedOrigins = [:]; sessionSections = [:]; sessionSectionPages = [:]
        sessionBulk = [:]; bulkVisible = [:]; bulkSections = [:]; bulkEdit = nil
        chosen = [:]; chosenAll = [:]; scopedChoices = [:]; ephemeralScopes = []
        transientCleanupChoices = [:]
    }

    /// `reload` asks the module to forget what it cached first (the Refresh button); after an action the module already did.
    /// `quiet` preserves existing content during automatic work. Status/cache reads stay silent; real scans report progress.
    /// `following`: a read that follows a changing tile (`Tile.refreshAfter`), every few seconds. It never shows loading, even when the
    /// module has no `status` and reads the Mac in full: each one filled the page's button and pulsed its background, every five
    /// seconds while Siri's models were being freed (2026-10-19).
    public func refresh(reload: Bool = false, quiet: Bool = false, following: Bool = false) async {
        await read(reload: reload, quiet: quiet, following: following)
    }

    /// Option/background mutations must supersede a presentation captured before the change.
    func refreshAfterChange() async { await read(quiet: true, superseding: true) }

    @MainActor private final class ReadFlight {
        let generation: Int
        var readsScreen: Bool
        let silent: Bool
        var task: Task<Void, Never>?
        var screenTask: Task<Screen, Never>?
        var startScreen: (@MainActor () -> Void)?
        var hasReadPresentation = false
        init(generation: Int, readsScreen: Bool, silent: Bool) {
            self.generation = generation; self.readsScreen = readsScreen; self.silent = silent
        }
        func includeScreen() { readsScreen = true; startScreen?() }
    }
    private var readFlight: ReadFlight?

    private func read(reload: Bool = false, quiet: Bool = false, following: Bool = false,
                      navigation: Bool = false, superseding: Bool = false) async {
        traceLoad("read-request reload=\(reload) quiet=\(quiet) following=\(following) navigation=\(navigation) superseding=\(superseding)")
        if reload || !quiet { invalidatePendingSelections() }
        guard !Task.isCancelled, !preparingForUninstall, state == .ready, let module else { return }
        guard !quiet || !performing else { return }
        dashboardWarmup?.cancel(); dashboardWarmup = nil
        if quiet, !reload, !superseding, let flight = readFlight {
            let needsLateScreen = screenIsVisible && !flight.readsScreen && flight.hasReadPresentation
            if screenIsVisible, !needsLateScreen {
                flight.includeScreen()
                if screen == nil, refreshRequests.contains(flight.generation) {
                    blockingRefreshes.insert(flight.generation); updateBusy()
                }
            }
            await flight.task?.value
            if readFlight === flight { readFlight = nil; requestModuleActivityUpdate(); scheduleAutoRefresh() }
            if needsLateScreen, screenIsVisible, state == .ready, isWatched {
                await read(quiet: true, following: following, navigation: navigation)
            }
            return
        }
        refreshGeneration += 1
        clearRefreshPresentation()
        let flight = ReadFlight(generation: refreshGeneration, readsScreen: screenIsVisible, silent: navigation && screen != nil)
        readFlight = flight
        let priority: TaskPriority = reload || !quiet || navigation || tile == nil || (flight.readsScreen && screen == nil)
            ? .userInitiated : Task.currentPriority
        let task = Task(priority: priority) { @MainActor [weak self, weak flight] in
            guard let self, let flight, self.readFlight === flight else { return }
            await self.refreshNow(module: module, reload: reload, quiet: quiet, following: following, flight: flight)
        }
        flight.task = task
        await task.value
        if readFlight === flight { readFlight = nil; requestModuleActivityUpdate(); scheduleAutoRefresh() }
    }

    private func refreshNow(module: any MacSpaceModule, reload: Bool, quiet: Bool, following: Bool, flight: ReadFlight) async {
        // Retire the pending timer before an explicit read; it must not fire halfway through and supersede the user's reload.
        autoRefresh?.cancel()
        autoRefresh = nil
        let context = context()
        let generation = flight.generation
        let started = Date()
        let expected = settings.loadDuration(module: id, reload: reload) ?? LoadFill.firstGuess
        refreshRequests.insert(generation)
        let blocking = screen == nil && flight.readsScreen
        if !flight.silent, !quiet || blocking { showRefresh(generation, started: started, expected: expected, blocking: blocking) }
        if reload && !quiet {
            rereadGeneration = generation
            isRereading = true
        }
        defer {
            if rereadGeneration == generation {
                rereadGeneration = nil
                isRereading = false
            }
            refreshRequests.remove(generation)
            blockingRefreshes.remove(generation)
            if refreshes.remove(generation) != nil {
                if refreshes.isEmpty { loading = nil; loadingGeneration = nil }
                updateBusy()
            }
            requestModuleActivityUpdate()
            scheduleAutoRefresh()
        }
        await syncModuleActivity()
        guard generation == refreshGeneration, state == .ready, isEnabled, !Task.isCancelled else { return }
        if reload {
            if let id = groupPath.last, let forest = graphPage(id) {
                for segment in forest.hero?.segments ?? [] {
                    if let pageID = segment.pageID { await module.invalidate(pageID: pageID, context: context) }
                }
            } else { await module.invalidate(pageID: groupPath.last.map { pageIDs[$0] ?? $0 }, context: context) }
        }
        // What the module says of its progress fills the Loading button (`LoadFill.reported`).
        let delivery = LoadProgressRelay()
        delivery.attach { [weak self, weak flight] fraction in
            Task { @MainActor in
                guard let self, let flight, !flight.silent, generation == self.refreshGeneration,
                      self.state == .ready, !self.preparingForUninstall, self.refreshRequests.contains(generation) else { return }
                if !self.refreshes.contains(generation) {
                    guard fraction < 1, self.isWatched || self.windowIsVisible || self.finishingHiddenRead, !following else { return }
                    self.showRefresh(generation, started: started, expected: expected, blocking: self.screen == nil && flight.readsScreen)
                }
                guard fraction > self.loading?.reported ?? -1 else { return }
                self.loading?.reported = fraction
            }
        }
        defer { flight.startScreen = nil }
        let reports: LoadProgressSink = { if $0.isFinite { delivery.report($0) } }
        let newTile: Tile
        let newScreen: Screen?
        if quiet, !reload, let status = await module.status(context: context) {
            newTile = status.tile
            newScreen = flight.readsScreen ? status.screen : nil
        } else {
            flight.startScreen = { [weak flight] in
                guard let flight, flight.screenTask == nil else { return }
                flight.screenTask = Task { await module.screen(context: context, progress: reports) }
            }
            if flight.readsScreen { flight.includeScreen() }
            newTile = await module.tile(context: context, progress: reports)
            if screenIsVisible { flight.includeScreen() }
            newScreen = await flight.screenTask?.value
        }
        flight.hasReadPresentation = true; flight.startScreen = nil
        traceLoad("read-result resultGen=\(generation) cancelled=\(Task.isCancelled)")
        guard generation == refreshGeneration, state == .ready, !Task.isCancelled else { return }
        if refreshes.contains(generation) { settings.setLoadDuration(Date().timeIntervalSince(started), module: id, reload: reload) }
        lastRefreshed = refreshClock()
        // Only what changed is published: each published value redraws the tile and the page, and the readings that follow the Mac
        // by themselves mostly find it unchanged.
        if tile != newTile {
            tile = newTile
            settings.setLastTile(newTile, module: id)
        }
        if tileIsStale { tileIsStale = false }
        if let newScreen = await preparedPage(newScreen) {
            guard generation == refreshGeneration, state == .ready else { return }
            reconcileSelection(newScreen)
            if screen != newScreen { screen = newScreen; invalidateClosedPages() }
            lastScreenRefreshed = refreshClock()
        }
        if reload { invalidateClosedPages() }
        await refreshPages()
        await openRequestedPage()
        scheduleAutoRefresh()
    }

    private func showRefresh(_ generation: Int, started: Date, expected: TimeInterval, blocking: Bool) {
        refreshes.insert(generation)
        if blocking { blockingRefreshes.insert(generation) }
        if loadingGeneration != generation {
            traceLoad("loading-start newGen=\(generation) blocking=\(blocking)")
            loading = LoadFill(started: started, expected: expected)
            loadingGeneration = generation
        }
        updateBusy()
    }

    private func updateBusy() {
        let busy = performing || !blockingRefreshes.isEmpty || pageLoading != nil
        if isBusy != busy { isBusy = busy }
        let refreshing = !refreshes.isEmpty
        if isRefreshing != refreshing { isRefreshing = refreshing }
        let reloading = !blockingRefreshes.isEmpty
        if isReloading != reloading { isReloading = reloading }
    }

    /// A newer read or action supersedes old reads immediately; their late completion must not keep the widget loading.
    private func clearRefreshPresentation(reason: String = #function) {
        traceLoad("loading-clear source=\(reason)")
        refreshes.removeAll()
        blockingRefreshes.removeAll()
        if loading != nil { loading = nil }
        loadingGeneration = nil
        updateBusy()
    }

    /// Runs an action. Missing permissions stop it before the module is called. Returns what the module answered (nil when it was not
    /// called).
    ///
    /// `quiet` is for a switch: its row has already moved, so the page shows no progress and is not held while the change runs, and
    /// it is read again quietly afterwards. Only a result the user must see is shown: a failure (the row then moves back) or something
    /// left to do.
    @discardableResult
    public func perform(_ action: Action, extraParameters: [String: String] = [:], quiet: Bool = false, rowID: String? = nil) async -> ActionResult? {
        guard !preparingForUninstall, state == .ready, module != nil else { return nil }
        guard let live = trustedAction(action) else {
            return .failed(String(localized: "Selected cleanup items changed. Review your selection again."))
        }
        let revision = contractRevision
        let instance = moduleEpoch
        guard extrasAreTrusted(extraParameters, for: live), confirm(live),
              contractRevision == revision, moduleEpoch == instance, trustedAction(live) != nil else { return nil }
        if let pageID = live.pageID {
            guard state == .ready, !preparingForUninstall, !performing else { return nil }
            let parameters = action.parameters.merging(extraParameters) { _, extra in extra }
            requestPage(parameters.isEmpty ? pageID : ActionPageRequest(destination: pageID, parameters: parameters).pageID)
            return nil
        }
        invalidatePendingSelections()
        // One action at a time, in the order asked: switches no longer wait for each other, and two changes running together could
        // both write the module's undo journal.
        let previous = lastAction
        // Working at once, also while the action ahead (and the reading after it) finishes; its own turn takes it out. Not the app's
        // own actions, which open something at once and have nothing to say.
        let requestID = UUID()
        if let rowID, !quiet, !Self.opensAtOnce(action) { queuedRows[rowID] = action; queuedRequestIDs[rowID] = requestID }
        let task = Task { @MainActor [weak self] () -> ActionResult? in
            _ = await previous?.value
            guard let self else { return nil }
            defer { self.clearQueuedRequest(rowID, requestID: requestID) }
            guard self.contractRevision == revision,
                  self.moduleEpoch == instance,
                  let current = self.trustedAction(live) else { return nil }
            self.clearQueuedRequest(rowID, requestID: requestID)
            return await self.performNow(current, extraParameters: extraParameters, quiet: quiet, rowID: rowID)
        }
        lastAction = task
        return await task.value
    }

    private func clearQueuedRequest(_ rowID: String?, requestID: UUID) {
        guard let rowID, queuedRequestIDs[rowID] == requestID else { return }
        queuedRequestIDs[rowID] = nil; queuedRows[rowID] = nil
    }

    public func performTileSwitch(_ action: Action, value: Bool) async -> ActionResult? {
        guard !tileIsStale, tile?.switchAction == action else { return nil }
        return await perform(action, extraParameters: ["value": value ? "true" : "false"], quiet: true)
    }

    private var lastAction: Task<ActionResult?, Never>?

    /// The app's own actions (`performNow`): they open a System Settings pane or macOS's Restart dialog at once, so their button
    /// never says Working. Marked working like a module's action, Open flashed "Working" over its pill as the pane opened, too
    /// quickly for the pill to take the word's width (2026-10-20). A button says something only when it has something to say.
    static func opensAtOnce(_ action: Action) -> Bool {
        action.pageID != nil || [Action.fullDiskAccessID, Action.openSettingsID, Action.restartID].contains(action.id)
    }

    /// How often a module is read again by itself, so its tile and page follow the Mac without Refresh; a tile that is changing
    /// asks for sooner (`Tile.refreshAfter`).
    static let autoRefreshInterval: TimeInterval = 60
    /// The same while another app is in front, with MacSpace's window still on screen behind it: a glance at it does not need
    /// the minute's figures, and every module read again each minute (Debloat starts several processes to read the Mac) kept
    /// MacSpace at a few percent of CPU in the background. Coming back to MacSpace reads again the modules whose figures are older
    /// than a minute (`appBecameActive`).
    static let backgroundRefreshInterval: TimeInterval = 600
    static let fastestAutoRefresh: TimeInterval = 2
    /// Whether MacSpace is the app in front; injectable for tests.
    static var isAppActive: @MainActor () -> Bool = { NSApp?.isActive ?? true }
    private var autoRefresh: Task<Void, Never>?
    private var lastRefreshed: Date?
    private var lastScreenRefreshed: Date?
    var refreshClock: () -> Date = { Date() }
    var dashboardWarmupDelay: Duration = .zero
    private var dashboardWarmup: Task<Void, Never>?

    /// Only the first detailed dashboard inventory waits for the opening animation.
    /// A direct visit cancels the delay and joins/starts the same normal read.
    private func deferDashboardWarmup() -> Bool {
        guard dashboardWarmupDelay > .zero, isWatched, !screenIsVisible, !hasCurrentRefresh, lastRefreshed == nil else { return false }
        if dashboardWarmup == nil {
            dashboardWarmup = Task { @MainActor [weak self, dashboardWarmupDelay] in
                do { try await Task.sleep(for: dashboardWarmupDelay) } catch { return }
                guard let self, self.state == .ready, self.isWatched, !self.screenIsVisible else { return }
                self.dashboardWarmup = nil
                await self.read(quiet: true)
            }
        }
        return true
    }

    var presentationAge: TimeInterval {
        (screenIsVisible ? lastScreenRefreshed : lastRefreshed).map { refreshClock().timeIntervalSince($0) } ?? .infinity
    }
    /// Whether a window of MacSpace is on screen. Without one nobody sees the tile or the page, so the module is not read again by
    /// itself: with the window closed, those readings (a full scan of the disk for System Data, every two minutes) were what kept
    /// MacSpace at 30% CPU in the background.
    public private(set) var isWatched = true
    public private(set) var screenIsVisible = true
    /// A covered module stops polling, but a visible app keeps its existing reads and lightweight observers alive.
    private var windowIsVisible = true
    var hiddenReadGrace: Duration = .seconds(300)
    private var finishingHiddenRead = false
    private var hiddenReadDeadline: Task<Void, Never>?

    private func cancelHiddenReadGrace() {
        hiddenReadDeadline?.cancel(); hiddenReadDeadline = nil
        finishingHiddenRead = false
    }

    private func retireHiddenReads() {
        // A suspended module can reply with its previous cache. Retire the generation first.
        readFlight = nil
        refreshGeneration += 1; clearRefreshPresentation()
        pageLoadGeneration += 1; pageLoading = nil; updateBusy()
    }

    private func finishReadsAfterWindowCloses() {
        guard hasPendingReads, hiddenReadGrace > .zero, state == .ready, isEnabled, !preparingForUninstall else {
            cancelHiddenReadGrace(); retireHiddenReads()
            return
        }
        guard !finishingHiddenRead else { return }
        finishingHiddenRead = true
        let delay = hiddenReadGrace
        traceLoad("hidden-read-grace-start duration=\(delay)")
        hiddenReadDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, !self.windowIsVisible, self.finishingHiddenRead else { return }
            self.hiddenReadDeadline = nil; self.finishingHiddenRead = false
            self.traceLoad("hidden-read-grace-expired")
            if !self.actionNeedsModuleActivity, !self.performing { self.retireHiddenReads() }
            self.requestModuleActivityUpdate()
        }
    }

    /// Covered modules stop polling. Their current read and observers remain active while an app window is visible.
    /// Closing the last canvas gives existing reads bounded headroom; idle backends suspend immediately.
    public func setWatched(_ watched: Bool, screenVisible: Bool = true, windowVisible: Bool? = nil) {
        let windowVisible = windowVisible ?? watched
        let openedPage = watched && screenVisible && !screenIsVisible
        guard watched != isWatched || screenVisible != screenIsVisible || windowVisible != windowIsVisible else { return }
        traceLoad("watch-change newWatched=\(watched) newPageVisible=\(screenVisible) newWindowVisible=\(windowVisible)")
        if !watched || !screenVisible { cancelRequestedPage() }
        invalidatePendingSelections()
        isWatched = watched
        screenIsVisible = screenVisible
        windowIsVisible = windowVisible
        dashboardWarmup?.cancel(); dashboardWarmup = nil
        if windowVisible { cancelHiddenReadGrace() }
        else { finishReadsAfterWindowCloses() }
        requestModuleActivityUpdate()
        if !watched {
            autoRefresh?.cancel()
            autoRefresh = nil
        } else if state == .ready {
            if !openedPage, hasCurrentRefresh { return }
            if deferDashboardWarmup() { return }
            if openedPage || presentationAge >= Self.fastestAutoRefresh {
                Task { if isWatched { await read(quiet: true, navigation: openedPage) } }
            } else { scheduleAutoRefresh() }
        }
    }

    /// Back in front: figures older than the usual minute are read again now, and the readings go back to every minute.
    func appResignedActive() {
        autoRefresh?.cancel(); autoRefresh = nil
        requestModuleActivityUpdate()
    }
    func appBecameActive() {
        guard state == .ready, windowIsVisible, isEnabled else { return }
        requestModuleActivityUpdate()
        guard isWatched else { return }
        guard !hasCurrentRefresh, pageRequests.isEmpty, !actionNeedsModuleActivity, !performing else { return }
        if presentationAge >= Self.autoRefreshInterval, !performing {
            Task { if isWatched { await refresh(quiet: true) } }
        } else { scheduleAutoRefresh() }
    }

    /// Follow the current metadata worker without reconciling unrelated global filesystem events.
    func followPendingPage() async {
        guard state == .ready, isWatched, screenIsVisible else { return }
        await refreshPages()
        scheduleAutoRefresh()
    }

    /// Schedules the next quiet reading after the one that just finished.
    private func scheduleAutoRefresh() {
        autoRefresh?.cancel()
        guard state == .ready, isWatched, Self.isAppActive(), !hasCurrentRefresh, pageRequests.isEmpty, !actionNeedsModuleActivity else { return }
        let interval = Self.isAppActive() ? Self.autoRefreshInterval : Self.backgroundRefreshInterval
        // A tile that is changing (`Tile.refreshAfter`) is followed at its own pace, in front or not, without showing loading.
        let pagePending = groupPath.last.flatMap { pages[$0] }?.loadingFraction ?? (groupPath.isEmpty ? screen?.loadingFraction : nil)
        let delay = pagePending != nil ? Self.fastestAutoRefresh : max(min(tile?.refreshAfter ?? interval, interval), Self.fastestAutoRefresh)
        let following = delay < interval
        autoRefresh = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.state == .ready, self.isWatched else { return }
            // This timer has fired. The read may cancel a pending timer, without canceling its own task.
            self.autoRefresh = nil
            // Not while an action runs: it reads the module again itself when it ends.
            if self.performing { self.scheduleAutoRefresh() }
            else if pagePending != nil { await self.followPendingPage() }
            else { await self.refresh(quiet: true, following: following) }
        }
    }

    private func performNow(_ action: Action, extraParameters: [String: String], quiet: Bool, rowID: String?) async -> ActionResult? {
        guard !preparingForUninstall, state == .ready, let module else { return nil }
        let performingContract = contractRevision
        // The app's own actions (`Action.allowFullDiskAccess`, `openSettings`, `restart`): the module is not called.
        if action.id == Action.fullDiskAccessID {
            openPane(LivePermissionChecker.fullDiskAccessSettingsURL)
            return nil
        }
        if action.id == Action.openSettingsID {
            // Only a System Settings pane: whatever else a module puts there is not opened.
            if let url = Action.settingsPane(action.parameters) { openPane(url) }
            return nil
        }
        // macOS's Restart dialog, where the user confirms.
        if action.id == Action.restartID {
            guard SystemRestart.showDialog() else {
                let result = ActionResult(outcome: .needsAttention, message: String(localized: "Restart your Mac from the Apple menu."), refresh: false)
                lastResult = result
                return result
            }
            return nil
        }
        let missing = action.requires.filter { permissions.status(of: $0) != .granted }
        if !missing.isEmpty {
            // For a switch it counts as failed: nothing changed, so the switch goes back.
            let result = ActionResult(outcome: quiet ? .failed : .needsAttention,
                                      message: String(localized: "Needs \(ListFormatter.localizedString(byJoining: missing.map(\.title)))"),
                                      refresh: false)
            if let rowID, !quiet { setRowResult(result, for: rowID) } else { lastResult = result }
            return result
        }
        readFlight = nil
        refreshGeneration += 1
        clearRefreshPresentation()
        performing = true
        actionNeedsModuleActivity = true
        let started = Date()
        if !quiet {
            updateBusy()
            isCleaning = rowID == nil
            runningRowID = rowID
            runningAction = action
            if let rowID { setRowResult(nil, for: rowID) }
            finishedRows = []
            progress = nil
        }
        defer {
            if !quiet {
                isCleaning = false
                runningAction = nil
                runningRowID = nil
            }
            actionNeedsModuleActivity = false
            requestModuleActivityUpdate()
            scheduleAutoRefresh()
        }
        await syncModuleActivity()
        guard contractRevision == performingContract, trustedAction(action) != nil, extrasAreTrusted(extraParameters, for: action) else { return nil }
        lastResult = nil
        invalidatePendingSelections()
        actionGeneration += 1
        let generation = actionGeneration
        let request = ActionRequest(actionID: action.id, parameters: action.parameters.merging(extraParameters) { _, new in new }, rowID: rowID)
        let visibleIDs = activeSelection.map { Set($0.selection?.choices.keys.map { $0 } ?? []) } ?? []
        let completed = FinishedChoiceProgress(allowed: request.parameters["selectionToken"] == nil ? nil : visibleIDs)
        let operation: @Sendable (ActionRequest, ModuleContext, @escaping ProgressSink) async -> ActionResult
        if request.actionID == CleanupBatch.actionID {
            let ids = Set(Selection.ids(request.parameters["ids"]))
            let current = currentCleanupTargets.filter { ids.contains($0.id) && $0.available }
            let frozen = request.parameters["targets"].flatMap { try? JSONDecoder().decode([CleanupTarget].self, from: Data($0.utf8)) }
            operation = { _, context, progress in
                guard let targets = frozen, Set(targets.map(\.id)) == ids, Set(current.map(\.id)) == ids, !ids.isEmpty,
                      targets.allSatisfy({ target in current.contains { $0.id == target.id && $0.action == target.action } }) else {
                    return .failed(String(localized: "Selected cleanup items changed. Review your selection again."))
                }
                return await CleanupBatch.run(targets, automatic: false, context: context, progress: progress, perform: module.perform)
            }
        } else { operation = module.perform }
        let result = await operation(request, context()) { [weak self] update in
            guard !quiet else { return }
            completed.record(update.finished)
            Task { @MainActor in
                guard let self, self.performing, self.actionGeneration == generation else { return }
                self.progress = update
                if !update.finished.isEmpty, Set(update.finished) != self.finishedRows {
                    self.finishedRows = Set(update.finished)
                    self.forgetFinishedChoices(self.finishedRows)
                }
            }
        }
        // A synchronous module may finish before its main-actor progress tasks run.
        // Keep successful removals out of later pages and button totals in that case too.
        if !quiet { forgetFinishedChoices(completed.ids) }
        if result.outcome == .succeeded, let token = request.parameters["selectionToken"] {
            for scope in Array(sessionBulk.keys) where sessionBulk[scope]?.token == token {
                sessionBulk[scope] = nil; bulkVisible[scope] = nil; bulkSections[scope] = nil
                if sessionGroup?.id == scope { sessionGroup?.selection?.bulk = nil }
            }
        }
        // A success the user started is "All done" on the page (`ActionResult`), once its figures are in; anything else is the
        // button's text.
        let batchContinues = request.actionID == CleanupBatch.actionID && result.message.isEmpty && result.presentation?.screen.cleanupTargets.contains(where: { !$0.available }) == true
        let continuesInRow = result.outcome == .succeeded && !result.restartRequired && (batchContinues || result.presentation?.screen.activeRow(for: request) != nil)
        let celebrates = !quiet && rowID == nil && !continuesInRow && result.outcome == .succeeded && !result.restartRequired && (result.freedBytes != nil || result.removedBytes != nil || !result.message.isEmpty)
        if let rowID, !quiet {
            setRowResult(result.message.isEmpty || continuesInRow ? nil : result, for: rowID)
        } else if !continuesInRow && ((!quiet && !celebrates) || result.outcome != .succeeded || result.restartRequired) { lastResult = result }
        // A long action that ends while the user is in another app says so in Notification Center.
        if !quiet { AppNotifications.shared.actionFinished(module: self, message: result.message, took: Date().timeIntervalSince(started)) }
        if let freed = result.freedBytes {
            CleanupHistory.shared.record(moduleID: id, moduleName: manifest.name, freedBytes: freed, trigger: .manual, summary: result.message)
        }
        performing = false
        updateBusy()
        // "All done" as soon as the work is: reading the Mac again takes seconds of its own (a full scan for System Data). Meanwhile
        // the button stays full and keeps saying what the action did, the charts keep moving (`isCleaning`), and the rows the action
        // finished stay gone, until the new figures are in.
        if !quiet {
            if celebrates {
                allDoneFreed = result.freedBytes
                allDoneRemoved = result.removedBytes
                isShowingCompletion = true
                allDone += 1
            }
            if result.refresh { progress = ActionProgress(fraction: 1, message: progress?.message ?? "", finished: progress?.finished ?? []) }
        }
        if let presentation = result.presentation {
            if tile != presentation.tile { tile = presentation.tile; settings.setLastTile(presentation.tile, module: id) }
            reconcileSelection(presentation.screen)
            if screen != presentation.screen { screen = presentation.screen }
            invalidateClosedPages()
            await refreshPages(all: true)
            tileIsStale = false
            lastRefreshed = refreshClock(); lastScreenRefreshed = lastRefreshed
            scheduleAutoRefresh()
        } else if result.refresh { await refresh(quiet: true) }
        if !quiet {
            updateBusy()
            progress = nil
            finishedRows = []
        }
        return result
    }

    /// Disabled modules may still own settings from an earlier session.
    func prepareForUninstall() async -> ActionResult {
        guard !isBusy else { return .failed(String(localized: "Working")) }
        await syncModuleActivity()
        do {
            try await loadModule()
            guard let module else { return .failed(manifest.name) }
            return await module.prepareForUninstall(context: context())
        } catch { return .failed(error.localizedDescription) }
    }

    public func dismissResult() { lastResult = nil }
    public func dismissRowResult(_ rowID: String) { setRowResult(nil, for: rowID) }

    private func setRowResult(_ result: ActionResult?, for rowID: String) {
        rowResults[rowID] = result
        if result != nil { resultRowID = rowID } else if resultRowID == rowID { resultRowID = rowResults.keys.first }
    }

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
        // In the same line as the user's actions: run beside one, both deleted the same caches, and the action's end cleared the
        // `isCleaning` this cleanup still needed.
        let previous = lastAction
        let task = Task { @MainActor [weak self] () -> CleanupReport? in
            _ = await previous?.value
            return await self?.autoCleanNow()
        }
        lastAction = Task { _ = await task.value; return nil }
        return await task.value
    }

    private func autoCleanNow() async -> CleanupReport? {
        guard !preparingForUninstall, state == .ready, manifest.autoClean == true, let module else { return nil }
        readFlight = nil; refreshGeneration += 1; clearRefreshPresentation()
        isCleaning = true
        performing = true
        actionNeedsModuleActivity = true
        defer { isCleaning = false; performing = false; actionNeedsModuleActivity = false; updateBusy(); requestModuleActivityUpdate(); scheduleAutoRefresh() }
        await syncModuleActivity()
        let report = await module.autoClean(context: context())
        if let report {
            CleanupHistory.shared.record(moduleID: id, moduleName: manifest.name, freedBytes: report.freedBytes, trigger: .automatic, summary: report.summary)
        }
        performing = false
        if isWatched { await refreshAfterChange() }
        return report
    }

    func runBackgroundTask(_ taskID: String) async {
        guard !preparingForUninstall, state == .ready, let module else { return }
        await module.runBackgroundTask(taskID, context: context())
        // A task may have changed something (the Debloat watch switching a feature off again): the tile and page show it.
        if isWatched { await refreshAfterChange() }
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
