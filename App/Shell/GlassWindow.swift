import AppKit
import SwiftUI

/// Finishes the window the plain window style gives: clear behind the glass, a shadow around the glass, and resizable from its edges.
/// The glass fills the window: the window's frame is the glass's edge, so macOS places it (Fill, Move & Resize, edge tiles) exactly
/// where it shows. It used to be 8 points larger than the glass on every side, and those places left a gap (2026-10-19, issue 34).
///
/// The shadow is not the window's own. macOS works out the shadow of a transparent window from its content and did so again on every
/// frame anything in the window changed: about 15 points of GPU while the mouse moved over the tiles or a page scrolled; and with it
/// comes the rim macOS draws around every window, a thicker edge than the glass's own (tried in 1.1.3's first build). It is drawn
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
        static let frameName = "MacSpace.glassWindow.2"
        /// Where earlier versions kept the window's frame, 8 points larger than the glass on every side.
        static let earlierFrameName = "MacSpace.glassWindow"
        static let earlierBand: CGFloat = 8

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
            // so the rounded corners selected the app behind instead of resizing.
            window.ignoresMouseEvents = false
            window.invalidateShadow()
            // Opened from the menu bar icon on another desktop, the window comes to that desktop instead of taking the user back to
            // the one it was left on.
            window.collectionBehavior.insert(.moveToActiveSpace)
            // Its size and place are kept between launches; a frame kept by an earlier version loses its band.
            window.setFrameAutosaveName(Self.frameName)
            if !window.setFrameUsingName(Self.frameName), window.setFrameUsingName(Self.earlierFrameName) {
                window.setFrame(window.frame.insetBy(dx: Self.earlierBand, dy: Self.earlierBand), display: false)
            }
            // The edges are resized from a band along the inside of the glass's edge (`ResizeBand`).
            if let frameView = window.contentView?.superview, !frameView.subviews.contains(where: { $0 is ResizeBand }) {
                let band = ResizeBand(frame: frameView.bounds)
                band.autoresizingMask = [.width, .height]
                frameView.addSubview(band, positioned: .above, relativeTo: nil)
            }
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
            // A child window moves with its parent by itself, in the same frame: on a move it is left alone. Moved or re-framed as
            // well on every step of a drag, it fought the move the window server was already making, and the shadow trailed and
            // flickered behind the glass (issue 34). It is told only about a new size, scale or screen.
            for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        self.shadowWindow?.follow(window)
                        self.showShadow(animated: false)
                    }
                })
            }
        }

        private func showShadow(animated: Bool) {
            guard let shadowWindow else { return }
            // A filled window reaches the usable screen edges; its separate shadow must disappear there too.
            let alpha: CGFloat = wantsShadow && window.map({ !WindowControls.isZoomed($0) }) == true ? 1 : 0
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

/// A click-through window around the main window's left, right and bottom, drawing a soft shadow around the rounded glass and nothing
/// under it (the glass would show a shadow behind it). Its layers only change when the main window is resized, so the shadow is drawn
/// once instead of on every frame.
///
/// It reaches no higher than the glass's top. Any window reaching under the menu bar makes macOS draw the menu bar's background, with
/// its dark bottom line across the whole screen: with room above the glass, that showed whenever the window was near the top
/// (issue 34). Cut short at the top instead, the shadow beside the top corners stopped in a hard line, so it fades out over the top
/// of the window (`fadeLength`). The shadow falls downward (`caster`), so little of it was above the glass anyway.
final class ShadowWindow: NSWindow {
    /// The corner radius the shadow was last drawn with: a new one in the Design menu draws it again.
    private var drawnRadius: CGFloat = -1
    /// Room beside and below the main window for the shadow to spread into.
    static let margin: CGFloat = 60
    /// How far down from the glass's top the shadow beside it fades in, from none to full: past the top corners' curve.
    static var fadeLength: CGFloat { Theme.windowRadius * 1.6 + 8 }
    private let container = CALayer()
    private let caster = CALayer()
    private let cutout = CAShapeLayer()
    private let fader = CAGradientLayer()

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
        // The layer's y runs up from the window's bottom, as the screen's does: full below, none at the top edge.
        fader.startPoint = CGPoint(x: 0.5, y: 0)
        fader.endPoint = CGPoint(x: 0.5, y: 1)
        fader.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        view.layer?.addSublayer(container)
        view.layer?.mask = fader
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Exactly where `follow` puts it, wherever the main window is.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// The glass with room beside and below it, and none above.
    static func frame(around glass: CGRect) -> CGRect {
        CGRect(x: glass.minX - margin, y: glass.minY - margin, width: glass.width + 2 * margin, height: glass.height + margin)
    }

    /// Takes the shape of the main window's glass, which is the main window's frame. Called for a new size only: a move needs nothing.
    func follow(_ main: NSWindow) {
        let glass = main.frame
        let frame = Self.frame(around: glass)
        let redraw = frame.size != self.frame.size || container.contentsScale != backingScaleFactor || drawnRadius != Theme.windowRadius
        drawnRadius = Theme.windowRadius
        if frame != self.frame { setFrame(frame, display: false) }
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
        let fadeStart = max(0, (bounds.height - Self.fadeLength) / max(bounds.height, 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        container.contentsScale = backingScaleFactor
        caster.frame = bounds
        caster.contentsScale = backingScaleFactor
        caster.shadowPath = shape
        cutout.frame = bounds
        cutout.path = outside
        fader.frame = bounds
        fader.locations = [0, NSNumber(value: Double(fadeStart)), 1]
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

/// A rounded rectangle that stretches to any size, the way a visual effect view takes its shape (`WindowBlur`).
enum GlassShape {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var masks: [CGFloat: NSImage] = [:]

    /// Its corners are continuous, as the glass's are; a continuous corner bends over about 1.53 times its radius, so the corner part
    /// of the image is that long. Made once per radius.
    static func mask(radius: CGFloat) -> NSImage {
        lock.lock()
        defer { lock.unlock() }
        if let made = masks[radius] { return made }
        let corner = (radius * 1.53).rounded(.up)
        let side = corner * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: corner, left: corner, bottom: corner, right: corner)
        image.resizingMode = .stretch
        masks[radius] = image
        return image
    }
}

/// Where the glass window is resized: a band along the inside of the glass's edge, wider at the corners. The glass is the window's
/// edge, so the band is the window's own: AppKit resizes a borderless window only from a hairline at its edge. It takes the pointer
/// only inside the band: everywhere else clicks go to the window's content.
final class ResizeBand: NSView {
    /// How far the band reaches into the glass: about the reach of a macOS window's own resize edge, and less than the glass's frame
    /// around the tiles (`Theme.frame`).
    static let inside: CGFloat = 7
    /// How far along each edge from a corner the corner's diagonal resize reaches.
    static let corner: CGFloat = 22

    override var isFlipped: Bool { false }

    /// The edge or corner under `point` (in this view), if it is in the band.
    func position(at point: NSPoint) -> NSCursor.FrameResizePosition? {
        let glass = bounds
        let inner = glass.insetBy(dx: Self.inside, dy: Self.inside)
        guard bounds.contains(point), !inner.contains(point) else { return nil }
        let left = point.x < glass.minX + Self.corner, right = point.x > glass.maxX - Self.corner
        let bottom = point.y < glass.minY + Self.corner, top = point.y > glass.maxY - Self.corner
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: break
        }
        if point.x < inner.minX { return .left }
        if point.x > inner.maxX { return .right }
        if point.y > inner.maxY { return .top }
        return .bottom
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return position(at: convert(point, from: superview)) != nil ? self : nil
    }

    private var tracking: NSTrackingArea?
    private var showsResizeCursor = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func mouseEntered(with event: NSEvent) { updateCursor(event) }
    override func mouseExited(with event: NSEvent) {
        if showsResizeCursor { NSCursor.arrow.set(); showsResizeCursor = false }
    }

    private func updateCursor(_ event: NSEvent) {
        if let position = position(at: convert(event.locationInWindow, from: nil)) {
            NSCursor.frameResize(position: position, directions: .all).set()
            showsResizeCursor = true
        } else if showsResizeCursor {
            // Back to the arrow once, when the pointer leaves the band; the content sets its own cursors after that.
            NSCursor.arrow.set()
            showsResizeCursor = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, let position = position(at: convert(event.locationInWindow, from: nil)) else { return }
        let start = window.frame
        let origin = NSEvent.mouseLocation
        let least = NSSize(width: max(window.minSize.width, Theme.minimumSize.width),
                           height: max(window.minSize.height, Theme.minimumSize.height))
        NSCursor.frameResize(position: position, directions: .all).push()
        defer { NSCursor.pop() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let now = NSEvent.mouseLocation
            let dx = now.x - origin.x, dy = now.y - origin.y
            var frame = start
            switch position {
            case .left, .topLeft, .bottomLeft:
                frame.size.width = max(start.width - dx, least.width)
                frame.origin.x = start.maxX - frame.width
            case .right, .topRight, .bottomRight:
                frame.size.width = max(start.width + dx, least.width)
            default: break
            }
            switch position {
            case .bottom, .bottomLeft, .bottomRight:
                frame.size.height = max(start.height - dy, least.height)
                frame.origin.y = start.maxY - frame.height
            case .top, .topLeft, .topRight:
                frame.size.height = max(start.height + dy, least.height)
            default: break
            }
            window.setFrame(frame, display: true)
        }
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
        view.maskImage = GlassShape.mask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: BlurView, context: Context) {
        let material: NSVisualEffectView.Material = isLight ? .popover : .hudWindow
        if view.material != material { view.material = material }
        let appearance: NSAppearance.Name = isLight ? .aqua : .darkAqua
        if view.appearance?.name != appearance { view.appearance = NSAppearance(named: appearance) }
    }
}
