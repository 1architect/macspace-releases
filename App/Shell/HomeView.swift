import AppKit
import MacSpacePlatform
import MacSpaceSdk
import SwiftUI

/// What a tile shows, whoever it belongs to.
struct TileInfo: Equatable {
    var title: String
    /// What goes with the title ("43.14 GB"), after it or above it (`TileCaption`).
    var figure: String?
    var status: String
    var needsAttention = false
    var graphic: TileGraphic?
    var loading = false
    /// What the switch of a `state` chart runs; nil when it cannot be flipped.
    var switchAction: Action?

    static let settings = TileInfo(title: "MacSpace", status: String(localized: "settings"))

    @MainActor
    init(_ handle: ModuleHandle) {
        if let tile = handle.tile {
            // Read again (Refresh, the first reading), the status line says so, in its own style: the old figures dimmed read as the
            // new ones.
            let reading = handle.tileIsStale || handle.isRefreshing
            self.init(title: tile.title, figure: tile.figure,
                      status: handle.isCleaning ? Self.cleaningStatus(handle.progress) : (reading ? Self.loadingStatus : tile.status),
                      needsAttention: tile.needsAttention, graphic: tile.graphic,
                      loading: handle.tileIsStale || handle.isRefreshing || handle.isCleaning, switchAction: tile.switchAction)
        } else {
            self.init(title: handle.manifest.name.lowercased(), status: Self.loadingStatus, loading: true)
        }
    }

    /// A tile's status line while its module reads the Mac.
    static var loadingStatus: String { String(localized: "loading…") }

    /// While a module cleans, its status line ("free up to 3.74 GB") says what it is doing and how far it is, as the page's pill
    /// does, and its chart breathes: on the dashboard the figure would otherwise stand still until the cleanup ends. In the tile's
    /// lowercase, except in German, where the message starts with a noun.
    static func cleaningStatus(_ progress: ActionProgress?) -> String {
        var text = progress?.message ?? String(localized: "working…")
        if Bundle.main.preferredLocalizations.first?.hasPrefix("de") != true, let first = text.first {
            text = first.lowercased() + text.dropFirst()
        }
        if let fraction = progress?.fraction { text += " \(Int((min(max(fraction, 0), 1) * 100).rounded()))%" }
        return text
    }

    /// The disk: an arc filled as far as the disk is used. What macOS can purge by itself is not drawn: at a few gigabytes it was a
    /// sliver too thin to see.
    @MainActor
    init(_ storage: StorageOverview) {
        let status = storage.status()
        // An empty gauge while the disk is read, so the light running along it shows where the figure will be.
        var graphic = TileGraphic.gauge(value: 0, label: "", sublabel: "")
        if let used = storage.usedFraction, let total = storage.totalBytes {
            graphic = .gauge(value: used, label: "\(Int((used * 100).rounded()))%", sublabel: String(localized: "of \(ByteFormat.string(total))"))
        }
        self.init(title: status.title, status: status.detail, graphic: graphic, loading: !storage.isLoaded)
    }

    init(title: String, figure: String? = nil, status: String, needsAttention: Bool = false, graphic: TileGraphic? = nil, loading: Bool = false,
         switchAction: Action? = nil) {
        self.title = title
        self.figure = figure
        self.status = status
        self.needsAttention = needsAttention
        self.graphic = graphic
        self.loading = loading
        self.switchAction = switchAction
    }
}

/// A tile's face: its deep color, its chart above the caption, and a mark when something waits for the user. `progress` runs from 0
/// on the dashboard to 1 when the tile has become a page: the chart and the mark leave, the color stays as the page's ground.
struct TileFace: View {
    let tint: TileTint
    let info: TileInfo
    var progress: CGFloat = 0
    /// The pointer is over the tile, and which block of its chart it is on. Not the pointer's position: the face is redrawn only
    /// when one of these changes, not on every mouse move.
    var hovering = false
    var hoveredBlock: String?
    /// On the dashboard the tiles' grounds are drawn together, in a layer of their own under all the faces (`HomeView`); the zoom's card
    /// draws its own.
    var drawsBackdrop = true
    /// The switch of a `state` chart is drawn over the tile, apart from the face (`TileSwitch`); the face keeps its place.
    var switchOverlaid = false
    @Environment(\.design) private var design

    /// Room left under the chart for the caption: a one-line caption at 22 points, with the margin under it (`margin`).
    static let captionBand: CGFloat = 62

    /// The tile's one margin, 12 points: from the top edge to the chart, from the sides to the chart, from the right edge to the
    /// caption, and from the bottom edge to the caption's baseline (`TileContent`), on every tile, large or small. The chart started
    /// 15 points down while its sides were 12 away, which left the top looking wider (2026-10-13); 12 is the sides' margin, kept.
    static let margin: CGFloat = 12
    static let topInset: CGFloat = margin

