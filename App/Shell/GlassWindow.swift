import AppKit
import SwiftUI

/// Finishes the window the plain window style gives: clear behind the glass, a shadow around the glass, and resizable from its edges.
///
/// The shadow is not the window's own. macOS works out the shadow of a transparent window from its content and did so again on every
/// frame anything in the window changed: about 15 points of GPU while the mouse moved over the tiles or a page scrolled. It is drawn
/// instead by a separate click-through window behind this one (`ShadowWindow`), which only redraws when the window is resized.
struct GlassWindowConfigurator: NSViewRepresentable {
    /// Whether the shadow shows: off while the window opens and closes, and with the temporary Window Shadow switch off.
    var shadow = true

    func makeNSView(context: Context) -> ConfiguringView { ConfiguringView() }
    func updateNSView(_ nsView: ConfiguringView, context: Context) {
        nsView.wantsShadow = shadow
    }

    final class ConfiguringView: NSView {
        var wantsShadow = true {
            didSet { if wantsShadow != oldValue { showShadow(animated: true) } }
        }
        private var shadowWindow: ShadowWindow?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tearDownShadow()
            guard let window else { return }
            KeyableWindow.adopt(window)
            window.styleMask.insert(.resizable)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = true
            // Set explicitly: left at its default, a transparent window lets clicks on its clear pixels through to the window behind,
            // so the rounded corners and the resize band around the glass selected the app behind instead of resizing.
            window.ignoresMouseEvents = false
            window.invalidateShadow()
            // The window could not become key when SwiftUI first showed it (it only can once adopted above), so it opened inactive and
            // its glass was drawn in the dimmed, unselected look until clicked. Make it key, with the app in front, once it is set up.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }

            let shadow = ShadowWindow()
            shadow.follow(window)
            window.addChildWindow(shadow, ordered: .below)
            shadowWindow = shadow
            showShadow(animated: false)
            // A child window moves with its parent by itself; it has to be told about a new size.
            for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        self.shadowWindow?.follow(window)
                    }
                })
            }
        }

        private func showShadow(animated: Bool) {
            guard let shadowWindow else { return }
            let alpha: CGFloat = wantsShadow ? 1 : 0
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = wantsShadow ? 0.3 : 0.15
                    shadowWindow.animator().alphaValue = alpha
                }
            } else {
                shadowWindow.alphaValue = alpha
            }
        }

        private func tearDownShadow() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            if let shadowWindow {
                shadowWindow.parent?.removeChildWindow(shadowWindow)
                shadowWindow.orderOut(nil)
            }
            shadowWindow = nil
        }
    }
}

/// A click-through window just larger than the main window, drawing a soft shadow around the main window's rounded glass and
/// nothing under it (the glass would show a shadow behind it). Its layers only change when the main window is resized, so the shadow
/// is drawn once instead of on every frame.
final class ShadowWindow: NSWindow {
    /// Room around the main window for the shadow to spread into.
    static let margin: CGFloat = 60
    private let container = CALayer()
    private let caster = CALayer()
    private let cutout = CAShapeLayer()

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        let view = NSView()
        view.wantsLayer = true
        contentView = view
        caster.shadowColor = NSColor.black.cgColor
        caster.shadowOpacity = 0.38
        caster.shadowRadius = 22
        caster.shadowOffset = CGSize(width: 0, height: -10)
        cutout.fillRule = .evenOdd
        container.mask = cutout
        container.addSublayer(caster)
        view.layer?.addSublayer(container)
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Takes the shape of the main window's glass, which sits inside its frame by the resize band.
    func follow(_ main: NSWindow) {
        let glass = main.frame.insetBy(dx: Theme.resizeMargin, dy: Theme.resizeMargin)
        let frame = glass.insetBy(dx: -Self.margin, dy: -Self.margin)
        setFrame(frame, display: false)
        let bounds = CGRect(origin: .zero, size: frame.size)
        let inner = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        let radius = min(Theme.windowRadius, inner.width / 2, inner.height / 2)
        let shape = CGPath(roundedRect: inner, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(shape)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        container.contentsScale = backingScaleFactor
        caster.frame = bounds
        caster.contentsScale = backingScaleFactor
        caster.shadowPath = shape
        cutout.frame = bounds
        cutout.path = outside
        CATransaction.commit()
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

/// The glass the tiles sit on. It blurs what is behind the window, and is the window's only edge. Under an open page, whose own glass
/// covers the whole window, only the edge is drawn.
struct GlassBackdrop: View {
    var showsGlass = true
    /// How far a page has opened over it (the zoom's progress): the glass fades out as the page's glass grows over it, so it is
    /// already gone when it stops being drawn. Dropped all at once, the page darkened in one frame as it settled.
    var glassFade: CGFloat = 0
    @Environment(\.design) private var design

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.windowRadius, style: .continuous)
        ZStack {
            if !showsGlass {
                Color.clear
            } else if design.windowGlass {
                GlassPane(corners: .radius(Theme.windowRadius), style: .clear)
                    .modifier(GlassFade(progress: glassFade))
            } else {
                // Measuring switch: a solid window, to see what the full-window glass costs on every frame.
                shape.fill(Color(white: design.isLight ? 0.92 : 0.13))
            }
        }
        .overlay { shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
    }
}

/// Fades the window's glass out over the second half of a page's opening, animated with it.
private struct GlassFade: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(1 - ZoomMath.ramp(progress, 0.35, 1))
    }
}
