import AppKit
import SwiftUI
import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private actor SelectionPageReads {
    var count = 0
    func read() { count += 1 }
}
private struct FileSelectionModule: MacSpaceModule {
    let reads: SelectionPageReads
    init() { reads = SelectionPageReads() }
    init(reads: SelectionPageReads) { self.reads = reads }
    let rows = (0..<40).map { Row(id: "file:\($0)", title: "Large file \($0).mov", trailing: "200 MB", paths: ["/fixture/file\($0)"]) }
    var selection: Selection {
        Selection(action: Action(id: "freeFiles", title: "Free selected", role: .prominent),
                  choices: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, UInt64(200_000_000)) }), scope: "folder:root")
    }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Disk", status: "Ready") }
    func screen(context: ModuleContext) async -> Screen {
        Screen(title: "Disk", hero: UsageBar(id: "map", title: "Disk", segments: [UsageSegment(id: "folder", label: "Folder", bytes: 8_000_000_000, tone: .series(0), pageID: "folder:A")]),
               widgets: [.list(ListWidget(id: "apps", title: "Apps", rows: [Row(id: "apps-entry", title: "Uninstall apps", subtitle: "12 items"), Row(id: "leftovers", title: "Leftovers from removed apps", trailing: "100 MB")])),
                         .list(ListWidget(id: "large", title: "Large files", rows: rows + [Row(id: "more", title: "More items", pageID: "more")], fillsRemainingSpace: true))], selection: selection)
    }
    func page(id: String, context: ModuleContext) async -> Screen? {
        await reads.read()
        return Screen(title: "Large files", layout: .singleColumn, widgets: [.list(ListWidget(id: "all", title: "Files of 100 MB or larger", rows: rows))], selection: selection)
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        progress(ActionProgress(message: "Freeing", finished: Selection.ids(request.parameters["ids"])))
        return .init(outcome: .needsAttention, message: "Fixture", refresh: false)
    }
}

private struct GraphSelectionModule: MacSpaceModule {
    let selection = Selection(action: Action(id: "freeFiles", title: "Free"), choices: ["file": 4096], scope: "graph-files:root", partial: true)
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Disk", status: "Ready") }
    func screen(context: ModuleContext) async -> Screen {
        Screen(title: "Disk", hero: UsageBar(id: "map", title: "Disk", segments: [UsageSegment(id: "files", label: "Files", bytes: 4096, tone: .series(0), items: [Row(id: "file", title: "File")], selection: selection)]), widgets: [])
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .init(outcome: .failed, message: "Fixture") }
}

private actor SelectionInventoryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requested = false
    private(set) var returned = false
    func wait() async {
        requested = true
        await withCheckedContinuation { continuation = $0 }
        returned = true
    }
    func release() { continuation?.resume(); continuation = nil }
}
private struct SessionSelectionModule: MacSpaceModule {
    let gate: SelectionInventoryGate?
    init() { gate = nil }
    init(gate: SelectionInventoryGate?) { self.gate = gate }
    let selection = Selection(action: Action(id: "freeFiles", title: "Delete selected"), choices: ["one": 100],
                              scope: "disk-files", partial: true, session: true, reviewed: ["one": "original"], origins: ["one": "duplicate-proof"])
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Disk", status: "Ready") }
    func screen(context: ModuleContext) async -> Screen {
        Screen(title: "Disk", widgets: [.list(ListWidget(id: "files", title: "Files", rows: [Row(id: "one", title: "One")]))], selection: selection)
    }
    func page(id: String, context: ModuleContext) async -> Screen? {
        if let gate { await gate.wait() }
        guard id != "unavailable" else { return nil }
        var inventory = selection
        inventory.choices = ["one": 100, "two": 200]
        inventory.reviewed["two"] = "second"
        if id == "second-folder" { inventory.choices = ["two": 200] }
        if id == "smaller" { inventory.choices["small"] = 1; inventory.reviewed["small"] = "small" }
        let rows = id == "category" ? [Row(id: "expand", title: "Show all files", pageID: "small-files")] : [Row(id: "small-file", title: "Small")]
        return Screen(title: "Files", widgets: [.list(ListWidget(id: "files", title: "Files", rows: rows))], selection: inventory)
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        progress(ActionProgress(message: "Deleting", finished: Selection.ids(request.parameters["ids"])))
        return .init(outcome: .needsAttention, message: "Fixture", refresh: false)
    }
}

