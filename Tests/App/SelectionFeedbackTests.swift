import Foundation
import XCTest
import MacSpaceSdk
import MacSpacePlatform
import SwiftUI
@testable import MacSpaceApp

private actor SelectionFeedbackControl {
    static let sizes: [String: UInt64] = ["one": 600_000_000, "two": 400_000_000]
    private var snapshots: [String: Set<String>] = [:]
    private var editContinuation: CheckedContinuation<Void, Never>?
    private var removalContinuation: CheckedContinuation<Void, Never>?
    private var holdEdit = false
    private(set) var editing = false
    private(set) var removing = false
    private(set) var readsDuringRemoval = 0
    func holdNextEdit() { holdEdit = true }
    func releaseEdit() { editContinuation?.resume(); editContinuation = nil }
    func releaseRemoval() { removalContinuation?.resume(); removalContinuation = nil }
    func resolve(_ request: SelectionBulkRequest) async -> SelectionBulk {
        if request.operation == "toggle", holdEdit {
            holdEdit = false; editing = true
            await withCheckedContinuation { editContinuation = $0 }
            editing = false
        }
        if removing && ["read", "membership"].contains(request.operation) { readsDuringRemoval += 1 }
        var chosen = request.token.flatMap { snapshots[$0] } ?? []
        if request.operation == "toggle", let id = request.toggledID {
            if !chosen.insert(id).inserted { chosen.remove(id) }
        }
        let token = ["read", "membership"].contains(request.operation) ? request.token ?? UUID().uuidString : UUID().uuidString
        snapshots[token] = chosen
        return .init(token: token, count: UInt64(chosen.count), bytes: chosen.compactMap { Self.sizes[$0] }.reduce(0, +), checked: request.visible.filter(chosen.contains),
            unavailableReason: removing ? "Selected files changed or are unavailable. Review your selection again." : nil)
    }
    func remove(progress: @escaping ProgressSink) async {
        removing = true
        progress(.init(fraction: 0.5, message: "Freeing space", finished: ["one"]))
        await withCheckedContinuation { removalContinuation = $0 }
        removing = false
    }
}
private struct SelectionFeedbackModule: MacSpaceModule {
    let control: SelectionFeedbackControl
    init() { control = SelectionFeedbackControl() }
    init(_ control: SelectionFeedbackControl) { self.control = control }
    var selection: Selection {
        Selection(action: Action(id: "freeFiles", title: "Free selected"), choices: SelectionFeedbackControl.sizes,
                  scope: "disk-files", partial: true, session: true, reviewed: ["one": "first", "two": "second"], bulkResolver: "selection:")
    }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Disk", status: "Ready") }
    func screen(context: ModuleContext) async -> Screen {
        Screen(title: "Files", widgets: [.list(.init(id: "files", title: "Files", rows: [.init(id: "one", title: "One"), .init(id: "two", title: "Two")]))], selection: selection)
    }
    func page(id: String, context: ModuleContext) async -> Screen? {
        guard let request = SelectionBulkRequest(pageID: id) else { return nil }
        var resolved = selection; resolved.choices = [:]; resolved.bulk = await control.resolve(request)
        return Screen(title: "Files", widgets: [], selection: resolved)
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        await control.remove(progress: progress)
        return .init(outcome: .succeeded, message: "Freed selected files", freedBytes: 100_000_000,
            presentation: .init(tile: Tile(title: "Disk", status: "Ready"), screen: Screen(title: "Files", widgets: [])), removedBytes: 1_000_000_000)
    }
}
@MainActor
final class SelectionFeedbackTests: XCTestCase {
    private func makeHandle(_ control: SelectionFeedbackControl, directory: URL) async throws -> ModuleHandle {
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in SelectionFeedbackModule(control) })
        await handle.activate()
        return handle
    }
    func testSelectingAndDeselectingKeepIdlePillAndImmediatelyUpdateItsTotal() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = SelectionFeedbackControl(), handle = try await makeHandle(control, directory: directory)
        defer { handle.deactivate() }
        await control.holdNextEdit()
        handle.toggle("one", in: try XCTUnwrap(handle.activeSelection))
        XCTAssertEqual(handle.activeSelection?.selection?.bulk?.bytes, 600_000_000)
        XCTAssertTrue(handle.isEditingSelection)
        guard case let .idle(first)? = ActionDock(handle: handle, isVisible: .constant(false)).phase else { return XCTFail("A checkbox change must keep the Free selected pill") }
        XCTAssertTrue(first.title.contains(ByteFormat.string(600_000_000)))
        for _ in 0..<100 { if await control.editing { break }; await Task.yield() }
        await control.releaseEdit()
        for _ in 0..<100 where handle.isEditingSelection { await Task.yield() }
        await control.holdNextEdit()
        handle.toggle("two", in: try XCTUnwrap(handle.activeSelection))
        XCTAssertEqual(handle.activeSelection?.selection?.bulk?.bytes, 1_000_000_000)
        guard case let .idle(second)? = ActionDock(handle: handle, isVisible: .constant(false)).phase else { return XCTFail("Adding another item must grow the same pill") }
        XCTAssertTrue(second.title.contains(ByteFormat.string(1_000_000_000)))
        for _ in 0..<100 { if await control.editing { break }; await Task.yield() }
        await control.releaseEdit()
        for _ in 0..<100 where handle.isEditingSelection { await Task.yield() }
        await control.holdNextEdit()
        handle.toggle("one", in: try XCTUnwrap(handle.activeSelection))
        XCTAssertEqual(handle.activeSelection?.selection?.bulk?.bytes, 400_000_000)
        guard case .idle? = ActionDock(handle: handle, isVisible: .constant(false)).phase else { return XCTFail("Deselecting must not show Loading") }
        for _ in 0..<100 { if await control.editing { break }; await Task.yield() }
        await control.releaseEdit()
        for _ in 0..<100 where handle.isEditingSelection { await Task.yield() }
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.activeSelection)), ["two"])
    }
    func testRapidCheckboxEditsRemainSerializedAndTheDisplayedTotalDoesNotFlashLoading() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = SelectionFeedbackControl(), handle = try await makeHandle(control, directory: directory)
        defer { handle.deactivate() }
        await control.holdNextEdit()
        handle.toggle("one", in: try XCTUnwrap(handle.activeSelection))
        handle.toggle("two", in: try XCTUnwrap(handle.activeSelection))
        XCTAssertEqual(handle.activeSelection?.selection?.bulk?.bytes, 1_000_000_000)
        guard case .idle? = ActionDock(handle: handle, isVisible: .constant(false)).phase else { return XCTFail("Rapid edits retain the selected-size action") }
        for _ in 0..<100 { if await control.editing { break }; await Task.yield() }
        await control.releaseEdit()
        for _ in 0..<100 where handle.isEditingSelection { await Task.yield() }
        XCTAssertEqual(handle.activeSelection?.selection?.bulk?.bytes, 1_000_000_000)
        XCTAssertEqual(handle.checked(try XCTUnwrap(handle.activeSelection)), ["one", "two"])
    }

    func testDeletionProgressCannotRevalidateRemovedFilesAndCompletionUsesRemovedTotal() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let control = SelectionFeedbackControl(), handle = try await makeHandle(control, directory: directory)
        defer { handle.deactivate() }
        handle.toggle("one", in: try XCTUnwrap(handle.activeSelection))
        for _ in 0..<100 where handle.isEditingSelection { await Task.yield() }
        handle.toggle("two", in: try XCTUnwrap(handle.activeSelection))
        for _ in 0..<100 where handle.isEditingSelection { await Task.yield() }
        let group = try XCTUnwrap(handle.activeSelection), token = try XCTUnwrap(group.selection?.bulk?.token)
        let action = try XCTUnwrap(handle.selectedAction)
        XCTAssertEqual(action.parameters["selectionToken"], token)
        let task = Task { await handle.perform(action) }
        for _ in 0..<100 { if await control.removing { break }; await Task.yield() }
        XCTAssertTrue(handle.isCleaning); XCTAssertTrue(handle.bulkMembershipKey.isEmpty)
        await handle.refreshBulkMembership()
        let staleReads = await control.readsDuringRemoval
        XCTAssertEqual(staleReads, 0, "Deleted targets must not be validated against the old frozen token")
        guard case .working? = ActionDock(handle: handle, isVisible: .constant(false)).phase else { return XCTFail("Progress remains visible during removal") }
        await control.releaseRemoval()
        let result = await task.value
        XCTAssertEqual(result?.outcome, .succeeded); XCTAssertNil(handle.lastResult)
        XCTAssertEqual(handle.allDoneRemoved, 1_000_000_000)
        XCTAssertEqual(handle.allDoneFreed, 100_000_000, "Actual volume reclamation remains a distinct measured value")
        XCTAssertTrue(handle.isShowingCompletion)
    }
}
