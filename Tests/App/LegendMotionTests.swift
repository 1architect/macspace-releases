import AppKit
import MacSpaceSdk
import SwiftUI
import XCTest
@testable import MacSpaceApp

@MainActor
final class LegendMotionTests: XCTestCase {
    private final class Motion: ObservableObject { @Published var offset: CGFloat = 0 }
    private struct MovingGraph: View {
        @ObservedObject var motion: Motion
        let hero: UsageBar
        var body: some View {
            HeroBlocks(usage: hero, tint: .blue)
                .environment(\.moduleGraphHeight, 150)
                .frame(width: 720)
                .offset(x: motion.offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(40)
                .frame(width: 1000, height: 420)
                .background(.black)
                .environment(\.colorScheme, .dark)
        }
    }

    func testLegendAndGraphTravelTogetherDuringPageMotion() async throws {
        _ = NSApplication.shared
        let labels = ["Gerenciado pelo macOS", "Arquivos compartilhados de apps", "Pode ser liberado", "Arquivos de suporte de apps"]
        let hero = UsageBar(id: "test", title: "", segments: labels.enumerated().map {
            UsageSegment(id: "\($0.offset)", label: $0.element, bytes: UInt64(4 - $0.offset) * 1_000_000_000, tone: .series($0.offset))
        })
        let motion = Motion()
        let host = NSHostingView(rootView: MovingGraph(motion: motion, hero: hero))
        let window = NSWindow(contentRect: CGRect(x: -5000, y: 0, width: 1000, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(1))
        let before = try snapshot(host, name: "legend-motion-start")
        withAnimation(.linear(duration: 1)) { motion.offset = 160 }
        try await Task.sleep(for: .milliseconds(350))
        let middle = try snapshot(host, name: "legend-motion-middle")
        try await Task.sleep(for: .milliseconds(750))
        let after = try snapshot(host, name: "legend-motion-end")
        let graphStart = try leadingInk(before, band: 70..<170)
        let legendStart = try leadingInk(before, band: 225..<280)
        let graphTravel = try leadingInk(middle, band: 70..<170) - graphStart
        let legendTravel = try leadingInk(middle, band: 225..<280) - legendStart
        XCTAssertEqual(graphTravel, legendTravel, accuracy: 2, "The legend moves with the graph in intermediate frames")
        XCTAssertEqual(try leadingInk(after, band: 70..<170) - graphStart, 160, accuracy: 2)
        XCTAssertEqual(try leadingInk(after, band: 225..<280) - legendStart, 160, accuracy: 2)
    }

    private func snapshot(_ host: NSView, name: String) throws -> NSBitmapImageRep {
        host.displayIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        if let path = ProcessInfo.processInfo.environment["MACSPACE_SNAPSHOT_DIR"] {
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
        }
        return image
    }

    private func leadingInk(_ bitmap: NSBitmapImageRep, band: Range<Int>) throws -> CGFloat {
        let scale = CGFloat(bitmap.pixelsWide) / 1000
        for x in 0..<bitmap.pixelsWide {
            for y in Int(CGFloat(band.lowerBound) * scale)..<Int(CGFloat(band.upperBound) * scale) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent + color.greenComponent + color.blueComponent > 0.2 {
                    return CGFloat(x) / scale
                }
            }
        }
        throw NSError(domain: "MissingRenderedGraph", code: 1)
    }
}