private actor BulkSelectionSnapshots {
    struct State: Sendable { var all = false; var smaller = false; var excluded = Set<String>(); var explicit = Set<String>() }
    var states: [String: State] = [:]
    var requests: [SelectionBulkRequest] = []
    func resolve(_ request: SelectionBulkRequest) -> SelectionBulk {
        requests.append(request)
        var state = request.token.flatMap { states[$0] } ?? State()
        if request.operation == "toggleAll" {
            if request.scopePageID == "smaller" { state.all = true; state.smaller = true; state.excluded = [] }
            else { state.all.toggle(); state.excluded = [] }
        } else if request.operation == "toggle", let id = request.toggledID {
            if state.all {
                if !state.excluded.insert(id).inserted { state.excluded.remove(id) }
            } else if !state.explicit.insert(id).inserted { state.explicit.remove(id) }
        }
        let token = request.operation == "read" ? request.token ?? UUID().uuidString : UUID().uuidString
        states[token] = state
        let count = UInt64((state.all ? 20_001 : 0) + (state.smaller ? 1 : 0) - state.excluded.count + state.explicit.count)
        let checked = request.visible.filter { id in
            ((id == "small" ? state.smaller : state.all) && !state.excluded.contains(id)) || state.explicit.contains(id)
        }
        return SelectionBulk(token: token, count: count, bytes: count * 100, checked: checked,
            all: state.all && state.excluded.isEmpty ? request.sections.filter { $0 != "smaller" || state.smaller } : [])
    }
}
private struct BulkSelectionModule: MacSpaceModule {
    let snapshots: BulkSelectionSnapshots
    init() { snapshots = BulkSelectionSnapshots() }
    init(snapshots: BulkSelectionSnapshots) { self.snapshots = snapshots }
    var selection: Selection {
        Selection(action: Action(id: "freeFiles", title: "Delete selected"), choices: ["one": 100, "two": 100],
            sections: [.init(id: "category", title: "Category", rows: ["one", "two"], pageID: "all")],
            scope: "disk-files", partial: true, session: true, reviewed: ["one": "original", "two": "second"], bulkResolver: "selection:")
    }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Disk", status: "Ready") }
    func screen(context: ModuleContext) async -> Screen {
        Screen(title: "Disk", widgets: [.list(ListWidget(id: "files", title: "Files", rows: [Row(id: "one", title: "One"), Row(id: "two", title: "Two")]))], selection: selection)
    }
    func page(id: String, context: ModuleContext) async -> Screen? {
        guard let request = SelectionBulkRequest(pageID: id) else { return nil }
        var selection = selection
        selection.choices = [:]; selection.sections = []
        selection.bulk = await snapshots.resolve(request)
        return Screen(title: "Files", widgets: [], selection: selection)
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        .init(outcome: .succeeded, message: "Done", refresh: false)
    }
}