    /// The caption's size, which sets how much room it leaves the legend under a blocks chart.
    var captionSize: CGFloat = 22
    /// The tile's size at rest, in its cell, when the face is drawn at another: lifted under the pointer, or on its way to another
    /// cell. What the chart decides by its size (the blocks' order, where the legend goes) is decided at rest, so it does not jump
    /// back and forth while the tile moves. nil: at the size it is drawn.
    var restingSize: CGSize?

    /// The least width the line naming the block under the pointer reads in.
    static let legendMinimumWidth: CGFloat = 84

    /// Where a blocks chart sits in a tile of `size`: from the top margin down to the caption, whose height it leaves (never less
    /// than `captionBand`), so a caption that takes more lines (`CaptionLayout`) takes only what they need. The line naming the block
    /// under the pointer goes left of the caption, only where it has room there (`legendShown`); it never takes room from the chart.
    /// Going above the caption where it had none, it took a row off the chart, and the chart jumped by that row each time the
    /// window's width crossed the point (2026-10-13).
    static func chartArea(in size: CGSize, info: TileInfo, captionSize: CGFloat, restingSize: CGSize? = nil) -> CGRect {
        let rest = restingSize ?? size
        let band = captionHeight(in: rest, info: info, captionSize: captionSize) + 14
        return CGRect(x: margin, y: topInset, width: max(size.width - 2 * margin, 0), height: max(size.height - topInset - band, 0))
    }

    static let minimumChartHeight: CGFloat = 40
    /// From the blocks to the line naming the one under the pointer: in the room between the chart and the caption, clear of both.
    static let legendGap: CGFloat = 2

    /// What the caption takes from the tile's bottom edge up: its title lines, its status line and the room under it.
    static func captionHeight(in size: CGSize, info: TileInfo, captionSize: CGFloat) -> CGFloat {
        let layout = CaptionLayout(info: info, size: captionSize, width: size.width - 2 * CaptionSize.tilePadding)
        let status = CaptionFont.status(size: captionSize)
        return max(captionBand, layout.titleHeight + ceil(status.ascender - status.descender + status.leading) + TileContent.captionBottom(size: captionSize))
    }

    /// Whether the line naming the block under the pointer has room left of the caption.
    static func legendShown(in size: CGSize, info: TileInfo, captionSize: CGFloat) -> Bool {
        legendRoom(in: size, info: info, captionSize: captionSize) >= legendMinimumWidth
    }

    /// The width left of the caption for the legend.
    static func legendRoom(in size: CGSize, info: TileInfo, captionSize: CGFloat) -> CGFloat {
        let padding = CaptionSize.tilePadding
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        let layout = CaptionLayout(info: info, size: captionSize, width: size.width - 2 * padding)
        let measured = max(layout.titleWidth, width(info.status, CaptionFont.status(size: captionSize)))
        // The caption never runs past the tile: where it would, it takes more lines (`CaptionLayout`).
        let caption = min(ceil(measured), max(size.width - 2 * padding, 0))
        return size.width - margin - 12 - caption - padding
    }

    @Environment(\.openPageRadius) private var pageRadius

    var body: some View {
        let chartOpacity = 1 - ZoomMath.ramp(progress, 0, 0.35)
        ZStack(alignment: .topLeading) {
            if drawsBackdrop {
                TileBackdrop(tint: tint, cornerRadius: ZoomMath.lerp(Theme.tileRadius, pageRadius ?? Theme.windowRadius, progress),
                             loading: info.loading)
            } else {
                Color.clear
            }
            // While a tile has nothing to show yet, placeholder blocks breathe in its place.
            // Not drawn once it has faded out (on the card under an open page): its animations would keep the window redrawing.
            if chartOpacity > 0, let graphic = info.graphic ?? (info.loading ? .blocks(LoadingWave.placeholderBlocks) : nil) {
                // Each chart puts only its glass shapes in a glass container (it draws only glass); its text stays outside.
                GeometryReader { proxy in
                    chart(graphic, in: proxy.size)
                }
                .opacity(chartOpacity)
            }
            // Over the chart too: the chart's glass would otherwise see the shade behind it and adapt to it late. Only where the face
            // draws its own ground (the zoom's card); on the dashboard the ground darkens itself, in the glass layer (`TileGround`).
            if drawsBackdrop && design.glass && design.hoverShade {
                HoverShade(shape: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous), on: hovering, amount: Theme.tileHoverShade)
            }
        }
        .overlay {
            if case let .state(on, alarming, _, _, _)? = info.graphic, on && alarming {
                GlowEdge().opacity(chartOpacity).transition(.opacity)
            }
        }
        // The mark sits in the bottom-left corner, on the caption's last line, clear of the switch and the window's buttons at the top.
        .overlay(alignment: .bottomLeading) {
            if info.needsAttention {
                AttentionMark()
                    .opacity(chartOpacity)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Theme.hover, value: info.needsAttention)
    }

    private func legend(_ mark: some View, _ text: String) -> some View {
        HStack(spacing: 4) {
            mark.frame(width: 8, height: 8)
            Text(text)
        }
    }

