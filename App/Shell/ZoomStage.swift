import MacSpaceSdk
import SwiftUI

/// The coordinate space of the window's content. Tile and page frames are measured in it, so a tile and what it turns into agree.
enum ZoomSpace {
    static let name = "zoom"
}

enum ZoomMath {
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

    /// The widget of a module's page that its dashboard tile turns into: the one with the summary's id, else the first of the same
    /// kind (a banner for a banner), else the first.
    static func heroIndex(in screen: Screen, summary: ScreenWidget?) -> Int? {
        guard !screen.widgets.isEmpty else { return nil }
        guard let summary else { return 0 }
        return screen.widgets.firstIndex { $0.id == summary.id }
            ?? screen.widgets.firstIndex { $0.kind == summary.kind }
            ?? 0
    }
}

extension ScreenWidget {
    var kind: String {
        switch self {
        case .banner: return "banner"
        case .usage: return "usage"
        case .chart: return "chart"
        case .list: return "list"
        case .toggles: return "toggles"
        case .button: return "button"
        case .steps: return "steps"
        case .text: return "text"
        case .section: return "section"
        }
    }
}

/// Where the tile's parts are on the dashboard, in `ZoomSpace`: the card, its title and its summary widget.
struct TileGeometry: Equatable {
    var card = CGRect.zero
    var header = CGRect.zero
    var summary = CGRect.zero

    var isComplete: Bool { card != .zero && header != .zero && summary != .zero }
}

/// Frames kept outside the view state: they change while scrolling and must not redraw the views that read them.
final class TileFrames {
    var tiles: [String: TileGeometry] = [:]
}

/// Where the open page put its title and the widget the tile turns into.
final class PageFrames {
    var title = CGRect.zero
    var hero = CGRect.zero
}

/// What the page needs to take part in the zoom: how far the zoom is, how far the rest of the page has appeared, and where to
/// report its title and hero widget.
struct ScreenZoom {
    var progress: CGFloat
    var reveal: CGFloat
    var frames: PageFrames
}

/// Fades and moves a part of the page in as the zoom progresses. `progress` is the zoom itself (0 tile, 1 open), `reveal` the
/// second, later animation that brings in everything that is not part of the tile.
struct ZoomReveal: ViewModifier, @preconcurrency Animatable {
    enum Part {
        /// The page's own copy of the tile's summary widget: it takes over from the flying one at the end of the zoom.
        case hero
        /// The page title: takes over from the tile's title.
        case title
        /// Everything else, one after another by `index`.
        case stagger(Int)
    }

    let part: Part
    var progress: CGFloat
    var reveal: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, reveal) }
        set { progress = newValue.first; reveal = newValue.second }
    }

    func body(content: Content) -> some View {
        var opacity: CGFloat = 1
        var shift: CGFloat = 0
        switch part {
        case .hero: opacity = ZoomMath.ramp(progress, 0.78, 0.96)
        case .title: opacity = ZoomMath.ramp(progress, 0.65, 0.85)
        case let .stagger(index):
            let start = 0.08 * CGFloat(min(max(index, 0), 6))
            let t = ZoomMath.ramp(reveal, start, start + 0.52)
            opacity = t
            shift = (1 - t) * 28
        }
        return content.opacity(opacity).offset(y: shift)
    }
}

enum ZoomStageLayer {
    /// The growing card: drawn under the page.
    case card
    /// The tile's title and summary widget: drawn over the page.
    case travelers
}

/// The part of the zoom that is not the page: the tile's card growing into the window, and the tile's real title and summary
/// widget travelling to where the page keeps them. At `progress` 0 it draws the tile exactly; at 1 it has handed over to the page.
struct ZoomStage<Header: View, Hero: View>: View, @preconcurrency Animatable {
    let layer: ZoomStageLayer
    var progress: CGFloat
    /// The rectangle the card grows from: the tile's card, or the Settings button.
    let origin: CGRect
    let tile: TileGeometry?
    let container: CGSize
    let pageTitle: CGRect
    let pageHero: CGRect
    let header: Header
    let hero: Hero

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = progress
        let card = ZoomMath.rect(from: origin, to: CGRect(origin: .zero, size: container), progress: p)
        ZStack(alignment: .topLeading) {
            if layer == .card {
                RoundedRectangle(cornerRadius: ZoomMath.lerp(14, 0, p), style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay { RoundedRectangle(cornerRadius: ZoomMath.lerp(14, 0, p), style: .continuous).fill(.background.secondary).opacity(1 - ZoomMath.ramp(p, 0, 0.8)) }
                    .frame(width: card.width, height: card.height)
                    .offset(x: card.minX, y: card.minY)
            }
            if layer == .travelers, let tile, tile.isComplete {
                // The title and the widget arrive (and stop) before the hand-over to the page's own copies starts (0.6 and 0.78), so the
                // two copies are on the same spot while they cross-fade.
                let q = CGFloat(sin(Double(min(p / 0.65, 1)) * .pi / 2))
                let titleTarget = pageTitle == .zero ? tile.header : pageTitle
                let titleScale = tile.header.height > 0 ? ZoomMath.lerp(1, titleTarget.height / tile.header.height, q) : 1
                let titleOrigin = ZoomMath.rect(from: tile.header, to: titleTarget, progress: q)
                header
                    .fixedSize()
                    .scaleEffect(titleScale, anchor: .topLeading)
                    .offset(x: titleOrigin.minX, y: titleOrigin.minY)
                    .opacity(1 - ZoomMath.ramp(p, 0.6, 0.8))
                let heroRect = ZoomMath.rect(from: tile.summary, to: pageHero == .zero ? tile.summary : pageHero, progress: q)
                hero
                    .frame(width: heroRect.width, alignment: .topLeading)
                    .offset(x: heroRect.minX, y: heroRect.minY)
                    .opacity(1 - ZoomMath.ramp(p, 0.78, 0.96))
            }
        }
        .frame(width: container.width, height: container.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Fades the dashboard out while a page grows over it. Quick, so the dashboard does not show beside the growing card.
struct ZoomFade: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(1 - ZoomMath.ramp(progress, 0, 0.3))
    }
}
