import AppKit
import SwiftUI
import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

private struct SelectionMotionModule: MacSpaceModule {
    let pageWide: Bool
    init() { pageWide = true }
    init(pageWide: Bool) { self.pageWide = pageWide }
    var rows: [Row] { [Row(id: "file", title: "A file", trailing: "100 MB", paths: ["/fixture/file"])] }
    var selection: Selection { Selection(action: Action(id: "free", title: "Free selected"), choices: ["file": 100_000_000], scope: pageWide ? "files" : nil) }
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Selection", status: "") }
    func screen(context: ModuleContext) async -> Screen {
        if pageWide { return Screen(title: "Selection", layout: .singleColumn, widgets: [.list(ListWidget(id: "files", rows: rows))], selection: selection) }
        return Screen(title: "Selection", widgets: [.list(ListWidget(id: "groups", rows: [Row(id: "files", title: "Selection", children: rows, selection: selection)]))])
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .failed("Read-only fixture") }
}

@MainActor
final class SelectionDockMotionTests: XCTestCase {
    private func yellowPixels(_ view: NSView) -> Int {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: image)
        var count = 0
        for y in stride(from: 0, to: image.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: image.pixelsWide, by: 4) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.65 && color.greenComponent > 0.3 && color.greenComponent < 0.85 && color.blueComponent < 0.35 { count += 1 }
            }
        }
        return count
    }
    func testPageWideAndCacheGroupSelectionShareDockArrivalAndDeparture() async throws {
        var curves: [[Int]] = []
        for pageWide in [false, true] {
            let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
            try Fixtures.writeBundle(Fixtures.manifest(), name: "Fixture", into: directory)
            let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
            let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in SelectionMotionModule(pageWide: pageWide) })
            await handle.activate(); defer { handle.deactivate() }
            if !pageWide { handle.pushGroup("files") }
            let view = NSHostingView(rootView: ScreenView(handle: handle, tint: .blue).frame(width: 700, height: 490).foregroundStyle(.white).background(TileBackdrop(tint: .blue)))
            let window = NSWindow(contentRect: CGRect(x: -5000, y: 0, width: 700, height: 490), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
            try await Task.sleep(for: .seconds(1))
            var curve = [yellowPixels(view)]
            let group = try XCTUnwrap(handle.activeSelection)
            withAnimation(ScreenView.choiceAnimation) { handle.toggle("file", in: group) }
            for delay in [80, 160, 600] { try await Task.sleep(for: .milliseconds(delay)); curve.append(yellowPixels(view)) }
            withAnimation(ScreenView.choiceAnimation) { handle.toggle("file", in: group) }
            for delay in [80, 160, 600] { try await Task.sleep(for: .milliseconds(delay)); curve.append(yellowPixels(view)) }
            XCTAssertEqual(curve.first, 0); XCTAssertEqual(curve.last, 0); XCTAssertGreaterThan(curve[3], 100)
            curves.append(curve); window.close()
        }
        let full = max(curves[0][3], curves[1][3])
        for i in curves[0].indices {
            XCTAssertLessThanOrEqual(abs(curves[0][i] - curves[1][i]), max(8, full / 4), "Selection dock motion must match the existing cache group at sample \(i)")
        }
        print("SELECTION_DOCK_MOTION cache=\(curves[0]) pageWide=\(curves[1])")
    }
}