    @ViewBuilder
    private func chart(_ graphic: TileGraphic, in size: CGSize) -> some View {
        let palette = design.palette(tint)
        switch graphic {
        case let .blocks(segments):
            let area = Self.chartArea(in: size, info: info, captionSize: captionSize, restingSize: restingSize)
            let blocks = BlockLayout.blocks(segments, limit: ChartLook.tile.limit)
            let hovered = hoveredBlock.flatMap { id in blocks.first { $0.segment.id == id }?.segment }
            // No names in the blocks: the one under the pointer is named in the line just under them.
            BlocksView(segments: segments, tint: tint, labels: false, hovered: hovered?.id, gap: CGFloat(TileType.current.tileGap),
                       outerRadius: TileType.current.concentricCorners ? Theme.tileRadius - Self.margin : nil,
                       look: .tile, loading: info.loading,
                       orderSize: restingSize.map { Self.chartArea(in: $0, info: info, captionSize: captionSize, restingSize: $0).size })
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
            // What the pointer is on, and nothing otherwise: its name and size, in the tile's small text, just under the blocks and as
            // wide as them, on every tile. Beside the caption, it had no room on a small tile and named nothing there.
            Group {
                if let hovered { Text("\(hovered.label) · \(ByteFormat.string(hovered.bytes))") }
            }
            .font(TileType.current.smallText)
            .foregroundStyle(palette.soft)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: area.width, alignment: .leading)
            .offset(x: area.minX, y: area.maxY + Self.legendGap)
            .animation(Theme.hover, value: hovered?.id)
        case let .dots(dots):
            VStack(alignment: .leading, spacing: 10) {
                DotsView(dots: dots, tint: tint, diameter: min(15, (size.width - 2 * Self.margin - 6 * 7) / 7), loading: info.loading)
                HStack(spacing: 10) {
                    legend(Circle().fill(palette.step(5)), String(localized: "disabled"))
                    legend(Circle().strokeBorder(palette.step(3), lineWidth: 1.5), String(localized: "enabled"))
                    if dots.contains(.attention) { legend(Circle().fill(design.action), String(localized: "undone")) }
                }
                .font(TileType.current.smallText)
                .foregroundStyle(palette.soft)
                .lineLimit(1)
            }
            .padding(.leading, Self.margin)
            .padding(.top, Self.topInset)
            .padding(.trailing, Self.margin)
        case let .state(on, _, detail, meter, actionable):
            StateView(on: on, detail: detail, meter: meter, meterIsActionable: actionable, tint: tint, loading: info.loading,
                      part: switchOverlaid ? .allButSwitch : .all, disabled: info.switchAction == nil,
                      showsDetail: StateView.detailFits(detail, width: size.width - 2 * Self.margin))
                // The tile's width, so the detail stays on one line; the meter keeps its own width (`StateView`).
                .frame(width: max(size.width - 2 * Self.margin, 0), alignment: .leading)
                .padding(.leading, Self.margin)
                .padding(.top, Self.topInset)
        case let .gauge(value, _, _):
            // A bar across the tile, centered in the room between the window's close button, in this tile's top-left corner, and
            // the caption, which says the figures.
            let top = GlassCircleButton.margin + GlassCircleButton.diameter
            BarGaugeView(value: value, tint: tint, loading: info.loading)
                .frame(width: max(size.width - 30, 0), height: BarGaugeView.height)
                .position(x: size.width / 2, y: (top + max(size.height - Self.captionBand, top)) / 2)
        }
    }
}

/// The caption's size, in two steps for each kind of tile: smaller on a short tile, so its chart keeps room, larger once the tile is
/// tall enough. Worked out from the tile's height point by point, it changed with every point of a resize, and the text grew and
/// shrank while the window was dragged (2026-10-13); now it changes at most once, at its step.
enum CaptionSize {
    /// The caption's distance from the tile's right edge: the tile's margin (`TileFace.margin`).
    static let tilePadding: CGFloat = 12

    static func tile(height: CGFloat, large: Bool) -> CGFloat {
        let type = TileType.current
        return CGFloat(large ? (height >= 300 ? type.largeTallSize : type.largeSize) : (height >= 180 ? type.mediumSize : type.smallSize))
    }
}

/// One entry of the dashboard.
struct DashboardTile: Identifiable {
    let destination: Destination
    let size: Bento.Size
    let tint: TileTint

    var id: Destination { destination }
    var opens: Bool { destination != .storage }
    /// The featured tile, two cells by two.
    var large: Bool { size.height > 1 }
}

