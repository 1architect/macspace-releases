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
    /// The glass's corner radius: the shadow is drawn again around a new one.
    var radius: CGFloat = Theme.windowRadius

    func makeNSView(context: Context) -> ConfiguringView { ConfiguringView() }
    func updateNSView(_ nsView: ConfiguringView, context: Context) {
        nsView.wantsShadow = shadow
        nsView.radius = radius
    }

    final class ConfiguringView: NSView {
        var wantsShadow = true {
            didSet { if wantsShadow != oldValue { showShadow(animated: true) } }
        }
        var radius: CGFloat = Theme.windowRadius {
            didSet { if radius != oldValue, let window { shadowWindow?.follow(window) } }
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
            // A child window moves with its parent by itself; it has to be told about a new size. After a move it is put back where it
            // belongs, should AppKit have placed it anywhere else.
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification,
                         NSWindow.didChangeBackingPropertiesNotification] {
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
    /// The corner radius the shadow was last drawn with: a new one in the Design menu draws it again.
    private var drawnRadius: CGFloat = -1
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

    /// Exactly where `follow` puts it. AppKit keeps a window's top edge below the menu bar, and this one reaches above the glass: with
    /// the main window near the top of the screen it was pushed down, and the shadow hung below the glass around an empty band.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Takes the shape of the main window's glass, which sits inside its frame by the resize band.
    func follow(_ main: NSWindow) {
        let glass = main.frame.insetBy(dx: Theme.resizeMargin, dy: Theme.resizeMargin)
        var frame = glass.insetBy(dx: -Self.margin, dy: -Self.margin)
        // Never under the menu bar: with the window against it (tiled to half the screen, or filling it) the shadow showed as a dark
        // band between the two and darkened the menu bar. The shadow stops where the window could reach, and a window at the top
        // casts none upward.
        if let screen = main.screen ?? NSScreen.main {
            let top = max(min(frame.maxY, screen.visibleFrame.maxY - Theme.resizeMargin), glass.maxY)
            frame.size.height = top - frame.minY
        }
        let redraw = frame.size != self.frame.size || container.contentsScale != backingScaleFactor || drawnRadius != Theme.windowRadius
        drawnRadius = Theme.windowRadius
        if frame != self.frame { setFrame(frame, display: false) }
        // A move only places the window again; the shadow is drawn anew only for a new size.
        guard redraw else { return }
        let bounds = CGRect(origin: .zero, size: frame.size)
        let inner = CGRect(x: glass.minX - frame.minX, y: glass.minY - frame.minY, width: glass.width, height: glass.height)
        // The glass's own continuous corners: a circular corner of the same radius reaches outside them where the curve meets the
        // edge, and in that sliver there was neither glass nor shadow, a line of bare desktop between the shadow and the border. The
        // hole is a pixel smaller than the glass, so the shadow runs under its edge and no seam opens where the two are antialiased.
        let shape = Self.glassPath(inner)
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(Self.glassPath(inner.insetBy(dx: 1 / backingScaleFactor, dy: 1 / backingScaleFactor)))
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

    /// The glass's outline: the window radius with continuous corners, as SwiftUI draws the glass.
    static func glassPath(_ rect: CGRect) -> CGPath {
        RoundedRectangle(cornerRadius: min(Theme.windowRadius, rect.width / 2, rect.height / 2), style: .continuous).path(in: rect).cgPath
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
///
/// Under the glass lies a plain blur of what is behind the window (`WindowBlur`). Liquid Glass alone blurs as much as the system's
/// glass setting asks: set to clear, it hardly blurred at all, and windows behind read straight through the tiles. The blur under it
/// keeps the window frosted whatever that setting, also under an open page.
struct GlassBackdrop: View {
    var showsGlass = true
    /// How far a page has opened over it (the zoom's progress): the glass fades out as the page's glass grows over it, so it is
    /// already gone when it stops being drawn. Dropped all at once, the page darkened in one frame as it settled.
    var glassFade: CGFloat = 0
    @Environment(\.design) private var design

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.windowRadius, style: .continuous)
        if design.windowBackground {
            ZStack {
                if design.windowGlass {
                    WindowBlur(cornerRadius: Theme.windowRadius, isLight: design.backgroundIsLight)
                    // The Color Lab's window fill and the studio's shading, over the blur and under the glass.
                    if design.fill(.window) != nil || design.shading(.window) != nil {
                        ShadedFill(shape: shape, color: design.fill(.window) == nil ? .clear : design.systemWindowColor, accent: design.action,
                                   fill: design.fill(.window), shading: design.shading(.window), light: design.backgroundIsLight)
                    }
                }
                if !showsGlass {
                    Color.clear
                } else if design.windowGlass {
                    GlassPane(corners: .radius(Theme.windowRadius), style: .clear)
                        .modifier(GlassFade(progress: glassFade))
                } else {
                    // Measuring switch: a solid window, to see what the full-window glass costs on every frame.
                    ShadedFill(shape: shape, color: design.systemWindowColor, accent: design.action, fill: design.fill(.window),
                               shading: design.shading(.window), light: design.backgroundIsLight)
                }
            }
            .overlay { shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
            .studioPickable(.window, in: shape)
        } else {
            // Nothing drawn behind the widgets (Design menu > Window Background); the empty ground still takes the window drag.
            Color.clear.contentShape(Rectangle())
        }
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

/// A blur of what is behind the window, in the window's rounded shape: the system's own (`NSVisualEffectView`), whatever the Liquid
/// Glass setting. With Reduce Transparency, the system draws it solid.
///
/// Its look follows the palette, not the system's appearance: under a light system appearance the window's background material laid a
/// pale grey sheet over the deep tiles. The deep palettes get the dark, smoky material of a heads-up window, which blurs without
/// whitening; the light palettes a light one.
struct WindowBlur: NSViewRepresentable {
    let cornerRadius: CGFloat
    let isLight: Bool

    final class BlurView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> BlurView {
        let view = BlurView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: BlurView, context: Context) {
        let material: NSVisualEffectView.Material = isLight ? .popover : .hudWindow
        if view.material != material { view.material = material }
        let appearance: NSAppearance.Name = isLight ? .aqua : .darkAqua
        if view.appearance?.name != appearance { view.appearance = NSAppearance(named: appearance) }
    }

    /// A rounded rectangle that stretches to any size, the way the visual effect view takes a shape. Its corners are continuous, as
    /// the glass's are; a continuous corner bends over about 1.53 times its radius, so the corner part of the image is that long.
    private static func mask(radius: CGFloat) -> NSImage {
        let corner = (radius * 1.53).rounded(.up)
        let side = corner * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: corner, left: corner, bottom: corner, right: corner)
        image.resizingMode = .stretch
        return image
    }
}
