import AppKit
import SwiftUI

/// Liquid Glass drawn by AppKit (`NSGlassEffectView`), not by SwiftUI's `glassEffect`, for the glass that moves: the window, the tiles
/// and the chart elements.
///
/// SwiftUI's glass captures the view it is applied to and composites the glass again whenever that view changes. Whatever changed on
/// every frame (a tile lifting, a block growing in, the zoom, the loading pulse) had its glass composited anew on every frame, and the
/// rim of every glass shape flickered while anything moved. SwiftUI's glass also jumped to where a scale, an offset or an opacity
/// animated by SwiftUI would end, ahead of what it held. AppKit's glass is a layer the system draws by itself, as it does for the
/// window's round buttons: it follows its frame, its transform and its opacity frame by frame like any view, and the color inside it
/// is a layer of its own, so changing that color does not touch the glass.
///
/// SwiftUI does not size an AppKit view frame by frame while it animates a layout; what moves glass of this kind is laid out again on
/// every frame (`TileSize`, `BlockFrame`, `AnimatedLength`, the zoom).
struct GlassPane: NSViewRepresentable {
    enum Corners: Equatable {
        case radius(CGFloat)
        /// Half the shorter side: a circle, or a capsule.
        case round
    }

    var corners: Corners
    var style: NSGlassEffectView.Style = .regular
    /// The color inside the glass, and how much of it covers the glass. Changes follow at once, frame by frame (the loading pulse).
    var color: Color = .clear
    var opacity: Double = 0
    /// How dark a shade lies over that color, 0...1 (the hover darkening). It eases in and out on its own.
    var shade: Double = 0

    func makeNSView(context: Context) -> GlassPaneView { GlassPaneView(frame: .zero) }

    func updateNSView(_ view: GlassPaneView, context: Context) {
        // The palette's appearance, not the system's: light glass under a deep palette's colors washed them out.
        let appearance: NSAppearance.Name = context.environment.design.isLight ? .aqua : .darkAqua
        if view.appearance?.name != appearance { view.appearance = NSAppearance(named: appearance) }
        if view.style != style { view.style = style }
        view.corners = corners
        let resolved = color.resolve(in: context.environment)
        view.setFill(resolved.cgColor.copy(alpha: CGFloat(Double(resolved.opacity) * min(max(opacity, 0), 1))) ?? .clear)
        view.setShade(min(max(shade, 0), 1))
    }
}

final class GlassPaneView: NSGlassEffectView {
    var corners: GlassPane.Corners = .radius(0) {
        didSet { if corners != oldValue { updateShape() } }
    }

    private let fill = CALayer()
    private let shade = CALayer()
    private var shadeAmount: Double?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let content = NSView(frame: bounds)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        shade.backgroundColor = .black
        shade.opacity = 0
        for layer in [fill, shade] {
            layer.cornerCurve = .continuous
            content.layer?.addSublayer(layer)
        }
        contentView = content
    }

    required init?(coder: NSCoder) { nil }

    /// The glass never takes clicks or the pointer: the SwiftUI views over it do.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // SwiftUI resizes the view on every frame of a movement; its color layers follow in the same frame.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShape()
    }

    override func layout() {
        super.layout()
        updateShape()
    }

    private func updateShape() {
        let radius: CGFloat
        switch corners {
        case let .radius(value): radius = value
        case .round: radius = min(bounds.width, bounds.height) / 2
        }
        if cornerRadius != radius { cornerRadius = radius }
        // The content view fills the glass.
        let inner = CGRect(origin: .zero, size: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [fill, shade] {
            layer.frame = inner
            layer.cornerRadius = min(radius, min(inner.width, inner.height) / 2)
        }
        CATransaction.commit()
    }

    func setFill(_ color: CGColor) {
        if let current = fill.backgroundColor, CFEqual(current, color) { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = color
        CATransaction.commit()
    }

    func setShade(_ amount: Double) {
        guard amount != shadeAmount else { return }
        let first = shadeAmount == nil
        shadeAmount = amount
        CATransaction.begin()
        if first {
            CATransaction.setDisableActions(true)
        } else {
            // As the shade on a flat tile: quick, and without a tail, so it lets go as soon as the pointer leaves.
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        shade.opacity = Float(amount)
        CATransaction.commit()
    }
}

/// A width or a leading inset laid out again on every frame while it changes, so AppKit glass sized or placed by it moves with the
/// SwiftUI views around it instead of jumping to where it ends up.
struct AnimatedLength: ViewModifier, @preconcurrency Animatable {
    enum Kind {
        case width
        case leading
    }

    var value: CGFloat
    let kind: Kind

    var animatableData: CGFloat {
        get { value }
        set { value = newValue }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        switch kind {
        case .width: content.frame(width: max(value, 0))
        case .leading: content.padding(.leading, max(value, 0))
        }
    }
}