/// The dashboard: the startup disk, one tile per active module and Settings, packed into a bento grid that fills the glass. Tiles
/// come in one after another each time the window opens, leave in reverse order when it closes, and glide to their new places when a
/// module is switched on or off.
struct HomeView: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var storage: StorageOverview
    /// Where each tile is, for the zoom into it.
    var frames = TileFrames()
    let open: (Destination) -> Void
    /// The tile that is being replaced by the zoom; it is not drawn so it does not show through.
    var hiddenTile: Destination?
    /// The window is closing: the tiles leave.
    var closing = false
    /// A page fully covers the dashboard: the tiles are not drawn (their glass and animations cost the GPU even when hidden), but
    /// their places are still laid out and recorded for the zoom back.
    var dormant = false
    /// The Settings tile; the standard window has Settings in its sidebar instead.
    var showsSettingsTile = true
    @State private var appeared = false
    /// The tile under the pointer, and where on it in coarse steps. Held here, not in each tile, because a tile's ground and its face
    /// are drawn in different layers and both lift and lean with it.
    @State private var pointerTile: Destination?
    @State private var lean = UnitPoint.center
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the tiles take to leave, for the window to wait before it goes.
    static func depopulateDuration(tiles: Int) -> Double { 0.26 + Double(max(tiles - 1, 0)) * Theme.depopulateStagger }

    static let minimumRowHeight: CGFloat = 120

    /// How the tiles are arranged in the glass: the number of columns, and whether they scroll because they do not fit.
    struct Arrangement: Equatable {
        var columns: Int
        var scrolls: Bool
    }

    static func arrangement(for size: CGSize, sizes: [Bento.Size]) -> Arrangement {
        let columns = Bento.columns(for: size.width)
        let rows = Bento.rows(Bento.pack(sizes: sizes, columns: columns))
        return Arrangement(columns: columns, scrolls: needed(rows: rows) > size.height)
    }

    static func needed(rows: Int) -> CGFloat {
        CGFloat(rows) * minimumRowHeight + CGFloat(max(rows - 1, 0)) * Theme.spacing
    }

    /// The disk is rose and Settings slate; each module brings its own color, else takes the next free one. The disk and Settings
    /// are always one cell; the featured module comes right after the disk and takes two by two, every other module one cell.
    @MainActor
    static func tiles(for handles: [ModuleHandle], includesSettings: Bool = true) -> [DashboardTile] {
        let large = featured(handles.map { (id: $0.id, reclaimable: $0.tile?.reclaimableBytes, wide: $0.manifest.tileSize == .wide) })
        var tiles = [DashboardTile(destination: .storage, size: Bento.Size(width: 1, height: 1), tint: .rose)]
        let spare: [TileTint] = [.blue, .teal, .graphite]
        var next = 0
        let ordered = handles.filter { $0.id == large } + handles.filter { $0.id != large }
        for handle in ordered {
            var tint = handle.manifest.tileTint
            if tint == nil { tint = spare[next % spare.count]; next += 1 }
            let size = handle.id == large ? Bento.Size(width: 2, height: 2) : Bento.Size(width: 1, height: 1)
            tiles.append(DashboardTile(destination: .module(handle.id), size: size, tint: tint ?? .blue))
        }
        if includesSettings { tiles.append(DashboardTile(destination: .settings, size: Bento.Size(width: 1, height: 1), tint: .slate)) }
        return tiles
    }

    /// The module that gets the large tile: the one that can free the most; while none can free anything, the one whose manifest asks
    /// for a wide tile, else the first. The dashboard redraws when a module's figure arrives (`ModuleHost.reclaimable`), and the tiles
    /// glide and resize into the new layout.
    nonisolated static func featured(_ modules: [(id: String, reclaimable: UInt64?, wide: Bool)]) -> String? {
        if let most = modules.filter({ ($0.reclaimable ?? 0) > 0 }).max(by: { ($0.reclaimable ?? 0) < ($1.reclaimable ?? 0) }) { return most.id }
        return (modules.first { $0.wide } ?? modules.first)?.id
    }

    /// The tiles at their places in a grid of `size`, in two layers: every tile's ground (its glass) at the bottom and every tile's face
    /// over it, moved alike by `TilePlacement`. Not in a glass container: one drew the six grounds in a single pass (about 10 points of
    /// GPU less while hovering), but it drew the glass apart from the faces, and a lifting tile's glass edge trailed behind its face.
    private func grid(_ tiles: [DashboardTile], placements: [Bento.Placement], columns: Int, rows: Int, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if !dormant {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    let frame = Bento.frame(placements[index], columns: columns, rows: rows, in: size)
                    DashboardGround(destination: tile.destination, host: host, storage: storage, tint: tile.tint,
                                    lifted: pointerTile == tile.destination && design.lift, hovering: pointerTile == tile.destination)
                        .modifier(placed(tile, index: index, count: tiles.count, frame: frame))
                }
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    let frame = Bento.frame(placements[index], columns: columns, rows: rows, in: size)
                    DashboardTileView(tile: tile, host: host, storage: storage, captionSize: CaptionSize.tile(height: frame.height, large: tile.large), restingSize: frame.size,
                                      isHidden: hiddenTile == tile.destination, hovering: pointerTile == tile.destination,
                                      onPointer: { lean in pointer(tile.destination, lean) }) {
                        open(tile.destination)
                    }
                    .modifier(placed(tile, index: index, count: tiles.count, frame: frame))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // The gaps between tiles are glass too: dragging there moves the window.
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()).allowsWindowActivationEvents(true) }
        .animation(Theme.layout, value: tiles.map(\.id))
        .animation(Theme.layout, value: tiles.map(\.size))
    }

    /// Everything that moves a tile, the same for its ground and its face so the two stay one: coming in and leaving with the window,
    /// its place, the lift and lean (or tilt) under the pointer, and hiding under the zoom.
    ///
    /// The face (`face`) lifts and leans with its ground, but as a scale and an offset (`TilePlacement.liftsByTransform`), not laid
    /// out: laid out again on every frame, its caption stepped from pixel to pixel (or, between pixels, blurred), and the blocks
    /// re-flowed into another arrangement (2026-10-12).
    private func placed(_ tile: DashboardTile, index: Int, count: Int, frame: CGRect, face: Bool = false) -> TilePlacement {
        let moves = pointerTile == tile.destination
        // No 3D turn over any glass, tiles or chart elements: inside a turned (projected) view AppKit's glass is drawn the expensive
        // way and in its dimmed look, so glass elements darkened under the pointer.
        let turns = !design.glass && !design.glassElements
        return TilePlacement(shown: appeared && !closing, closing: closing, index: index, count: count, frame: frame,
                             lifted: moves && design.lift && tile.opens,
                             lean: moves && design.tilt && !reduceMotion ? lean : .center,
                             turns: turns, liftsByTransform: face, reduceMotion: reduceMotion,
                             liftAnimation: design.liftAnimation, leanAnimation: design.leanAnimation,
                             hidden: hiddenTile == tile.destination)
    }

    /// The pointer moved over a tile (`lean` in steps across it) or left it (nil).
    private func pointer(_ destination: Destination, _ newLean: UnitPoint?) {
        if let newLean {
            if pointerTile != destination { pointerTile = destination }
            if lean != newLean { lean = newLean }
        } else if pointerTile == destination {
            pointerTile = nil
            lean = .center
        }
    }

    var body: some View {
        let tiles = host.hasScanned ? Self.tiles(for: host.dashboardHandles, includesSettings: showsSettingsTile) : []
        let sizes = tiles.map(\.size)
        GeometryReader { proxy in
            // A new size takes its arrangement at once, every tile following the window: the tiles used to leave and come back
            // whenever the number of columns changed, which flashed the dashboard empty in the middle of a resize (2026-10-13).
            let arrangement = Self.arrangement(for: proxy.size, sizes: sizes)
            let columns = arrangement.columns
            let placements = Bento.pack(sizes: sizes, columns: columns)
            let rows = Bento.rows(placements)
            let size = CGSize(width: proxy.size.width, height: max(proxy.size.height, Self.needed(rows: rows)))
            // The zoom needs each tile's place. It is taken from the layout, not measured on screen: measured frames include the hover
            // lift, the press and the dashboard receding behind an open page, and a card closing onto them landed beside its tile.
            let _ = frames.record(zip(tiles, placements).map { ($0.destination, Bento.frame($1, columns: columns, rows: rows, in: size)) },
                                  large: Set(tiles.filter(\.large).map(\.destination)))
            Group {
                if !arrangement.scrolls {
                    // Everything fits: no scroll view. One wrapped the tiles even when it could not scroll, and added its own layers to
                    // every frame the window draws.
                    let _ = (frames.scrollOffset = 0)
                    grid(tiles, placements: placements, columns: columns, rows: rows, size: size)
                } else {
                    ScrollView {
                        grid(tiles, placements: placements, columns: columns, rows: rows, size: size)
                    }
                    .scrollIndicators(.never)
                    .scrollEdgeEffectHidden(true, for: .all)
                    // A lifted tile may reach into the glass frame; the scroll view must not cut it.
                    .scrollClipDisabled()
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in frames.scrollOffset = offset }
                }
            }
        }
        // Each time the window opens, once the tiles are known: a moment later, so the change animates instead of landing in the
        // first frame.
        .task(id: host.hasScanned) {
            guard host.hasScanned else { return }
            try? await Task.sleep(for: .milliseconds(30))
            appeared = true
        }
        .onDisappear { appeared = false }
    }
}