@MainActor
final class PageFileSelectionTests: XCTestCase {
    func testPartialPagesKeepSelectedChoicesAcrossDisjointInventories() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in FileSelectionModule() })
        await handle.activate(); defer { handle.deactivate() }
        func page(_ id: String, bytes: UInt64) -> Screen {
            Screen(title: "Files", widgets: [.list(ListWidget(id: "files", rows: [Row(id: id, title: id)]))],
                   selection: Selection(action: Action(id: "freeFiles", title: "Free selected"), choices: [id: bytes], scope: "folder:root", partial: true))
        }
        let first = page("one", bytes: 1), second = page("two", bytes: 2)
        handle.toggle("one", in: try XCTUnwrap(handle.pageSelection(first, id: "first")))
        handle.toggle("two", in: try XCTUnwrap(handle.pageSelection(second, id: "second")))
        let combined = try XCTUnwrap(handle.pageSelection(second, id: "second"))
        XCTAssertEqual(handle.checked(combined), ["one", "two"])
        XCTAssertEqual(combined.selection?.choices.values.reduce(0, +), 3)
        handle.toggle("one", in: try XCTUnwrap(handle.pageSelection(first, id: "first")))
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.pageSelection(second, id: "second"))), ["two"])
        handle.clearPageSelections()
        XCTAssertTrue(handle.checked(try XCTUnwrap(handle.pageSelection(second, id: "second"))).isEmpty)
    }

    func testVisibleFilesThatLoseEligibilityAreNotRetainedInTheFreeTotal() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in FileSelectionModule() })
        await handle.activate(); defer { handle.deactivate() }
        var screen = Screen(title: "Files", widgets: [.list(ListWidget(id: "files", rows: [Row(id: "one", title: "One")]))],
                            selection: Selection(action: Action(id: "freeFiles", title: "Free"), choices: ["one": 4096], scope: "files", partial: true))
        handle.toggle("one", in: try XCTUnwrap(handle.pageSelection(screen, id: "first")))
        screen.selection?.choices = [:]
        XCTAssertTrue(handle.checked(try XCTUnwrap(handle.pageSelection(screen, id: "first"))).isEmpty)
    }

    func testGraphChoiceScopeSurvivesNestedNavigationAndClearsWhenItsGroupCloses() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in GraphSelectionModule() })
        await handle.activate(); defer { handle.deactivate() }
        XCTAssertNil(handle.activeSelection)
        handle.pushGroup("segment:files")
        let group = try XCTUnwrap(handle.activeSelection)
        handle.toggle("file", in: group)
        handle.pushGroup("nested")
        handle.popGroup()
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.activeSelection)), ["file"])
        handle.popGroup()
        handle.pushGroup("segment:files")
        XCTAssertTrue(handle.checked(try XCTUnwrap(handle.activeSelection)).isEmpty)
        handle.popGroup()
    }

    func testSynchronousProgressCannotLeaveFreedOffPageChoicesSelected() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in FileSelectionModule() })
        await handle.activate(); defer { handle.deactivate() }
        let page = Screen(title: "Partial", widgets: [.list(ListWidget(id: "files", rows: [Row(id: "file", title: "File")]))],
                          selection: Selection(action: Action(id: "freeFiles", title: "Free"), choices: ["file": 4096], scope: "partial", partial: true))
        let group = try XCTUnwrap(handle.pageSelection(page, id: "partial"))
        handle.toggle("file", in: group)
        _ = await handle.perform(try XCTUnwrap(group.selection?.action), extraParameters: ["ids": Selection.parameter(["file"])])
        XCTAssertTrue(handle.checked(try XCTUnwrap(handle.pageSelection(page, id: "partial"))).isEmpty)
    }

    func testRootAndMoreShareChoicesAndCachedReopenIsImmediateAndBounded() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first), reads = SelectionPageReads()
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in FileSelectionModule(reads: reads) })
        await handle.activate(); defer { handle.deactivate() }
        let root = try XCTUnwrap(handle.activeSelection)
        handle.toggle("file:0", in: root)
        handle.pushGroup("more")
        for _ in 0..<100 where handle.pages["more"]?.selection == nil { try await Task.sleep(for: .milliseconds(5)) }
        let more = try XCTUnwrap(handle.activeSelection)
        XCTAssertEqual(handle.checked(more), ["file:0"])
        handle.toggle("file:1", in: more)
        handle.popGroup()
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.activeSelection)), ["file:0", "file:1"])
        let initialReads = await reads.count
        handle.pushGroup("more")
        XCTAssertEqual(handle.groupPath, ["more"], "Cached reopening must not await a page read")
        let reopenedReads = await reads.count
        XCTAssertEqual(initialReads, reopenedReads)
        handle.popGroup()
        for n in 0..<20 {
            let id = "folder:\(n)"
            handle.pushGroup(id)
            for _ in 0..<100 where handle.groupPath.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
            handle.popGroup()
        }
        XCTAssertLessThanOrEqual(handle.pages.count, 12)
        handle.clearPageSelections()
        XCTAssertTrue(handle.checked(root).isEmpty)
    }

    private func sessionHandle(gate: SelectionInventoryGate? = nil) async throws -> ModuleHandle {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in SessionSelectionModule(gate: gate) })
        await handle.activate()
        return handle
    }

    func testShowAllFilesPushesThroughDefaultNavigation() async throws {
        let handle = try await sessionHandle(); defer { handle.deactivate() }
        handle.requestPage("category")
        for _ in 0..<100 where handle.groupPath.isEmpty { await Task.yield() }
        XCTAssertEqual(handle.groupPath, ["category"])
        handle.pushGroup("expand")
        for _ in 0..<100 where handle.pages["expand"]?.selection == nil { await Task.yield() }
        XCTAssertEqual(handle.groupPath, ["category", "expand"], "Show all files uses a normal push and a new breadcrumb level")
        guard case let .list(list)? = handle.pages["expand"]?.widgets.first else { return XCTFail() }
        XCTAssertEqual(list.rows.first?.id, "small-file")
        XCTAssertFalse(handle.checked(try XCTUnwrap(handle.activeSelection)).contains("small"))
    }

    func testSessionSelectionSurvivesBackHomeAndReturningWithOriginalReviewMetadata() async throws {
        let handle = try await sessionHandle(); defer { handle.deactivate() }
        let first = try XCTUnwrap(handle.activeSelection)
        handle.toggle("one", in: first)
        handle.pushGroup("unrelated")
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.activeSelection)), ["one"])
        handle.popGroup()
        handle.setWatched(false, screenVisible: false)
        handle.clearPageSelections()
        handle.setWatched(true, screenVisible: true)
        var changed = try XCTUnwrap(handle.screen)
        changed.selection?.choices = ["one": 999, "two": 200]
        changed.selection?.reviewed = ["one": "replacement", "two": "second"]
        changed.selection?.origins = ["one": "replacement-proof"]
        let returned = try XCTUnwrap(handle.pageSelection(changed, id: "other-category"))
        XCTAssertEqual(handle.checked(returned), ["one"])
        XCTAssertEqual(returned.selection?.choices["one"], 100)
        XCTAssertEqual(returned.selection?.reviewed["one"], "original")
        XCTAssertEqual(returned.selection?.origins["one"], "duplicate-proof")
        handle.toggle("two", in: returned)
        let combined = try XCTUnwrap(handle.pageSelection(changed, id: "other-category"))
        XCTAssertEqual(handle.checked(combined), ["one", "two"])
        XCTAssertEqual(handle.checked(combined).compactMap { combined.selection?.choices[$0] }.reduce(0, +), 300)
    }

    func testSessionHeadersResolveEntireInventoryAndSmallerFilesDoNotAutoSelect() async throws {
        let handle = try await sessionHandle(); defer { handle.deactivate() }
        var page = try XCTUnwrap(handle.screen)
        page.selection?.sections = [.init(id: "category", title: "Category", rows: ["one"], pageID: "all")]
        let group = try XCTUnwrap(handle.pageSelection(page, id: "category"))
        handle.toggleAll("category", in: group)
        for _ in 0..<100 where handle.chosen["disk-files"] != ["one", "two"] { await Task.yield() }
        var selected = try XCTUnwrap(handle.pageSelection(page, id: "category"))
        XCTAssertEqual(handle.checked(selected), ["one", "two"])
        XCTAssertEqual(handle.allChecked(selected), ["category"])
        page.selection?.choices["small"] = 1
        page.selection?.sections = [.init(id: "category", title: "Category", rows: ["one", "small"], pageID: "smaller")]
        selected = try XCTUnwrap(handle.pageSelection(page, id: "smaller"))
        XCTAssertEqual(handle.checked(selected), ["one", "two"])
        XCTAssertTrue(handle.allChecked(selected).isEmpty)
        handle.toggleAll("category", in: selected)
        for _ in 0..<100 where handle.chosen["disk-files"]?.contains("small") != true { await Task.yield() }
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.pageSelection(page, id: "smaller"))), ["one", "two", "small"])
        handle.toggleAll("category", in: try XCTUnwrap(handle.pageSelection(page, id: "smaller")))
        for _ in 0..<100 where handle.chosen["disk-files"]?.isEmpty != true { await Task.yield() }
        XCTAssertTrue(handle.checked(try XCTUnwrap(handle.pageSelection(page, id: "smaller"))).isEmpty)
    }

    func testSessionHeaderClearsOnlyItsScopeAndUnavailableInventoryKeepsChoices() async throws {
        let handle = try await sessionHandle(); defer { handle.deactivate() }
        handle.toggle("one", in: try XCTUnwrap(handle.activeSelection))
        var page = try XCTUnwrap(handle.screen)
        page.selection?.choices = ["two": 200]
        page.widgets = [.list(ListWidget(id: "folder-files", rows: [Row(id: "two", title: "Two")]))]
        page.selection?.sections = [.init(id: "folder", title: "Folder", rows: ["two"])]
        handle.toggleAll("folder", in: try XCTUnwrap(handle.pageSelection(page, id: "folder")))
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.pageSelection(page, id: "folder"))), ["one", "two"])
        handle.toggleAll("folder", in: try XCTUnwrap(handle.pageSelection(page, id: "folder")))
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.pageSelection(page, id: "folder"))), ["one"])
        // The remote folder header can sit beside other selected rows on the same category page.
        page.selection?.choices = ["one": 100, "two": 200]
        page.widgets = [.list(ListWidget(id: "files", rows: [Row(id: "one", title: "One"), Row(id: "two", title: "Two")]))]
        page.selection?.sections = [.init(id: "folder", title: "Folder", rows: ["two"], pageID: "second-folder")]
        handle.toggleAll("folder", in: try XCTUnwrap(handle.pageSelection(page, id: "folder")))
        for _ in 0..<100 where handle.chosen["disk-files"]?.contains("two") != true { await Task.yield() }
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.pageSelection(page, id: "folder"))), ["one", "two"])
        handle.toggleAll("folder", in: try XCTUnwrap(handle.pageSelection(page, id: "folder")))
        for _ in 0..<100 where handle.chosen["disk-files"]?.contains("two") == true { await Task.yield() }
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.pageSelection(page, id: "folder"))), ["one"])
        page.selection?.sections = [.init(id: "folder", title: "Folder", rows: ["two"], pageID: "unavailable")]
        handle.toggleAll("folder", in: try XCTUnwrap(handle.pageSelection(page, id: "folder")))
        for _ in 0..<100 where handle.lastResult == nil { await Task.yield() }
        XCTAssertEqual(handle.lastResult?.outcome, .failed)
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.pageSelection(page, id: "folder"))), ["one"])
    }

    func testQuietRefreshDoesNotCancelCheckboxEditsOrHideFreshChoices() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first), snapshots = BulkSelectionSnapshots()
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in BulkSelectionModule(snapshots: snapshots) })
        await handle.activate(); defer { handle.deactivate() }
        handle.toggle("one", in: try XCTUnwrap(handle.activeSelection))
        await handle.refresh(quiet: true)
        for _ in 0..<100 where handle.activeSelection?.selection?.bulk == nil { await Task.yield() }
        let group = try XCTUnwrap(handle.activeSelection)
        XCTAssertEqual(handle.checked(group), ["one"])
        XCTAssertEqual(handle.choosableIDs(group), ["one", "two"])
        var expanded = try XCTUnwrap(handle.screen); expanded.selection?.choices["small"] = 1
        let current = try XCTUnwrap(handle.pageSelection(expanded, id: "expanded"))
        XCTAssertTrue(handle.choosableIDs(current).contains("small"), "A fresh eligible checkbox never waits for a later membership task")
        XCTAssertFalse(handle.checked(current).contains("small"))
    }

    func testBulkSelectionUsesBoundedMembershipAndFrozenTokenForMoreThanTenThousandFiles() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first), snapshots = BulkSelectionSnapshots()
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in BulkSelectionModule(snapshots: snapshots) })
        await handle.activate(); defer { handle.deactivate() }
        handle.toggleAll("category", in: try XCTUnwrap(handle.activeSelection))
        for _ in 0..<100 where handle.activeSelection?.selection?.bulk == nil { await Task.yield() }
        var group = try XCTUnwrap(handle.activeSelection)
        XCTAssertEqual(group.selection?.bulk?.count, 20_001)
        XCTAssertEqual(group.selection?.bulk?.bytes, 2_000_100)
        XCTAssertEqual(group.selection?.choices.count, 2)
        XCTAssertEqual(handle.checked(group), ["one", "two"])
        XCTAssertTrue(handle.chosen["disk-files"]?.isEmpty == true)
        handle.toggle("one", in: group)
        handle.toggle("two", in: group)
        for _ in 0..<100 where handle.activeSelection?.selection?.bulk?.count != 19_999 { await Task.yield() }
        group = try XCTUnwrap(handle.activeSelection)
        XCTAssertEqual(group.selection?.bulk?.count, 19_999)
        XCTAssertTrue(handle.checked(group).isEmpty)
        var smaller = try XCTUnwrap(handle.screen)
        smaller.selection?.choices["small"] = 100
        smaller.selection?.sections = [.init(id: "category", title: "Category", rows: ["one", "two", "small"], pageID: "smaller")]
        let shown = try XCTUnwrap(handle.pageSelection(smaller, id: "smaller"))
        XCTAssertFalse(handle.checked(shown).contains("small"))
        XCTAssertTrue(handle.allChecked(shown).isEmpty)
        handle.clearPageSelections()
        XCTAssertEqual(handle.activeSelection?.selection?.bulk?.count, 19_999)
        let requests = await snapshots.requests
        XCTAssertLessThanOrEqual(requests.map { $0.visible.count }.max() ?? 0, 2)
        XCTAssertTrue(requests.allSatisfy { $0.ids.isEmpty })
        let token = try XCTUnwrap(handle.activeSelection?.selection?.bulk?.token)
        _ = await handle.perform(try XCTUnwrap(group.selection?.action), extraParameters: ["selectionToken": token])
        XCTAssertNil(handle.activeSelection?.selection?.bulk)
    }

    func testRequestedPageReplyCannotReopenAfterNavigationOrLifecycleChanges() async throws {
        for change in ["navigation", "deactivate", "visibility"] {
            let gate = SelectionInventoryGate(), handle = try await sessionHandle(gate: gate)
            defer { handle.deactivate() }
            handle.requestPage("all")
            for _ in 0..<100 {
                if await gate.requested { break }
                await Task.yield()
            }
            let requested = await gate.requested
            XCTAssertTrue(requested)
            switch change {
            case "navigation": handle.pushGroup("different")
            case "deactivate": handle.deactivate(); await handle.activate()
            default: handle.setWatched(false, screenVisible: false)
            }
            await gate.release()
            for _ in 0..<100 {
                if await gate.returned { break }
                await Task.yield()
            }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertNil(handle.pages["all"], change)
            XCTAssertFalse(handle.groupPath.contains("all"), change)
        }
    }

    func testPendingHeaderRepliesCannotApplyAfterTheSelectionContextChanges() async throws {
        for change in ["navigation", "choice", "inverse", "deactivate", "refresh", "action"] {
            let gate = SelectionInventoryGate(), handle = try await sessionHandle(gate: gate)
            defer { handle.deactivate() }
            var page = try XCTUnwrap(handle.screen)
            page.selection?.sections = [.init(id: "category", title: "Category", rows: ["one"], pageID: "all")]
            let group = try XCTUnwrap(handle.pageSelection(page, id: "category"))
            handle.toggleAll("category", in: group)
            for _ in 0..<100 {
                if await gate.requested { break }
                await Task.yield()
            }
            let requested = await gate.requested
            XCTAssertTrue(requested)
            switch change {
            case "navigation": handle.pushGroup("different")
            case "choice": handle.toggle("one", in: group)
            case "inverse": handle.toggleAll("category", in: group)
            case "deactivate": handle.deactivate(); await handle.activate()
            case "refresh": await handle.refresh()
            default: _ = await handle.perform(try XCTUnwrap(group.selection?.action))
            }
            await gate.release()
            for _ in 0..<100 {
                if await gate.returned { break }
                await Task.yield()
            }
            // Let the MainActor continuation handle the delivered reply after the gate resumed.
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(handle.chosen["disk-files"] ?? [], change == "choice" ? ["one"] : [], change)
        }
    }

    func testFinishedSessionFilesClearGloballyAndNeverReappearOnAnotherPage() async throws {
        let handle = try await sessionHandle(); defer { handle.deactivate() }
        let group = try XCTUnwrap(handle.activeSelection)
        handle.toggle("one", in: group)
        handle.pushGroup("unrelated")
        _ = await handle.perform(try XCTUnwrap(group.selection?.action), extraParameters: ["ids": "one"])
        XCTAssertTrue(handle.checked(try XCTUnwrap(handle.activeSelection)).isEmpty)
        handle.popGroup()
        XCTAssertTrue(handle.checked(try XCTUnwrap(handle.activeSelection)).isEmpty)
    }

    func testRenderSelectionOverviewAtCompactAndWideSizes() async throws {
        guard let output = ProcessInfo.processInfo.environment["MACSPACE_SNAPSHOT_DIR"] else { throw XCTSkip("Set MACSPACE_SNAPSHOT_DIR for native render verification") }
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in FileSelectionModule(reads: SelectionPageReads()) })
        await handle.activate(); defer { handle.deactivate() }
        handle.toggle("file:0", in: try XCTUnwrap(handle.activeSelection))
        for (name, size) in [("wide", CGSize(width: 1448, height: 900)), ("compact", CGSize(width: 700, height: 490))] {
            if let selection = handle.activeSelection, !handle.checked(selection).contains("file:0") { handle.toggle("file:0", in: selection) }
            let view = NSHostingView(rootView: ScreenView(handle: handle, tint: .blue).frame(width: size.width, height: size.height).foregroundStyle(.white).background(TileBackdrop(tint: .blue)))
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -5000, y: 0), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
            try await Task.sleep(for: .seconds(1.5))
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("disk-selection-\(name).png"))
            }
            window.close()
        }
    }
}
