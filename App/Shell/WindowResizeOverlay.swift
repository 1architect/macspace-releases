import AppKit
import SwiftUI

/// Explicit hit targets for the borderless window. The middle passes through to the canvas;
/// the perimeter reaches four points inside the visible glass as well as into the outside band.
struct WindowResizeOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowResizeView { WindowResizeView() }
    func updateNSView(_ view: WindowResizeView, context: Context) {}
}

struct WindowResizeEdge: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1)
    static let right = Self(rawValue: 2)
    static let bottom = Self(rawValue: 4)
    static let top = Self(rawValue: 8)

    static func target(at point: NSPoint, in bounds: NSRect, band: CGFloat, corner: CGFloat) -> Self {
        guard bounds.contains(point) else { return [] }
        let left = point.x < bounds.minX + band
        let right = point.x >= bounds.maxX - band
        let bottom = point.y < bounds.minY + band
        let top = point.y >= bounds.maxY - band
        guard left || right || bottom || top else { return [] }
        var edge: Self = []
        if point.x < bounds.minX + corner { edge.insert(.left) }
        if point.x >= bounds.maxX - corner { edge.insert(.right) }
        if point.y < bounds.minY + corner { edge.insert(.bottom) }
        if point.y >= bounds.maxY - corner { edge.insert(.top) }
        return edge
    }

    /// Clamp each moving edge while keeping its opposite edge fixed, including at minimum size.
    func frame(from original: NSRect, delta: NSPoint, minimum: NSSize, maximum: NSSize) -> NSRect {
        var result = original
        if contains(.left) || contains(.right) {
            result.size.width = min(maximum.width, max(minimum.width, original.width + (contains(.left) ? -delta.x : delta.x)))
            if contains(.left) { result.origin.x = original.maxX - result.width }
        }
        if contains(.bottom) || contains(.top) {
            result.size.height = min(maximum.height, max(minimum.height, original.height + (contains(.bottom) ? -delta.y : delta.y)))
            if contains(.bottom) { result.origin.y = original.maxY - result.height }
        }
        return result
    }

    var cursorPosition: NSCursor.FrameResizePosition {
        switch self {
        case [.left, .bottom]: return .bottomLeft
        case [.right, .bottom]: return .bottomRight
        case [.left, .top]: return .topLeft
        case [.right, .top]: return .topRight
        case .left: return .left
        case .right: return .right
        case .bottom: return .bottom
        default: return .top
        }
    }
}

final class WindowResizeView: NSView {
    private var drag: (edge: WindowResizeEdge, point: NSPoint, frame: NSRect)?
    private var band: CGFloat { Theme.resizeMargin + 4 }
    private let corner: CGFloat = 28
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func target(_ point: NSPoint) -> WindowResizeEdge {
        guard let window, window.styleMask.contains(.resizable), !window.styleMask.contains(.fullScreen) else { return [] }
        return WindowResizeEdge.target(at: point, in: bounds, band: band, corner: corner)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        target(convert(point, from: superview)).isEmpty ? nil : self
    }

    override func draw(_ dirtyRect: NSRect) {
        // Clear pixels in a transparent window can pass clicks to another app before NSView hit testing.
        // Paint only the perimeter with a near-transparent fill so it participates in window hit testing.
        NSColor.black.withAlphaComponent(0.01).setFill()
        let perimeter = NSBezierPath(rect: bounds)
        perimeter.appendRect(bounds.insetBy(dx: band, dy: band))
        perimeter.windingRule = .evenOdd
        perimeter.fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let xs = [bounds.minX, bounds.minX + corner, bounds.maxX - corner, bounds.maxX]
        let ys = [bounds.minY, bounds.minY + corner, bounds.maxY - corner, bounds.maxY]
        for x in 0..<3 {
            for y in 0..<3 where x != 1 || y != 1 {
                let cell = NSRect(x: xs[x], y: ys[y], width: xs[x + 1] - xs[x], height: ys[y + 1] - ys[y])
                // Split corner cells into the same L-shaped target used for hit testing.
                let strips = [NSRect(x: bounds.minX, y: bounds.minY, width: band, height: bounds.height),
                              NSRect(x: bounds.maxX - band, y: bounds.minY, width: band, height: bounds.height),
                              NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: band),
                              NSRect(x: bounds.minX, y: bounds.maxY - band, width: bounds.width, height: band)]
                for strip in strips {
                    let rect = cell.intersection(strip)
                    guard !rect.isEmpty else { continue }
                    let edge = target(NSPoint(x: rect.midX, y: rect.midY))
                    guard !edge.isEmpty else { continue }
                    addCursorRect(rect, cursor: .frameResize(position: edge.cursorPosition, directions: .all))
                }
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let edge = target(convert(event.locationInWindow, from: nil))
        guard !edge.isEmpty else { return }
        window.makeKeyAndOrderFront(nil)
        drag = (edge, window.convertPoint(toScreen: event.locationInWindow), window.frame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let drag else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let contentMinimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        let minimum = NSSize(width: max(window.minSize.width, contentMinimum.width), height: max(window.minSize.height, contentMinimum.height))
        let contentMaximum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMaxSize)).size
        let maximum = NSSize(width: max(minimum.width, min(window.maxSize.width, contentMaximum.width)),
                             height: max(minimum.height, min(window.maxSize.height, contentMaximum.height)))
        window.setFrame(drag.edge.frame(from: drag.frame, delta: NSPoint(x: point.x - drag.point.x, y: point.y - drag.point.y),
                                        minimum: minimum, maximum: maximum), display: true)
    }

    override func mouseUp(with event: NSEvent) { drag = nil }
}