/// A tile's face on the dashboard: its chart and caption, the click, and the pointer. Its ground is drawn in the layer under it
/// (`TileGround`), and both are moved together by `TilePlacement`. A glass tile leans toward the pointer instead of turning in 3D:
/// under a 3D rotation, glass redraws what it shows late.
struct DashboardTileView: View {
    let tile: DashboardTile
    @ObservedObject var host: ModuleHost
    @ObservedObject var storage: StorageOverview
    let captionSize: CGFloat
    /// Its size in its cell, without the lift (`TileFace.restingSize`).
    let restingSize: CGSize
    /// The tile is under an open page: it ignores the pointer, so it comes back flat when the page closes onto it.
    var isHidden = false
    /// The pointer is over this tile (held by the dashboard).
    var hovering = false
    /// Reports the pointer in coarse steps across the tile (10 %), or nil when it leaves: only a change of step moves the tile.
    let onPointer: (UnitPoint?) -> Void
    let open: () -> Void
    /// The block of the chart under the pointer: the face is redrawn only when it changes, not on every mouse move.
    @State private var hoveredBlock: String?
    @State private var lastStep: UnitPoint?
    @State private var size = CGSize.zero
    @Environment(\.design) private var design

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
        // A drag that moved the window is not a click (`WindowMoveCheck`).
        Button { if tile.opens && !WindowMoveCheck.shared.windowMoved() { open() } } label: {
            // Not clipped: everything in the tile is drawn inside its shape already, and a clip made every frame mask the whole tile.
            TileContent(destination: tile.destination, tint: tile.tint, host: host, storage: storage, captionSize: captionSize,
                        hovering: hovering, hoveredBlock: hoveredBlock, drawsBackdrop: false, switchOverlaid: true, restingSize: restingSize)
                .contentShape(shape)
        }
        .buttonStyle(TilePressStyle(pressable: tile.opens))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tile.opens ? .isButton : [])
        // Over the button, not in it: a click on the switch flips it and does not open the tile. A control of its own for
        // VoiceOver too, not merged into the tile.
        .overlay(alignment: .topLeading) {
            if case let .module(id) = tile.destination, let handle = host.handle(for: id) { TileSwitch(handle: handle, tint: tile.tint) }
        }
        .studioPickable(.tile(tile.tint), in: shape)
        // The whole dashboard moves the window, the tiles too: they never move themselves, so a drag on one has nothing else to do.
        .simultaneousGesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onContinuousHover { phase in
            switch phase {
            // The disk's tile opens nothing: it takes the pointer only to move the window, and does not lift.
            case let .active(location) where size.width > 0 && !isHidden && design.trackPointer && tile.opens:
                let step = 10.0
                let next = UnitPoint(x: (location.x / size.width * step).rounded() / step, y: (location.y / size.height * step).rounded() / step)
                if next != lastStep { lastStep = next; onPointer(next) }
                let block = block(at: location)
                if block != hoveredBlock { hoveredBlock = block }
            default:
                resetPointer()
            }
        }
        .onChange(of: isHidden) { _, hidden in if hidden { resetPointer() } }
        // Watching the mouse from the first press on (`WindowMoveCheck`).
        .onAppear { _ = WindowMoveCheck.shared }
    }

    private func resetPointer() {
        if lastStep != nil { lastStep = nil; onPointer(nil) }
        if hoveredBlock != nil { hoveredBlock = nil }
    }

    /// The block of this tile's chart under `location`, if the chart is blocks.
    private func block(at location: CGPoint) -> String? {
        guard case let .module(id) = tile.destination, let handle = host.handle(for: id),
              case let .blocks(segments)? = handle.tile?.graphic else { return nil }
        let info = TileInfo(handle)
        let area = TileFace.chartArea(in: size, info: info, captionSize: captionSize, restingSize: restingSize)
        return BlocksView.segment(at: CGPoint(x: location.x - area.minX, y: location.y - area.minY), in: area.size, segments: segments,
                                  orderSize: TileFace.chartArea(in: restingSize, info: info, captionSize: captionSize, restingSize: restingSize).size,
                                  look: .tile)?.id
    }
}

