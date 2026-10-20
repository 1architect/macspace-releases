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
    /// Whether the shadow shows: it grows in with the glass when the window opens, and is off while the window closes.
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

        /// Off until the window says otherwise: set up before SwiftUI hands over the value, the shadow showed at once, before the glass.
        var wantsShadow = false {
            didSet { if wantsShadow != oldValue { showShadow(animated: true, growing: wantsShadow) } }
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
            // A child window moves with its parent by itself, in the same frame. Moved or re-framed as well on every step of a drag,
            // it fought the move the window server was already making, and the shadow trailed and flickered behind the glass
            // (issue 34). So a move changes nothing unless the room above the glass has to change near the menu bar
            // (`ShadowWindow.roomAbove`); a new size, scale or screen draws it again.
            for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        self.shadowWindow?.follow(window)
                        self.showShadow(animated: false)
                    }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, let shadowWindow = self.shadowWindow else { return }
                    if shadowWindow.needsNewRoom(for: window) { shadowWindow.follow(window) }
                }
            })
        }

        private func showShadow(animated: Bool, growing: Bool = false) {
            guard let shadowWindow else { return }
            // A filled window reaches the usable screen edges; its separate shadow must disappear there too.
            let alpha: CGFloat = wantsShadow && window.map({ !WindowControls.isZoomed($0) }) == true ? 1 : 0
            if growing && alpha == 1 {
                // The glass is growing in: the shadow, already at the glass's full size, grows in with it on the same spring
                // instead of fading in around it. Waiting for the glass to finish left the window without a shadow while it opened.
                // The layer's growth first: shown before it, the window could draw one frame of the full shadow.
                shadowWindow.growIn(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                shadowWindow.alphaValue = 1
            } else if animated {
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

/// A click-through window around the main window, drawing a soft shadow around the rounded glass and nothing under it (the glass
/// would show a shadow behind it). Its layers only change when the main window is resized, so the shadow is drawn once instead of
/// on every frame. Its layers and their look are 1.1.2's.
///
/// Above the glass it reaches only as far as the shadow does (`above`), and never under the menu bar: any window reaching under
/// the menu bar makes macOS draw the menu bar's background, with its dark bottom line across the whole screen (issue 34). Near the
/// menu bar the room above shrinks to what is left, and the top of the shadow fades out over its last points (`fade`) instead of
/// stopping in a line beside the top corners. With no room above at all, the shadow went too, and looked shifted down (1.1.3's
/// second build).
final class ShadowWindow: NSWindow {
    /// The corner radius the shadow was last drawn with: a new one in the Design menu draws it again.
    private var drawnRadius: CGFloat = -1
    /// Room beside and below the main window for the shadow to spread into.
    static let margin: CGFloat = 60
    /// Room above the glass: the shadow falls 10 points down with a 22-point blur, so about 30 points of it show above the glass.
    static let above: CGFloat = 36
    /// How far down from the window's top edge the shadow fades in, from none to full: the last points of a full room above, and past
    /// the top corners' curve when there is no room.
    static func fade(room: CGFloat) -> CGFloat { max(12, Theme.windowRadius * 1.6 + 8 - room) }
    /// The room above the glass the window has now.
    private(set) var room: CGFloat = -1
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

    /// The room above `glass` on its screen: `above`, less whatever would reach under the menu bar.
    static func roomAbove(_ glass: CGRect, screenTop: CGFloat?) -> CGFloat {
        guard let screenTop else { return above }
        return min(above, max(0, screenTop - glass.maxY))
    }

    /// The glass with room beside and below it, and `room` above.
    static func frame(around glass: CGRect, room: CGFloat) -> CGRect {
        CGRect(x: glass.minX - margin, y: glass.minY - margin, width: glass.width + 2 * margin, height: glass.height + margin + room)
    }

    /// Whether a move took the glass near enough the menu bar, or away from it, to change the room above.
    func needsNewRoom(for main: NSWindow) -> Bool {
        Self.roomAbove(main.frame, screenTop: (main.screen ?? NSScreen.main)?.visibleFrame.maxY) != room
    }

    /// Takes the shape of the main window's glass, which is the main window's frame.
    func follow(_ main: NSWindow) {
        let glass = main.frame
        let room = Self.roomAbove(glass, screenTop: (main.screen ?? NSScreen.main)?.visibleFrame.maxY)
        let frame = Self.frame(around: glass, room: room)
        let redraw = frame.size != self.frame.size || container.contentsScale != backingScaleFactor || drawnRadius != Theme.windowRadius
        drawnRadius = Theme.windowRadius
        self.room = room
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
        let fadeStart = max(0, (bounds.height - Self.fade(room: room)) / max(bounds.height, 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Scaled about the glass's center, as SwiftUI scales the glass (`growIn`).
        container.anchorPoint = CGPoint(x: inner.midX / max(bounds.width, 1), y: inner.midY / max(bounds.height, 1))
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

    /// Grows in with the glass as it opens: from the glass's opening size and clear, on the glass's own spring (`Theme.windowIn`),
    /// around its center. The shadow and the hole under the glass scale together, as one layer the render server animates: nothing
    /// is drawn again. With reduced motion the glass only fades in, and so does the shadow.
    func growIn(reduceMotion: Bool) {
        let spring = { (keyPath: String, from: Any) -> CASpringAnimation in
            let animation = CASpringAnimation(perceptualDuration: Theme.windowInSpring.duration, bounce: Theme.windowInSpring.bounce)
            animation.keyPath = keyPath
            animation.fromValue = from
            animation.toValue = 1
            animation.duration = animation.settlingDuration
            return animation
        }
        container.removeAnimation(forKey: "growIn.scale")
        container.removeAnimation(forKey: "growIn.opacity")
        if !reduceMotion { container.add(spring("transform.scale", Theme.windowOpeningScale), forKey: "growIn.scale") }
        container.add(spring("opacity", 0), forKey: "growIn.opacity")
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

/// The ground the tiles sit on: macOS's own window color in the palette's light or dark (`Design.systemWindowColor`), with a faint
/// light edge, the window's only edge. Under an open page, which covers the whole window, only the edge is drawn.
struct GlassBackdrop: View {
    var showsGlass = true
    @Environment(\.design) private var design

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.windowRadius, style: .continuous)
        ZStack {
            if !showsGlass {
                Color.clear
            } else {
                ShadedFill(shape: shape, color: design.systemWindowColor, accent: design.action, fill: design.fill(.window),
                           shading: design.shading(.window), light: design.isLight)
            }
        }
        .overlay { shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
        .studioPickable(.window, in: shape)
    }
}
