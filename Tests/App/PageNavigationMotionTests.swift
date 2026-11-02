import AppKit
import MacSpaceSdk
import SwiftUI
import XCTest
@testable import MacSpaceApp

@MainActor
final class PageNavigationMotionTests: XCTestCase {
    private final class Navigation: ObservableObject {
        @Published var covered = false
        @Published var showsPage = false
    }

    private struct Stack: View {
        @ObservedObject var navigation: Navigation
        let width: CGFloat

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.black
                if navigation.showsPage {
                    Page(navigation: navigation, width: width)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                // A reference driven by the same parent transaction, sampled in the same
                // frame. Comparing wall-clock sleeps across windows is sensitive to rendering load.
                Rectangle().fill(Color(red: 0, green: 1, blue: 0)).frame(width: 10, height: 10)
                    .offset(x: navigation.showsPage ? 0 : width + 200)
                    .opacity(navigation.showsPage ? 1 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .zIndex(2)
            }
            .frame(width: width + 200, height: 650)
        }
    }

    func testNewCompactAndWidePagesSlideAsOneSurface() async throws {
        _ = NSApplication.shared
        for width: CGFloat in [700, 1448] {
            let navigation = Navigation()
            let host = NSHostingView(rootView: Stack(navigation: navigation, width: width))
            let window = NSWindow(contentRect: CGRect(x: -5000, y: 0, width: width + 200, height: 650),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(150))
            withAnimation(.linear(duration: 1)) { navigation.showsPage = true }
            try await Task.sleep(for: .milliseconds(650))
            let arriving = try edges(host, reference: true)
            try await Task.sleep(for: .milliseconds(500))
            let settled = try edges(host, reference: true)
            try assertTogether(settled, arriving, direction: 1, width: width)
            XCTAssertEqual(arriving[0] - settled[0], arriving[3] - settled[3], accuracy: 2,
                           "The complete page must follow the parent navigation animation at width \(width)")
            print("PAGE_NAVIGATION width=\(width) arriving=\(arriving) settled=\(settled)")
        }
    }

    private struct Page: View {
        @ObservedObject var navigation: Navigation
        let width: CGFloat

        var body: some View {
            WidgetForm(widgets: [.list(ListWidget(id: "list", title: "Section", rows: [
                Row(id: "row", title: "A visible list item", trailing: "100 MB")
            ]))], handler: { _, _, _, _ in nil }, allowsGraphBesideList: true) {
                VStack(spacing: 10) {
                    Rectangle().fill(.blue).frame(height: 150)
                    Rectangle().fill(.red).frame(width: 120, height: 14)
                }
                .geometryGroup()
            }
            .modifier(PageScrollArea(hasFooter: false))
            .modifier(StackedPage(covered: navigation.covered))
            .frame(width: width, height: 650)
            .padding(.horizontal, 100)
            .foregroundStyle(.white)
            .background(.black)
            .environment(\.colorScheme, .dark)
        }
    }

    func testCompactAndWidePagesMoveGraphLegendAndListTogetherForwardAndBack() async throws {
        _ = NSApplication.shared
        for width: CGFloat in [700, 1448] {
            let navigation = Navigation()
            let host = NSHostingView(rootView: Page(navigation: navigation, width: width))
            let window = NSWindow(contentRect: CGRect(x: -5000, y: 0, width: width + 200, height: 650),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(300))
            let start = try edges(host)
            withAnimation(.linear(duration: 1)) { navigation.covered = true }
            try await Task.sleep(for: .milliseconds(350))
            let forward = try edges(host)
            try assertTogether(start, forward, direction: -1, width: width)
            try await Task.sleep(for: .milliseconds(800))
            withAnimation(.linear(duration: 1)) { navigation.covered = false }
            try await Task.sleep(for: .milliseconds(350))
            let back = try edges(host)
            XCTAssertLessThan(back[0], start[0] - 10)
            try assertTogether(start, back, direction: -1, width: width)
            try await Task.sleep(for: .milliseconds(800))
            let end = try edges(host)
            for index in start.indices { XCTAssertEqual(start[index], end[index], accuracy: 1) }
        }
    }

    private func assertTogether(_ start: [CGFloat], _ frame: [CGFloat], direction: CGFloat, width: CGFloat) throws {
        let travel = zip(start, frame).map { $1 - $0 }
        XCTAssertGreaterThan(travel[0] * direction, 10, "The page must move at width \(width)")
        XCTAssertEqual(travel[0], travel[1], accuracy: 2, "Graph and legend must move together at width \(width)")
        XCTAssertEqual(travel[0], travel[2], accuracy: 2, "Graph and list must move together at width \(width)")
    }

    private func edges(_ host: NSView, reference: Bool = false) throws -> [CGFloat] {
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        var result = [CGFloat?](repeating: nil, count: reference ? 4 : 3)
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            autoreleasepool {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                    let kind: Int?
                    if b > 0.1 && b > r * 2 && b > g * 1.2 { kind = 0 }
                    else if r > 0.1 && r > g * 2 && r > b * 2 { kind = 1 }
                    else if reference && g > 0.1 && g > r * 1.2 && g > b * 1.2 { kind = 3 }
                    else if min(r, g, b) > 0.18 && max(r, g, b) - min(r, g, b) < 0.03 { kind = 2 }
                    else { kind = nil }
                    if let kind, result[kind] == nil { result[kind] = CGFloat(x) / scale }
                }
            }
            if result.allSatisfy({ $0 != nil }) { break }
        }
        return try result.enumerated().map { try XCTUnwrap($0.element, "Missing page component \($0.offset) in rendered frame") }
    }
}
