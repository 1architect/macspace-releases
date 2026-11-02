import AppKit
import SwiftUI

/// Per-window state: a second floating window must not inherit the first window's tiled corners.
struct WindowCornerStyle: Equatable {
    var attached = false
    var nativeRadius: CGFloat = 16
    var fullScreen = false

    var windowRadius: CGFloat { attached ? (fullScreen ? 0 : nativeRadius) : Theme.windowRadius }
    var tileRadius: CGFloat { attached ? 10 : Theme.tileRadius }
    static let duration = 0.32

    /// AppKit does not expose a desktop tile-state flag. Match complete half/quarter/fill rectangles,
    /// including macOS's optional tiling margins, rather than mistaking any window near an edge for a tile.
    static func isAttached(frame: CGRect, visible: CGRect, fullScreen: Bool = false) -> Bool {
        if fullScreen { return true }
        guard visible.width > 0, visible.height > 0 else { return false }
        let tolerance: CGFloat = 2
        for margin: CGFloat in [0, 4, 8, 12, 16] {
            let area = visible.insetBy(dx: margin, dy: margin)
            let halfWidth = (area.width - margin) / 2
            let halfHeight = (area.height - margin) / 2
            let widths = [(area.minX, area.width), (area.minX, halfWidth), (area.maxX - halfWidth, halfWidth)]
            let heights = [(area.minY, area.height), (area.minY, halfHeight), (area.maxY - halfHeight, halfHeight)]
            for (x, width) in widths {
                for (y, height) in heights {
                    if abs(frame.minX - x) <= tolerance && abs(frame.minY - y) <= tolerance
                        && abs(frame.width - width) <= tolerance && abs(frame.height - height) <= tolerance { return true }
                }
            }
        }
        return false
    }

    @MainActor static func read(_ window: NSWindow) -> Self {
        let fullScreen = window.styleMask.contains(.fullScreen)
        return Self(attached: window.screen.map { isAttached(frame: window.frame, visible: $0.visibleFrame, fullScreen: fullScreen) } ?? fullScreen,
                    nativeRadius: NativeWindowCorners.radius, fullScreen: fullScreen)
    }
}

/// Resolve the current macOS default through its public concentric-corner API, with no private selectors.
@MainActor private enum NativeWindowCorners {
    final class Probe: NSView {
        override var cornerConfiguration: NSViewCornerConfiguration? { .corners(radius: .containerConcentric) }
    }
    static let radius: CGFloat = measure()

    private static func measure() -> CGFloat {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        guard let content = window.contentView else { return 16 }
        let probe = Probe(frame: content.bounds)
        content.addSubview(probe)
        content.layoutSubtreeIfNeeded()
        return probe.effectiveCornerRadii?.topLeft ?? 16
    }
}

extension EnvironmentValues {
    @Entry var windowCornerStyle = WindowCornerStyle()
}