/// Whether the window moved since the mouse went down: a drag that starts on a tile moves the window (`WindowDragGesture`), and the
/// tile's button then sees a click where it is let go, which must not open it.
@MainActor
final class WindowMoveCheck {
    static let shared = WindowMoveCheck()
    private var monitor: Any?
    private var origin: NSPoint?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.origin = event.window?.frame.origin }
            return event
        }
    }

    func windowMoved() -> Bool {
        guard let origin, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        return hypot(window.frame.origin.x - origin.x, window.frame.origin.y - origin.y) > 2
    }
}

/// A tile's ground on the dashboard, in the layer under the faces. A flat tile casts its shadow from this plain rounded shape, not from
/// its whole content (which was recomputed on every frame the tile moved); a glass tile casts none, as it would show inside the glass.
struct TileGround: View {
    let tint: TileTint
    let lifted: Bool
    /// The pointer is over the tile. A glass ground darkens its own tint, inside the glass, so the shade is the glass's own shape.
    var hovering = false
    /// The tile is loading: its ground brightens and dims (`TileBackdrop.loading`).
    var loading = false
    @Environment(\.design) private var design

    var body: some View {
        if design.glass {
            TileBackdrop(tint: tint, darkened: hovering && design.hoverShade, loading: loading)
        } else {
            TileBackdrop(tint: tint, loading: loading)
                .background {
                    LabFill(shape: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous), color: design.palette(tint).base,
                            fill: design.fill(.tile(tint)))
                        .shadow(color: .black.opacity(lifted ? 0.22 : 0.07), radius: lifted ? 14 : 5, y: lifted ? 8 : 2)
                }
                .animation(design.liftAnimation, value: lifted)
        }
    }
}

