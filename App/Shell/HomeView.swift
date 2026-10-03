import MacSpacePlatform
import MacSpaceSdk
import SwiftUI

/// What a tile shows, whoever it belongs to.
struct TileInfo: Equatable {
    var title: String
    var status: String
    var needsAttention = false
    var graphic: TileGraphic?
    var loading = false

    static let settings = TileInfo(title: "MacSpace", status: "settings")

    @MainActor
    init(_ handle: ModuleHandle) {
        if let tile = handle.tile {
            self.init(title: tile.title, status: tile.status, needsAttention: tile.needsAttention, graphic: tile.graphic, loading: handle.tileIsStale)
        } else {
            self.init(title: handle.manifest.name.lowercased(), status: "looking…", loading: true)
        }
    }

    /// The disk: an arc filled as far as the disk is used, what macOS can purge by itself as the lighter part after it.
    @MainActor
    init(_ storage: StorageOverview) {
        let status = storage.status
        // An empty gauge while the disk is read, so the light running along it shows where the figure will be.
        var graphic = TileGraphic.gauge(value: 0, extra: 0, label: "", sublabel: "")
        if let used = storage.usedFraction, let total = storage.totalBytes {
            graphic = .gauge(value: used, extra: storage.purgeableFraction ?? 0, label: "\(Int((used * 100).rounded()))%",
                             sublabel: "of \(ByteFormat.string(total))")
        }
        self.init(title: status.title, status: status.detail, graphic: graphic, loading: !storage.isLoaded)
    }

