import AppKit
import MacSpaceSdk
import SwiftUI
import XCTest
@testable import MacSpaceApp

@MainActor
final class ModuleScrollTests: XCTestCase {
    private final class GraphProbe {
        var frame = CGRect.zero
    }

    func testWideGraphStaysFixedAndCompactGraphScrollsWithTheRows() async throws {
        _ = NSApplication.shared
        for width: CGFloat in [780, 1448] {
            let probe = GraphProbe()
            let rows = (0..<60).map { Row(id: "row:\($0)", title: "Item \($0)", trailing: "100 MB") }
            let root = WidgetForm(widgets: [.list(ListWidget(id: "items", title: "Items", rows: rows))],
                                  handler: { _, _, _, _ in nil }, allowsGraphBesideList: true) {
                Rectangle().fill(.blue).frame(height: 150)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.frame = $0 }
            }
            .modifier(PageScrollArea(hasFooter: true))
            .frame(width: width, height: 730)
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: CGRect(x: -5000, y: 0, width: width, height: 730),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.orderOut(nil); window.close() }
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let scrolls = scrollViews(in: hosting).filter { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 200 }
            XCTAssertEqual(scrolls.count, 1, "Exactly one scroll view, containing the list")
            let scroll = try XCTUnwrap(scrolls.first)
            let before = probe.frame
            XCTAssertGreaterThan(before.width, 100)
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: CGPoint(x: origin.x, y: origin.y + 250))
            scroll.reflectScrolledClipView(scroll.contentView)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, origin.y + 200, "The list really scrolled")
            if width >= ModulePageLayout.minimumSideViewportWidth {
                XCTAssertEqual(probe.frame.minY, before.minY, accuracy: 0.5, "Wide graph stays fixed")
                XCTAssertEqual(probe.frame.minX, before.minX, accuracy: 0.5)
            } else {
                XCTAssertGreaterThan(abs(probe.frame.minY - before.minY), 200, "Compact graph scrolls normally")
            }
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