/// A dashboard tile's ground, loading while its module or the disk is being read: it follows the module (or the disk) itself, as the
/// tile's face does (`TileContent`).
private struct DashboardGround: View {
    let destination: Destination
    @ObservedObject var host: ModuleHost
    @ObservedObject var storage: StorageOverview
    let tint: TileTint
    let lifted: Bool
    let hovering: Bool

    var body: some View {
        switch destination {
        case let .module(id):
            if let handle = host.handle(for: id) {
                ModuleGround(handle: handle, tint: tint, lifted: lifted, hovering: hovering)
            } else {
                TileGround(tint: tint, lifted: lifted, hovering: hovering)
            }
        case .storage: TileGround(tint: tint, lifted: lifted, hovering: hovering, loading: !storage.isLoaded)
        case .settings, .home: TileGround(tint: tint, lifted: lifted, hovering: hovering)
        }
    }
}

private struct ModuleGround: View {
    @ObservedObject var handle: ModuleHandle
    let tint: TileTint
    let lifted: Bool
    let hovering: Bool

    var body: some View { TileGround(tint: tint, lifted: lifted, hovering: hovering, loading: TileInfo(handle).loading) }
}

/// Moves a tile's ground and face alike: in with the window one after another, out in reverse order, to its place, lifted and leaning
/// (or, flat, tilted) under the pointer, and hidden while the zoom stands in for it.
struct TilePlacement: ViewModifier {
    let shown: Bool
    let closing: Bool
    let index: Int
    let count: Int
    let frame: CGRect
    let lifted: Bool
    let lean: UnitPoint
    let turns: Bool
    /// Lifted and leaning as a scale and an offset of what is drawn, at its resting size and place: a face, whose text and blocks must
    /// not be laid out again on every frame. Its glass ground keeps being laid out (see below).
    var liftsByTransform = false
    let reduceMotion: Bool
    let liftAnimation: Animation
    let leanAnimation: Animation
    let hidden: Bool

