import AppKit
import XCTest
import SwiftUI
@testable import MacSpaceApp

@MainActor
final class ShadowTrackingTests: XCTestCase {
    private final class RadiusState: ObservableObject { @Published var radius: CGFloat = 28 }
    private struct AnimatedShadow: View {
        @ObservedObject var state: RadiusState
        var body: some View {
            Color.clear
                .background(GlassWindowConfigurator(shadow: false, radius: state.radius, cornerStyle: .constant(WindowCornerStyle())))
                .animation(.linear(duration: 1), value: state.radius)
        }
    }

    func testShadowReceivesTheWindowAnimationsIntermediateRadius() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let frameKey = "NSWindow Frame " + GlassWindowConfigurator.ConfiguringView.frameName
        let saved = defaults.object(forKey: frameKey)
        let state = RadiusState()
        let host = NSHostingView(rootView: AnimatedShadow(state: state))
        let main = NSWindow(contentRect: CGRect(x: -5000, y: 0, width: 700, height: 490),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.contentView = host
        main.orderBack(nil)
        defer {
            main.setFrameAutosaveName("")
            main.close()
            if let saved { defaults.set(saved, forKey: frameKey) } else { defaults.removeObject(forKey: frameKey) }
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let configuring = try XCTUnwrap(configurators(in: host).first)
        XCTAssertEqual(configuring.radius, 28)
        state.radius = 16
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(configuring.radius, 16)
        XCTAssertLessThan(configuring.radius, 28, "The shadow must receive interpolated radii rather than jumping to the target")
        let shadow = try XCTUnwrap(main.childWindows?.compactMap { $0 as? ShadowWindow }.first)
        let caster = try XCTUnwrap(shadow.contentView?.layer?.sublayers?.first?.sublayers?.first)
        let glass = CGRect(x: main.frame.minX - shadow.frame.minX, y: main.frame.minY - shadow.frame.minY,
                           width: main.frame.width, height: main.frame.height)
        XCTAssertEqual(caster.shadowPath, ShadowWindow.glassPath(glass, radius: configuring.radius))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(configuring.radius, 16, accuracy: 0.01)
    }

    private func configurators(in view: NSView) -> [GlassWindowConfigurator.ConfiguringView] {
        (view as? GlassWindowConfigurator.ConfiguringView).map { [$0] } ?? view.subviews.flatMap { configurators(in: $0) }
    }

    func testResizeAndRadiusChangesClearStalePathsAndMatchTheCurrentGlass() throws {
        _ = NSApplication.shared
        let main = NSWindow(contentRect: CGRect(x: 200, y: 160, width: 700, height: 490),
                            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        let shadow = ShadowWindow()
        defer { shadow.close(); main.close() }
        shadow.follow(main, radius: 28)
        let container = try XCTUnwrap(shadow.contentView?.layer?.sublayers?.first)
        let caster = try XCTUnwrap(container.sublayers?.first)
        let cutout = try XCTUnwrap(container.mask as? CAShapeLayer)
        // Reproduce an in-flight old-radius animation when another resize arrives.
        caster.add(CABasicAnimation(keyPath: "shadowPath"), forKey: "shadowPath")
        cutout.add(CABasicAnimation(keyPath: "path"), forKey: "path")
        main.setFrame(CGRect(x: 160, y: 130, width: 920, height: 620), display: false)
        for radius: CGFloat in [24, 20, 16, 20, 28] {
            shadow.follow(main, radius: radius)
            XCTAssertNil(caster.animation(forKey: "shadowPath"))
            XCTAssertNil(cutout.animation(forKey: "path"))
            let glass = CGRect(x: main.frame.minX - shadow.frame.minX, y: main.frame.minY - shadow.frame.minY,
                               width: main.frame.width, height: main.frame.height)
            XCTAssertEqual(caster.shadowPath, ShadowWindow.glassPath(glass, radius: radius))
            XCTAssertEqual(caster.frame.size, shadow.frame.size)
        }
        XCTAssertNotEqual(ShadowWindow.fade(room: 0, radius: 16), ShadowWindow.fade(room: 0, radius: 28))
    }
}
