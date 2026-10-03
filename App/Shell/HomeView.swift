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
            TileBackdrop(tint: tint)
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
            // Over the chart too: the chart's glass would otherwise see the shade behind it and adapt to it late.
            if design.glass && design.hoverShade {
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

    /// The tiles at their places in a grid of `size`.
    private func grid(_ tiles: [DashboardTile], placements: [Bento.Placement], columns: Int, rows: Int, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if !dormant {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                    let frame = Bento.frame(placements[index], columns: columns, rows: rows, in: size)
                    let shown = appeared && !closing
                    DashboardTileView(tile: tile, host: host, storage: storage, captionSize: CaptionSize.tile(height: frame.height),
                                      isHidden: hiddenTile == tile.destination) {
                        open(tile.destination)
                    }
                    .frame(width: frame.width, height: frame.height)
                    .scaleEffect(shown || reduceMotion ? 1 : 0.86)
                    .opacity(shown ? 1 : 0)
                    .animation(closing ? Theme.depopulate.delay(Double(tiles.count - 1 - index) * Theme.depopulateStagger)
                                       : Theme.layout.delay(0.12 + Double(index) * Theme.populateStagger), value: shown)
                    .offset(x: frame.minX, y: frame.minY)
                    .opacity(hiddenTile == tile.destination ? 0 : 1)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
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

/// A tile on the dashboard. It lifts and tilts toward the pointer and sinks when pressed; its chart answers the pointer too. A glass
/// tile tilts without turning in 3D: under a 3D rotation, glass redraws what it shows late, and part of the tile stayed dark after the
/// pointer left. It leans toward the pointer instead.
struct DashboardTileView: View {
    let tile: DashboardTile
    @ObservedObject var host: ModuleHost
    @ObservedObject var storage: StorageOverview
    let captionSize: CGFloat
    /// The tile is under an open page: it ignores the pointer, so it comes back flat when the page closes onto it.
    var isHidden = false
    let open: () -> Void
    /// The pointer is over the tile; where it is, in coarse steps, for the lean and tilt; the block of the chart it is on. Each changes
    /// rarely while the mouse moves, and only `hovering` and `hoveredBlock` reach the tile's content: a pointer position passed down
    /// redrew the whole tile (chart, caption, layout) on every step.
    @State private var hovering = false
    @State private var lean = UnitPoint.center
    @State private var hoveredBlock: String?
    @State private var size = CGSize.zero
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
        let lifted = hovering && design.lift
        let tilt = reduceMotion || !design.tilt ? UnitPoint.center : lean
        let turns = !design.glass
        Button(action: open) {
            // Not clipped: everything in the tile is drawn inside its shape already, and a clip made every frame mask the whole tile.
            TileContent(destination: tile.destination, tint: tile.tint, host: host, storage: storage, captionSize: captionSize,
                        hovering: hovering, hoveredBlock: hoveredBlock)
                .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .allowsHitTesting(tile.opens)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onContinuousHover { phase in
            switch phase {
            case let .active(location) where size.width > 0 && !isHidden && design.trackPointer:
                if !hovering { hovering = true }
                let step = 10.0
                let next = UnitPoint(x: (location.x / size.width * step).rounded() / step, y: (location.y / size.height * step).rounded() / step)
                if next != lean { lean = next }
                let block = block(at: location)
                if block != hoveredBlock { hoveredBlock = block }
            default:
                resetPointer()
            }
        }
        .tilted(tilt, active: turns)
        // Flat tiles only: a glass tile is see-through, so a shadow would show inside it, offset from its edge. The shadow is cast by a
        // plain rounded rectangle behind the tile, not by the tile itself: a shadow of the whole tile was recomputed from all of its
        // content on every frame it moved.
        .background {
            if !design.glass {
                shape.fill(design.palette(tile.tint).base)
                    .shadow(color: .black.opacity(lifted ? 0.22 : 0.07), radius: lifted ? 14 : 5, y: lifted ? 8 : 2)
            }
        }
        .offset(x: turns ? 0 : (tilt.x - 0.5) * 4, y: turns ? 0 : (tilt.y - 0.5) * 4)
        .scaleEffect(lifted && tile.opens ? 1.018 : 1)
        .animation(Theme.hover, value: hovering)
        .animation(.interactiveSpring(duration: 0.25), value: lean)
        .onChange(of: isHidden) { _, hidden in if hidden { resetPointer() } }
        .pointerStyle(tile.opens ? .link : nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tile.opens ? .isButton : [])
    }

    private func resetPointer() {
        if hovering { hovering = false }
        if lean != .center { lean = .center }
        if hoveredBlock != nil { hoveredBlock = nil }
    }

    /// The block of this tile's chart under `location`, if the chart is blocks.
    private func block(at location: CGPoint) -> String? {
        guard case let .module(id) = tile.destination, case let .blocks(segments)? = host.handle(for: id)?.tile?.graphic else { return nil }
        let area = TileFace.chartArea(in: size)
        return BlocksView.segment(at: CGPoint(x: location.x - area.minX, y: location.y - area.minY), in: area.size, segments: segments)?.id
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
            if showsFace { TileFace(tint: tint, info: info, progress: progress, hovering: hovering, hoveredBlock: hoveredBlock) } else { Color.clear }
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

/// The tile sinks and darkens while pressed. The darkening is a shade laid over the tile, not a brightness filter: a filter stays on
/// the tile even at 0 and makes every frame draw the whole tile, glass and all, through it.
private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .fill(.black.opacity(configuration.isPressed ? 0.06 : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed ? 0.955 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}