    /// The lift and the lean are laid out (the tile's size and place worked out again on every frame), not drawn as a scale and an
    /// offset: glass moved by those effects followed on its own timing, and the darkened color inside a hovered tile's glass showed
    /// out of line with the glass's edge while the tile lifted.
    /// Coming in and leaving is laid out too, not a scale effect: a tile's glass ground (AppKit) followed a scale effect on its own
    /// timing, and while the tiles came in (when the charts load) a ghost of each ground showed beside its face.
    func body(content: Content) -> some View {
        let lift: CGFloat = lifted ? 1.018 : 1
        let grow: CGFloat = (liftsByTransform ? 1 : lift) * (shown || reduceMotion ? 1 : 0.86)
        let leanOffset = turns ? CGSize.zero : CGSize(width: (lean.x - 0.5) * 4, height: (lean.y - 0.5) * 4)
        let laidOutLean = liftsByTransform ? CGSize.zero : leanOffset
        content
            .modifier(TileSize(size: CGSize(width: frame.width * grow, height: frame.height * grow)))
            .animation(liftAnimation, value: lifted)
            .scaleEffect(liftsByTransform ? lift : 1)
            .animation(liftAnimation, value: lifted)
            .offset(liftsByTransform ? leanOffset : .zero)
            .animation(leanAnimation, value: lean)
            .tilted(lean, active: turns)
            .opacity(shown ? 1 : 0)
            .animation(closing ? Theme.depopulate.delay(Double(count - 1 - index) * Theme.depopulateStagger)
                               : Theme.layout.delay(0.12 + Double(index) * Theme.populateStagger), value: shown)
            .modifier(TileCenter(center: CGPoint(x: frame.midX + laidOutLean.width, y: frame.midY + laidOutLean.height)))
            .animation(leanAnimation, value: lean)
            .opacity(hidden ? 0 : 1)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// A tile's size, laid out on every frame while it changes.
///
/// In whole device pixels, and an even number of them, so that its middle (`TileCenter`) and its edges fall on pixels too. Lifted
/// under the pointer, a tile is 1.8 % larger: at any fraction of a pixel, its caption, pinned to its corner, was drawn between pixels,
/// softer and thinner than at rest, and moved by fractions while the tile lifted, which read as jitter (2026-10-12).
private struct TileSize: ViewModifier, @preconcurrency Animatable {
    var size: CGSize
    @Environment(\.displayScale) private var scale

    var animatableData: CGSize.AnimatableData {
        get { size.animatableData }
        set { size.animatableData = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(width: PixelGrid.even(max(size.width, 0), scale: scale), height: PixelGrid.even(max(size.height, 0), scale: scale))
    }
}

/// Where a tile's middle is in the grid, laid out on every frame while it moves. On a whole device pixel (`TileSize`).
private struct TileCenter: ViewModifier, @preconcurrency Animatable {
    var center: CGPoint
    @Environment(\.displayScale) private var scale

    var animatableData: CGPoint.AnimatableData {
        get { center.animatableData }
        set { center.animatableData = newValue }
    }

    func body(content: Content) -> some View {
        content.position(x: PixelGrid.whole(center.x, scale: scale), y: PixelGrid.whole(center.y, scale: scale))
    }
}

/// Lengths rounded to the screen's pixels.
enum PixelGrid {
    /// The nearest whole number of pixels, in points.
    static func whole(_ length: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = max(scale, 1)
        return (length * scale).rounded() / scale
    }

    /// The nearest even number of pixels, in points: half of it is whole pixels too.
    static func even(_ length: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = max(scale, 1)
        return ((length * scale / 2).rounded() * 2) / scale
    }
}

/// The face and caption of the tile for `destination`, kept up to date with its module. Used on the dashboard and by the zoom.
struct TileContent: View {
    let destination: Destination
    let tint: TileTint
    @ObservedObject var host: ModuleHost
    @ObservedObject var storage: StorageOverview
    var captionSize: CGFloat
    var progress: CGFloat = 0
    var captionPadding: CGFloat = CaptionSize.tilePadding
    var hovering = false
    var hoveredBlock: String?
    var drawsBackdrop = true
    /// The zoom draws the face and the caption in separate layers, so the page can scroll between them.
    var showsFace = true
    var showsCaption = true
    /// The caption leaves as the tile opens: the page names itself at the top.
    var captionOpacity: CGFloat = 1
    /// The dashboard draws a `state` chart's switch over the tile itself (`TileSwitch`).
    var switchOverlaid = false
    /// The tile's size in its cell (`TileFace.restingSize`); nil where it is drawn at rest.
    var restingSize: CGSize?
    /// The width the caption is laid out in, when not the tile's: the zoom's, the tile's on the dashboard.
    var captionWidth: CGFloat?

    var body: some View {
        switch destination {
        case let .module(id):
            if let handle = host.handle(for: id) { ModuleTileContent(handle: handle, content: self) }
        case .settings: layout(TileInfo.settings)
        case .storage: layout(TileInfo(storage))
        case .home: EmptyView()
        }
    }

    /// Room under the caption: its baseline is as far from the tile's bottom edge as the chart is from the top edge
    /// (`TileFace.topInset`), so the tile is framed alike above and below. The line's descent lies under the baseline.
    static func captionBottom(size: CGFloat) -> CGFloat {
        max(TileFace.topInset + CaptionFont.status(size: size).descender, 0)
    }

    func layout(_ info: TileInfo) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if showsFace { TileFace(tint: tint, info: info, progress: progress, hovering: hovering, hoveredBlock: hoveredBlock,
                                      drawsBackdrop: drawsBackdrop, switchOverlaid: switchOverlaid, captionSize: captionSize,
                                      restingSize: restingSize) } else { Color.clear }
            if showsCaption {
                TileCaption(title: info.title, figure: info.figure, status: info.status, size: captionSize, loading: info.loading,
                            layoutWidth: (captionWidth ?? restingSize?.width).map { max(1, $0 - 2 * captionPadding) })
                    .padding([.top, .horizontal], captionPadding)
                    .padding(.bottom, Self.captionBottom(size: captionSize))
                    .frame(width: captionWidth, alignment: .trailing)
                    .opacity(captionOpacity)
            }
        }
    }
}

private struct ModuleTileContent: View {
    @ObservedObject var handle: ModuleHandle
    let content: TileContent

    var body: some View { content.layout(TileInfo(handle)) }
}

/// The tile darkens while pressed. A shade laid over it, not a brightness filter: a filter stays on the tile even at 0 and makes every
/// frame draw the whole tile through it. It does not sink: its ground, in the layer underneath, cannot see the press.
private struct TilePressStyle: ButtonStyle {
    /// A tile that opens nothing (the disk) takes the drag that moves the window, and shows no press.
    var pressable = true
    /// Read so a change of the corner radius redraws the press shade.
    @Environment(\.design) private var design

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .fill(.black.opacity(configuration.isPressed && pressable ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .animation(Theme.press, value: configuration.isPressed)
    }
}

/// A `state` chart's switch on the dashboard, drawn where the face leaves its place. Flipped, it runs the tile's `switchAction` as the
/// page's switch row does.
private struct TileSwitch: View {
    @ObservedObject var handle: ModuleHandle
    let tint: TileTint

    var body: some View {
        let info = TileInfo(handle)
        if case let .state(on, _, detail, meter, actionable)? = info.graphic {
            StateView(on: on, detail: detail, meter: meter, meterIsActionable: actionable, tint: tint, loading: info.loading, part: .switchOnly,
                      flip: info.switchAction.map { action in { [handle] value in
                          // Quiet, as the page's switch: it has already moved.
                          let result = await handle.perform(action, extraParameters: ["value": value ? "true" : "false"], quiet: true)
                          return result.map { $0.outcome != .failed } ?? false
                      } },
                      disabled: info.switchAction == nil)
                .padding(.leading, TileFace.margin)
                .padding(.top, TileFace.topInset)
        }
    }
}
