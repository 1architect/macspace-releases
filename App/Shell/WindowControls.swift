import AppKit
import SwiftUI

/// The dashboard's ✕ in the glass window, which has no title bar and so none of the window's own buttons: under the pointer its
/// glass grows into one pill that also holds Minimize and Zoom, and shrinks back to the ✕ when the pointer leaves.
struct WindowControls: View {
    let close: () -> Void
    @State private var expanded = false
    @State private var window = WindowBox()
    @State private var zoomed = false
    @Environment(\.design) private var design

    static let diameter = GlassCircleButton.diameter

    var body: some View {
        HStack(spacing: 0) {
            control("xmark", glyph: 12, help: String(localized: "Close"), action: close)
            if expanded {
                control("minus", glyph: 12, help: String(localized: "Minimize")) { window.window.map(Self.minimize) }
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                control(zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", glyph: 13,
                        help: zoomed ? String(localized: "Restore") : String(localized: "Maximize")) {
                    if let window = window.window { zoomed = Self.toggleZoom(window) }
                }
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .foregroundStyle(design.ink)
        .frame(height: Self.diameter)
        .background(alignment: .leading) {
            GlassGround(width: Self.diameter * (expanded ? 3 : 1), height: Self.diameter)
        }
        .background { WindowReader(box: window) }
        .contentShape(Capsule())
        .onHover { hovering in
            if hovering, let window = window.window { zoomed = Self.isZoomed(window) }
            expanded = hovering
        }
        .animation(Theme.layout, value: expanded)
        .animation(Theme.press, value: zoomed)
    }

    private func control(_ symbol: String, glyph: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .fontWeight(.medium)
                .frame(width: glyph, height: glyph)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(RoundedRectangle(cornerRadius: Self.diameter / 2, style: .continuous))
        }
        .buttonStyle(ControlStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    /// One button of the pill: a light under the pointer and a press, over the pill's shared glass.
    private struct ControlStyle: ButtonStyle {
        @State private var hovering = false

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            configuration.label
                .opacity(pressed ? 0.55 : 1)
                .background {
                    RoundedRectangle(cornerRadius: (WindowControls.diameter - 8) / 2, style: .continuous)
                        .fill(.white.opacity(hovering ? (pressed ? 0.06 : 0.12) : 0))
                        .padding(4)
                }
                .scaleEffect(pressed ? 0.88 : 1)
                .onHover { hovering = $0 }
                .animation(Theme.press, value: pressed)
                .animation(Theme.hover, value: hovering)
        }
    }

    /// Into the Dock. A window with no title bar is not miniaturizable unless told it is.
    static func minimize(_ window: NSWindow) {
        window.styleMask.insert(.miniaturizable)
        window.miniaturize(nil)
    }

    /// Whether the window fills its screen's visible area (the screen less the menu bar and the Dock).
    static func isZoomed(_ window: NSWindow) -> Bool {
        guard let visible = window.screen?.visibleFrame else { return false }
        return abs(window.frame.minX - visible.minX) < 2 && abs(window.frame.minY - visible.minY) < 2
            && abs(window.frame.width - visible.width) < 2 && abs(window.frame.height - visible.height) < 2
    }

    /// Fills the screen's visible area, or goes back to the size and place it had before. Returns whether it is now zoomed. AppKit's
    /// own zoom does nothing for a window without a title bar.
    @discardableResult
    static func toggleZoom(_ window: NSWindow) -> Bool {
        guard let visible = window.screen?.visibleFrame else { return false }
        if isZoomed(window) {
            let restored = unzoomedFrames[window.windowNumber] ?? centered(in: visible, size: CGSize(width: visible.width * 0.6, height: visible.height * 0.7))
            unzoomedFrames[window.windowNumber] = nil
            window.setFrame(restored, display: true, animate: true)
            return false
        }
        unzoomedFrames[window.windowNumber] = window.frame
        window.setFrame(visible, display: true, animate: true)
        return true
    }

    private static func centered(in rect: CGRect, size: CGSize) -> CGRect {
        CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Where each window was before it was zoomed, by window number.
    @MainActor private static var unzoomedFrames: [Int: CGRect] = [:]
}

/// The window a view is in, kept weakly.
final class WindowBox {
    weak var window: NSWindow?
}

/// Tells `box` which window it is in.
private struct WindowReader: NSViewRepresentable {
    let box: WindowBox

    final class ReaderView: NSView {
        var box: WindowBox?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.box = box
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.box = box
        if box.window == nil { box.window = nsView.window }
    }
}
