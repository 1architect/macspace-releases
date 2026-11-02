import AppKit
import MacSpaceSdk
import SwiftUI
import XCTest
@testable import MacSpaceApp

@MainActor
final class WideGraphLoadingTests: XCTestCase {
    private final class Reading: ObservableObject {
        @Published var loading = true
        @Published var hasRows = false
        var appearances = 0
        var graph = CGRect.zero
    }
    private struct Fixture: View {
        @ObservedObject var reading: Reading
        let width: CGFloat
        var body: some View {
            WidgetForm(widgets: reading.hasRows ? [.list(ListWidget(id: "rows", title: "Ready", rows: [Row(id: "one", title: "Ready item")]))] : [],
                       handler: { _, _, _, _ in nil }, allowsGraphBesideList: true, graphLoading: reading.loading,
                       cascadeOffset: 10) {
                Graph(reading: reading)
            }
            .modifier(PageScrollArea(hasFooter: true))
            .frame(width: width, height: 730)
            .foregroundStyle(.white)
            .background(.black)
            .environment(\.colorScheme, .dark)
            .environment(\.pageCascadeCount, 12)
        }
    }

    private struct Graph: View {
        let reading: Reading
        @Environment(\.moduleGraphHeight) private var height

        var body: some View {
            Rectangle().fill(.blue).frame(height: height ?? 220)
                .onAppear { reading.appearances += 1 }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { reading.graph = $0 }
        }
    }

    func testFullWidthGraphResizesBeforeListRevealsWithoutRecreatingTheGraph() async throws {
        _ = NSApplication.shared
        let reading = Reading()
        let host = NSHostingView(rootView: Fixture(reading: reading, width: 1448))
        let window = makeWindow(host, width: 1448)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let before = try snapshot(host, name: "loading-full-width")
        let normal = try XCTUnwrap(ModulePageLayout.graphArrangement(viewport: CGSize(width: 1448, height: 730), hasGraph: true))
        let fullWidth = reading.graph.width
        XCTAssertEqual(fullWidth, 1448 - 2 * PageInsets.side - 2 * PageInsets.formHeaderIndent, accuracy: 1)
        XCTAssertEqual(reading.graph.height, normal.graphHeight, accuracy: 1, "Loading already uses the final graph height")
        XCTAssertEqual(reading.appearances, 1)
        reading.hasRows = true
        reading.loading = false
        try await Task.sleep(for: .milliseconds(40))
        let middle = try snapshot(host, name: "loading-resizing")
        XCTAssertGreaterThan(try blueEdge(middle), try blueEdge(before) + 5, "The graph moves right during the existing resize spring")
        XCTAssertEqual(whitePixels(middle), 0, "List text must wait for the graph resize to finish")
        XCTAssertEqual(try blueHeight(middle), try blueHeight(before), accuracy: 1, "Only the graph width animates")
        try await Task.sleep(for: .milliseconds(200))
        let arriving = try snapshot(host, name: "loading-list-arriving")
        XCTAssertGreaterThan(whitePixels(arriving), 20, "List arrival must not wait for residual spring settling or the ten preceding legend items")
        try await Task.sleep(for: .seconds(2))
        let after = try snapshot(host, name: "loading-list-revealed")
        XCTAssertEqual(reading.graph.width, normal.graphWidth - 2 * PageInsets.formHeaderIndent, accuracy: 1)
        XCTAssertEqual(try blueHeight(after), try blueHeight(before), accuracy: 1)
        XCTAssertGreaterThan(whitePixels(after), 20, "The existing list reveal runs after resizing")
        XCTAssertGreaterThan(abs(try blueEdge(middle) - blueEdge(after)), 5,
                             "The intermediate graph is still resizing, including the existing spring's overshoot")
        XCTAssertEqual(reading.appearances, 1, "Resize the existing graph, do not replace it")

        // A refresh with existing rows cannot expand the graph over them.
        reading.loading = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reading.graph.width, normal.graphWidth - 2 * PageInsets.formHeaderIndent, accuracy: 1)
    }

    func testInterruptedLoadCannotRevealAnObsoleteListAndSmallViewsStayStacked() async throws {
        _ = NSApplication.shared
        for width: CGFloat in [780, 1448] {
            let reading = Reading()
            let host = NSHostingView(rootView: Fixture(reading: reading, width: width))
            let window = makeWindow(host, width: width)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            let initialWidth = reading.graph.width
            reading.hasRows = true
            reading.loading = false
            try await Task.sleep(for: .milliseconds(100))
            reading.hasRows = false
            reading.loading = true
            try await Task.sleep(for: .seconds(1.5))
            XCTAssertEqual(reading.graph.width, initialWidth, accuracy: 1)
            XCTAssertEqual(reading.appearances, 1)
        }
    }

    func testEmptyShellsDoNotReserveTheListButRealContentAndEmptyMessagesDo() {
        XCTAssertFalse(ModulePagePresentation.hasContent([.list(ListWidget(id: "empty", rows: []))]))
        XCTAssertFalse(ModulePagePresentation.hasContent([.section(SectionWidget(id: "empty", title: "Empty", widgets: []))]))
        XCTAssertTrue(ModulePagePresentation.hasContent([.list(ListWidget(id: "empty", emptyMessage: "No items", rows: []))]))
        XCTAssertTrue(ModulePagePresentation.hasContent([.list(ListWidget(id: "rows", rows: [Row(id: "one", title: "One")]))]))
    }

    func testReduceMotionUsesTheFinalLayoutWithoutWaitingForACompletion() {
        let state = WideGraphLoadingState()
        state.update(expand: true, active: true, reduceMotion: true)
        XCTAssertEqual(state.phase, .expanded)
        state.update(expand: false, active: true, reduceMotion: true)
        XCTAssertEqual(state.phase, .ready)
    }

    private func makeWindow(_ host: NSView, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -5000, y: 0, width: width, height: 730), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func snapshot(_ host: NSView, name: String) throws -> NSBitmapImageRep {
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["MACSPACE_SNAPSHOT_DIR"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
        }
        return bitmap
    }

    private func blueEdge(_ bitmap: NSBitmapImageRep) throws -> CGFloat {
        let scale = CGFloat(bitmap.pixelsWide) / 1448
        for x in 0..<bitmap.pixelsWide {
            if let color = bitmap.colorAt(x: x, y: Int(150 * scale))?.usingColorSpace(.deviceRGB),
               color.blueComponent > 0.6 && color.redComponent < 0.5 { return CGFloat(x) / scale }
        }
        throw NSError(domain: "MissingGraph", code: 1)
    }

    private func blueHeight(_ bitmap: NSBitmapImageRep) throws -> CGFloat {
        let scale = CGFloat(bitmap.pixelsWide) / 1448
        let pixels = (0..<bitmap.pixelsHigh).filter { y in
            guard let color = bitmap.colorAt(x: Int(1300 * scale), y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.blueComponent > 0.6 && color.redComponent < 0.5
        }
        return CGFloat(try XCTUnwrap(pixels.last) - XCTUnwrap(pixels.first) + 1) / scale
    }

    private func whitePixels(_ bitmap: NSBitmapImageRep) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / 1448
        var count = 0
        for x in stride(from: Int(50 * scale), to: Int(320 * scale), by: 2) {
            for y in stride(from: Int(100 * scale), to: Int(180 * scale), by: 2) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.7 && color.greenComponent > 0.7 && color.blueComponent > 0.7 { count += 1 }
            }
        }
        return count
    }
}
