import AppKit
import SwiftUI

/// Finishes the window the plain window style gives: clear behind the glass, a shadow that follows the glass, and resizable from
/// its edges.
struct GlassWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguringView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            KeyableWindow.adopt(window)
            window.styleMask.insert(.resizable)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.invalidateShadow()
        }
    }
}

/// The plain window style makes a borderless window, and AppKit never makes a borderless window key: Escape, Command-comma and
/// typing would not reach it. SwiftUI owns the window's class, so the window is moved to a subclass of it that can become key and main.
enum KeyableWindow {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var subclasses: [ObjectIdentifier: AnyClass] = [:]

    static func adopt(_ window: NSWindow) {
        guard !window.canBecomeKey else { return }
        let base: AnyClass = type(of: window)
        lock.lock()
        defer { lock.unlock() }
        var subclass = subclasses[ObjectIdentifier(base)]
        if subclass == nil {
            let name = "MacSpaceKeyable_" + NSStringFromClass(base)
            subclass = NSClassFromString(name) ?? {
                guard let made = objc_allocateClassPair(base, name, 0) else { return nil }
                let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
                let types = "c@:"
                class_addMethod(made, #selector(getter: NSWindow.canBecomeKey), imp_implementationWithBlock(yes), types)
                class_addMethod(made, #selector(getter: NSWindow.canBecomeMain), imp_implementationWithBlock(yes), types)
                objc_registerClassPair(made)
                return made
            }()
            subclasses[ObjectIdentifier(base)] = subclass
        }
        if let subclass { object_setClass(window, subclass) }
    }
}

/// The glass the tiles sit on. It blurs what is behind the window, and is the window's only edge.
struct GlassBackdrop: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.windowRadius, style: .continuous)
        Color.clear
            .glassEffect(.clear, in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
    }
}
