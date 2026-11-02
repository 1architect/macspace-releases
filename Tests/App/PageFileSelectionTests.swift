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
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .init(outcome: .succeeded, message: "Done") }
}

@MainActor
final class PageFileSelectionTests: XCTestCase {
    func testRootAndMoreShareChoicesAndCachedReopenIsImmediateAndBounded() async throws {
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first), reads = SelectionPageReads()
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in FileSelectionModule(reads: reads) })
        await handle.activate(); defer { handle.deactivate() }
        let root = try XCTUnwrap(handle.activeSelection)
        handle.toggle("file:0", in: root)
        handle.pushGroup("more")
        for _ in 0..<100 where handle.groupPath.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
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

    func testRenderSelectionOverviewAtCompactAndWideSizes() async throws {
        guard let output = ProcessInfo.processInfo.environment["MACSPACE_SNAPSHOT_DIR"] else { throw XCTSkip("Set MACSPACE_SNAPSHOT_DIR for native render verification") }
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Test", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in FileSelectionModule(reads: SelectionPageReads()) })
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