    init(title: String, status: String, needsAttention: Bool = false, graphic: TileGraphic? = nil, loading: Bool = false) {
        self.title = title
        self.status = status
        self.needsAttention = needsAttention
        self.graphic = graphic
        self.loading = loading
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
    @Environment(\.design) private var design

    /// Room left under the chart for the caption.
    static let captionBand: CGFloat = 62

    /// Where a blocks chart sits in a tile of `size`.
    static func chartArea(in size: CGSize) -> CGRect {
        CGRect(x: 12, y: 12, width: max(size.width - 24, 0), height: max(size.height - 12 - captionBand - 14, 0))
    }

    var body: some View {
        let chartOpacity = 1 - ZoomMath.ramp(progress, 0, 0.35)
        ZStack(alignment: .topLeading) {
            if drawsBackdrop { TileBackdrop(tint: tint, isPage: progress >= 1) } else { Color.clear }
            // While a tile has nothing to show yet, placeholder blocks breathe in its place.
            // Not drawn once it has faded out (on the card under an open page): its animations would keep the window redrawing.
            if chartOpacity > 0, let graphic = info.graphic ?? (info.loading ? .blocks(LoadingWave.placeholderBlocks) : nil) {
                GlassGroup {
                    GeometryReader { proxy in
                        chart(graphic, in: proxy.size)
                    }
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
        .overlay(alignment: .topTrailing) {
            if info.needsAttention {
                AttentionMark()
                    .padding(12)
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
            let area = Self.chartArea(in: size)
            let hovered = hoveredBlock.flatMap { id in segments.first { $0.id == id } }
            BlocksView(segments: segments, tint: tint, labels: segments.contains { !$0.label.isEmpty }, hovered: hovered?.id, loading: info.loading)
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
            // What the pointer is on, or what amber means.
            HStack(spacing: 6) {
                if let hovered {
                    RoundedRectangle(cornerRadius: 2).fill(BlockColor.fill(hovered, rank: segments.firstIndex(of: hovered) ?? 0, tint: tint, design: design)).frame(width: 9, height: 9)
                    Text("\(hovered.label) · \(ByteFormat.string(hovered.bytes))")
                } else if segments.contains(where: { $0.tone == .caution }) {
                    RoundedRectangle(cornerRadius: 2).fill(design.action).frame(width: 9, height: 9)
                    Text("can be freed")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.soft)
            .offset(x: 14, y: area.maxY + 8)
            .animation(Theme.hover, value: hovered?.id)
        case let .dots(dots):
            VStack(alignment: .leading, spacing: 10) {
                DotsView(dots: dots, tint: tint, diameter: min(15, (size.width - 28 - 6 * 7) / 7), loading: info.loading)
                HStack(spacing: 10) {
                    legend(Circle().fill(palette.step(5)), "off")
                    legend(Circle().strokeBorder(palette.step(3), lineWidth: 1.5), "runs")
                    if dots.contains(.attention) { legend(Circle().fill(design.action), "undone") }
                }
                .font(.system(size: 11))
                .foregroundStyle(palette.soft)
                .lineLimit(1)
            }
            .padding(.leading, 14)
            .padding(.top, 16)
            .padding(.trailing, 14)
        case let .state(on, _, detail, meter, actionable):
            StateView(on: on, detail: detail, meter: meter, meterIsActionable: actionable, tint: tint, loading: info.loading)
                .frame(width: max(min(size.width - 28, 200), 0), alignment: .leading)
                .padding(.leading, 14)
                .padding(.top, 16)
        case let .gauge(value, extra, label, sublabel):
            // Clear of the window's close button, which sits in this tile's top-left corner. A ring needs height; a short tile gets a
            // bar across it instead.
            let side = min(size.width * 0.56, size.height - Self.captionBand - 34)
            if side >= 100 {
                GaugeView(value: value, extra: extra, label: label, sublabel: sublabel, tint: tint, loading: info.loading)
                    .frame(width: side, height: side)
                    .position(x: max(size.width / 2, 52 + side / 2), y: 20 + side / 2)
            } else {
                BarGaugeView(value: value, extra: extra, label: label, sublabel: sublabel, tint: tint, loading: info.loading)
                    .frame(width: max(size.width - 30, 0), alignment: .leading)
                    .offset(x: 15, y: 9)
            }
        }
    }
}

/// The caption's size: large on big tiles, smaller when the window is small, largest on a page.
enum CaptionSize {
    static let tilePadding: CGFloat = 15

    static func tile(height: CGFloat) -> CGFloat { min(22, max(14, height * 0.1)) }
}

/// One entry of the dashboard.
struct DashboardTile: Identifiable {
    let destination: Destination
    let size: Bento.Size
    let tint: TileTint

    var id: Destination { destination }
    var opens: Bool { destination != .storage }
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

    /// The disk is violet and Settings slate; each module brings its own color, else takes the next free one. The disk and Settings
    /// are always one cell; the featured module comes right after the disk and takes two by two, every other module one cell.
    @MainActor
    static func tiles(for handles: [ModuleHandle]) -> [DashboardTile] {
        let large = featured(handles.map { (id: $0.id, reclaimable: $0.tile?.reclaimableBytes, wide: $0.manifest.tileSize == .wide) })
        var tiles = [DashboardTile(destination: .storage, size: Bento.Size(width: 1, height: 1), tint: .violet)]
        let spare: [TileTint] = [.blue, .teal, .graphite]
        var next = 0
        let ordered = handles.filter { $0.id == large } + handles.filter { $0.id != large }
        for handle in ordered {
            var tint = handle.manifest.tileTint
            if tint == nil { tint = spare[next % spare.count]; next += 1 }
            let size = handle.id == large ? Bento.Size(width: 2, height: 2) : Bento.Size(width: 1, height: 1)
            tiles.append(DashboardTile(destination: .module(handle.id), size: size, tint: tint ?? .blue))
        }
        tiles.append(DashboardTile(destination: .settings, size: Bento.Size(width: 1, height: 1), tint: .slate))
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
                    TileGround(tint: tile.tint, lifted: pointerTile == tile.destination && design.lift,
                               hovering: pointerTile == tile.destination)
                        .frame(width: frame.width, height: frame.height)
                        .modifier(placed(tile, index: index, count: tiles.count, frame: frame))
                }
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    let frame = Bento.frame(placements[index], columns: columns, rows: rows, in: size)
                    DashboardTileView(tile: tile, host: host, storage: storage, captionSize: CaptionSize.tile(height: frame.height),
                                      isHidden: hiddenTile == tile.destination, hovering: pointerTile == tile.destination,
                                      onPointer: { lean in pointer(tile.destination, lean) }) {
                        open(tile.destination)
                    }
                    .frame(width: frame.width, height: frame.height)
                    .modifier(placed(tile, index: index, count: tiles.count, frame: frame))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // The gaps between tiles are glass too: dragging there moves the window.
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()).allowsWindowActivationEvents(true) }
        .animation(Theme.layout, value: tiles.map(\.id))
        .animation(Theme.layout, value: tiles.map(\.size))
        .animation(Theme.layout, value: columns)
    }

    /// Everything that moves a tile, the same for its ground and its face so the two stay one: coming in and leaving with the window,
    /// its place, the lift and lean (or tilt) under the pointer, and hiding under the zoom.
    private func placed(_ tile: DashboardTile, index: Int, count: Int, frame: CGRect) -> TilePlacement {
        let moves = pointerTile == tile.destination
        return TilePlacement(shown: appeared && !closing, closing: closing, index: index, count: count, frame: frame,
                             lifted: moves && design.lift && tile.opens,
                             lean: moves && design.tilt && !reduceMotion ? lean : .center,
                             turns: !design.glass, reduceMotion: reduceMotion,
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
        let tiles = host.hasScanned ? Self.tiles(for: host.dashboardHandles) : []
        GeometryReader { proxy in
            let columns = Bento.columns(for: proxy.size.width)
            let placements = Bento.pack(sizes: tiles.map(\.size), columns: columns)
            let rows = Bento.rows(placements)
            let needed = CGFloat(rows) * Self.minimumRowHeight + CGFloat(max(rows - 1, 0)) * Theme.spacing
            let size = CGSize(width: proxy.size.width, height: max(proxy.size.height, needed))
            // The zoom needs each tile's place. It is taken from the layout, not measured on screen: measured frames include the hover
            // lift, the press and the dashboard receding behind an open page, and a card closing onto them landed beside its tile.
            let _ = frames.record(zip(tiles, placements).map { ($0.destination, Bento.frame($1, columns: columns, rows: rows, in: size)) })
            if needed <= proxy.size.height {
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
        Button(action: open) {
            // Not clipped: everything in the tile is drawn inside its shape already, and a clip made every frame mask the whole tile.
            TileContent(destination: tile.destination, tint: tile.tint, host: host, storage: storage, captionSize: captionSize,
                        hovering: hovering, hoveredBlock: hoveredBlock, drawsBackdrop: false)
                .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .allowsHitTesting(tile.opens)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onContinuousHover { phase in
            switch phase {
            case let .active(location) where size.width > 0 && !isHidden && design.trackPointer:
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
        .pointerStyle(tile.opens ? .link : nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tile.opens ? .isButton : [])
    }

    private func resetPointer() {
        if lastStep != nil { lastStep = nil; onPointer(nil) }
        if hoveredBlock != nil { hoveredBlock = nil }
    }

    /// The block of this tile's chart under `location`, if the chart is blocks.
    private func block(at location: CGPoint) -> String? {
        guard case let .module(id) = tile.destination, case let .blocks(segments)? = host.handle(for: id)?.tile?.graphic else { return nil }
        let area = TileFace.chartArea(in: size)
        return BlocksView.segment(at: CGPoint(x: location.x - area.minX, y: location.y - area.minY), in: area.size, segments: segments)?.id
    }
}

/// A tile's ground on the dashboard, in the layer under the faces. A flat tile casts its shadow from this plain rounded shape, not from
/// its whole content (which was recomputed on every frame the tile moved); a glass tile casts none, as it would show inside the glass.
struct TileGround: View {
    let tint: TileTint
    let lifted: Bool
    /// The pointer is over the tile. A glass ground darkens its own tint, inside the glass, so the shade is the glass's own shape.
    var hovering = false
    @Environment(\.design) private var design

    var body: some View {
        if design.glass {
            TileBackdrop(tint: tint, darkened: hovering && design.hoverShade)
        } else {
            TileBackdrop(tint: tint)
                .background {
                    RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                        .fill(design.palette(tint).base)
                        .shadow(color: .black.opacity(lifted ? 0.22 : 0.07), radius: lifted ? 14 : 5, y: lifted ? 8 : 2)
                }
                .animation(design.liftAnimation, value: lifted)
        }
    }
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
    let reduceMotion: Bool
    let liftAnimation: Animation
    let leanAnimation: Animation
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .tilted(lean, active: turns)
            .offset(x: turns ? 0 : (lean.x - 0.5) * 4, y: turns ? 0 : (lean.y - 0.5) * 4)
            .scaleEffect(lifted ? 1.018 : 1)
            .animation(liftAnimation, value: lifted)
            .animation(leanAnimation, value: lean)
            .scaleEffect(shown || reduceMotion ? 1 : 0.86)
            .opacity(shown ? 1 : 0)
            .animation(closing ? Theme.depopulate.delay(Double(count - 1 - index) * Theme.depopulateStagger)
                               : Theme.layout.delay(0.12 + Double(index) * Theme.populateStagger), value: shown)
            .offset(x: frame.minX, y: frame.minY)
            .opacity(hidden ? 0 : 1)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
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

    var body: some View {
        switch destination {
        case let .module(id):
            if let handle = host.handle(for: id) { ModuleTileContent(handle: handle, content: self) }
        case .settings: layout(TileInfo.settings)
        case .storage: layout(TileInfo(storage))
        case .home: EmptyView()
        }
    }

    func layout(_ info: TileInfo) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if showsFace { TileFace(tint: tint, info: info, progress: progress, hovering: hovering, hoveredBlock: hoveredBlock,
                                      drawsBackdrop: drawsBackdrop) } else { Color.clear }
            if showsCaption {
                TileCaption(title: info.title, status: info.status, size: captionSize, loading: info.loading)
                    .padding(captionPadding)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .fill(.black.opacity(configuration.isPressed ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .animation(Theme.press, value: configuration.isPressed)
    }
}
