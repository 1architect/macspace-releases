import SwiftUI

/// The coordinate space of the glass's content. Tile frames are measured in it, so a tile and the page it grows into agree.
enum ZoomSpace {
    static let name = "zoom"
}

enum ZoomMath {
    /// Returning graphics must mount when Back starts, before the shrinking card makes them visible.
    /// Opening can still release a graphic once the page covers it.
    static func drawsGraphic(progress: CGFloat, returning: Bool) -> Bool {
        returning || graphicOpacity(progress: progress, returning: false) > 0
    }

    static func graphicOpacity(progress: CGFloat, returning: Bool) -> CGFloat {
        1 - ramp(progress, 0, returning ? 1 : 0.35)
    }

    /// A graphic's own springs animate in one tile-sized layout while the card moves around it.
    /// Otherwise each zoom frame retargets the block frames and invalidates the chart's geometry cache.
    static func graphicLayout(proposed: CGSize, resting: CGSize?, returning: Bool) -> CGSize {
        guard returning, let resting, resting.width.isFinite, resting.height.isFinite,
              resting.width > 0, resting.height > 0 else { return proposed }
        return resting
    }

    static func graphicScale(layout: CGSize, proposed: CGSize) -> CGSize {
        CGSize(width: layout.width > 0 ? proposed.width / layout.width : 1,
               height: layout.height > 0 ? proposed.height / layout.height : 1)
    }

    /// 0 until `start`, 1 from `end`, smooth in between.
    static func ramp(_ value: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat {
        let t = min(max((value - start) / (end - start), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func lerp(_ from: CGFloat, _ to: CGFloat, _ progress: CGFloat) -> CGFloat { from + (to - from) * progress }

    static func rect(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        CGRect(x: lerp(from.minX, to.minX, progress), y: lerp(from.minY, to.minY, progress),
               width: lerp(from.width, to.width, progress), height: lerp(from.height, to.height, progress))
    }
}

/// Where each tile is on the dashboard, as laid out (before any lift, press or recede), and how far the dashboard is scrolled. Kept
/// outside the view state: it changes while scrolling and must not redraw the views that read it.
final class TileFrames {
    private var layout: [Destination: CGRect] = [:]
    private var large: Set<Destination> = []
    var scrollOffset: CGFloat = 0

    func record(_ frames: [(Destination, CGRect)], large: Set<Destination> = []) {
        layout = Dictionary(frames, uniquingKeysWith: { first, _ in first })
        self.large = large
    }

    /// The dashboard's large tile (`DashboardTile.large`), for the zoom to draw its caption and blocks as the tile has them.
    func isLarge(_ destination: Destination) -> Bool { large.contains(destination) }

    /// The tile's rectangle in `ZoomSpace` right now.
    func frame(of destination: Destination) -> CGRect? {
        layout[destination]?.offsetBy(dx: 0, dy: -scrollOffset)
    }
}

/// Brings a part of a page in after the tile has grown, one after another by `index`.
struct ZoomReveal: ViewModifier, @preconcurrency Animatable {
    let index: Int
    var reveal: CGFloat

    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    func body(content: Content) -> some View {
        let start = 0.07 * CGFloat(min(max(index, 0), 6))
        let t = ZoomMath.ramp(reveal, start, start + 0.55)
        // No blur: blurring a page full of glass is one of the most expensive things the window can draw.
        return content.opacity(t).offset(y: (1 - t) * 16)
    }
}

/// A tile growing into the page and shrinking back. At `progress` 0 it is exactly the dashboard tile; at 1 it fills the glass.
/// The face is drawn under the page and the caption over it, so the page scrolls between the two.
struct ZoomCard<Content: View>: View, @preconcurrency Animatable {
    @Environment(\.windowCornerStyle) private var corners
    var progress: CGFloat
    /// The tile's rectangle on the dashboard, and the rectangle the page takes (the whole window).
    let origin: CGRect
    let target: CGRect
    let container: CGSize
    let content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let card = ZoomMath.rect(from: origin, to: target, progress: progress)
        content(progress)
            .frame(width: card.width, height: card.height)
            .clipShape(RoundedRectangle(cornerRadius: ZoomMath.lerp(corners.tileRadius, corners.windowRadius, progress), style: .continuous))
            .offset(x: card.minX, y: card.minY)
            .frame(width: container.width, height: container.height, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Sends the dashboard back while a tile grows over it: the other tiles recede and fade, so the growing card reads as coming
/// forward.
struct ZoomFade: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            // No blur: the dashboard is all glass, and blurring it on top is very expensive to draw.
            .scaleEffect(1 - 0.06 * progress)
            .opacity(1 - ZoomMath.ramp(progress, 0.05, 0.6))
    }
}
