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
        var graphic: TileGraphic?
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
    var pointer: UnitPoint?
    @Environment(\.design) private var design

    /// Room left under the chart for the caption.
    static let captionBand: CGFloat = 62

    var body: some View {
        let chartOpacity = 1 - ZoomMath.ramp(progress, 0, 0.35)
        ZStack(alignment: .topLeading) {
            TileBackdrop(tint: tint)
            if let graphic = info.graphic {
                GeometryReader { proxy in
                    chart(graphic, in: proxy.size)
                }
                .opacity(chartOpacity)
            }
            if info.loading { Shimmer() }
            // Over the chart too: the chart's glass would otherwise see the shade behind it and adapt to it late.
            if design.glass && design.hoverShade {
                HoverShade(shape: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous), on: pointer != nil, amount: Theme.tileHoverShade)
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
            let area = CGRect(x: 12, y: 12, width: max(size.width - 24, 0), height: max(size.height - 12 - Self.captionBand - 14, 0))
            let hovered = pointer.flatMap { unit -> UsageSegment? in
                let point = CGPoint(x: unit.x * size.width - area.minX, y: unit.y * size.height - area.minY)
                return BlocksView.segment(at: point, in: area.size, segments: segments)
            }
            BlocksView(segments: segments, tint: tint, hovered: hovered?.id)
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
                DotsView(dots: dots, tint: tint, diameter: min(15, (size.width - 28 - 6 * 7) / 7))
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
            StateView(on: on, detail: detail, meter: meter, meterIsActionable: actionable, tint: tint)
                .frame(width: max(min(size.width - 28, 200), 0), alignment: .leading)
                .padding(.leading, 14)
                .padding(.top, 16)
        case let .gauge(value, extra, label, sublabel):
            // Clear of the window's close button, which sits in this tile's top-left corner.
            let side = max(min(size.width * 0.56, size.height - Self.captionBand - 34), 40)
            GaugeView(value: value, extra: extra, label: label, sublabel: sublabel, tint: tint)
                .frame(width: side, height: side)
                .position(x: max(size.width / 2, 52 + side / 2), y: 20 + side / 2)
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
/// come in one after another when the window opens, and glide to their new places when a module is switched on or off.
struct HomeView: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var storage: StorageOverview
    /// Where each tile is, for the zoom into it.
    var frames = TileFrames()
    let open: (Destination) -> Void
    /// The tile that is being replaced by the zoom; it is not drawn so it does not show through.
    var hiddenTile: Destination?
    @State private var appeared = false

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
    /// for a wide tile, else the first.
    nonisolated static func featured(_ modules: [(id: String, reclaimable: UInt64?, wide: Bool)]) -> String? {
        if let most = modules.filter({ ($0.reclaimable ?? 0) > 0 }).max(by: { ($0.reclaimable ?? 0) < ($1.reclaimable ?? 0) }) { return most.id }
        return (modules.first { $0.wide } ?? modules.first)?.id
    }

    var body: some View {
        let tiles = host.hasScanned ? Self.tiles(for: host.dashboardHandles) : []
        GeometryReader { proxy in
            let columns = Bento.columns(for: proxy.size.width)
            let placements = Bento.pack(sizes: tiles.map(\.size), columns: columns)
            let rows = Bento.rows(placements)
            let needed = CGFloat(rows) * Self.minimumRowHeight + CGFloat(max(rows - 1, 0)) * Theme.spacing
            let size = CGSize(width: proxy.size.width, height: max(proxy.size.height, needed))
            ScrollView {
                // The zoom needs each tile's place. It is taken from the layout, not measured on screen: measured frames include the
                // hover lift, the press and the dashboard receding behind an open page, and a card closing onto them landed beside its tile.
                let _ = frames.record(zip(tiles, placements).map { ($0.destination, Bento.frame($1, columns: columns, rows: rows, in: size)) })
                ZStack(alignment: .topLeading) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        let frame = Bento.frame(placements[index], columns: columns, rows: rows, in: size)
                        DashboardTileView(tile: tile, host: host, storage: storage, captionSize: CaptionSize.tile(height: frame.height),
                                          isHidden: hiddenTile == tile.destination) {
                            open(tile.destination)
                        }
                        .frame(width: frame.width, height: frame.height)
                        .scaleEffect(appeared ? 1 : 0.86)
                        .opacity(appeared ? 1 : 0)
                        .animation(Theme.layout.delay(Double(index) * 0.06), value: appeared)
                        .offset(x: frame.minX, y: frame.minY)
                        .opacity(hiddenTile == tile.destination ? 0 : 1)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                // The gaps between tiles are glass too: dragging there moves the window.
                .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()).allowsWindowActivationEvents(true) }
                .animation(Theme.layout, value: tiles.map(\.id))
                .animation(Theme.layout, value: tiles.map(\.size))
                .animation(Theme.layout, value: columns)
            }
            .scrollDisabled(needed <= proxy.size.height)
            .scrollIndicators(.never)
            .scrollEdgeEffectHidden(true, for: .all)
            // A lifted tile may reach into the glass frame; the scroll view must not cut it.
            .scrollClipDisabled()
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in frames.scrollOffset = offset }
        }
        .onChange(of: host.hasScanned, initial: true) { _, scanned in if scanned { appeared = true } }
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
    @State private var pointer: UnitPoint?
    @State private var size = CGSize.zero
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
        let hovering = pointer != nil
        let lifted = hovering && design.lift
        let tilt = reduceMotion || !design.tilt ? UnitPoint.center : (pointer ?? .center)
        let turns = !design.glass
        Button(action: open) {
            TileContent(destination: tile.destination, tint: tile.tint, host: host, storage: storage, captionSize: captionSize, pointer: pointer)
                .clipShape(shape)
                .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .allowsHitTesting(tile.opens)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onContinuousHover { phase in
            switch phase {
            case let .active(location) where size.width > 0 && !isHidden:
                pointer = UnitPoint(x: location.x / size.width, y: location.y / size.height)
            default:
                pointer = nil
            }
        }
        .rotation3DEffect(.degrees(turns ? (tilt.x - 0.5) * 5 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .rotation3DEffect(.degrees(turns ? (0.5 - tilt.y) * 5 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .offset(x: turns ? 0 : (tilt.x - 0.5) * 4, y: turns ? 0 : (tilt.y - 0.5) * 4)
        .scaleEffect(lifted && tile.opens ? 1.018 : 1)
        // Glass is see-through, so a deeper shadow would show inside the tile, offset from its edge.
        .shadow(color: .black.opacity(lifted && !design.glass ? 0.22 : 0.07), radius: lifted && !design.glass ? 14 : 5,
                y: lifted && !design.glass ? 8 : 2)
        .animation(Theme.hover, value: hovering)
        .animation(.interactiveSpring(duration: 0.25), value: pointer)
        .onChange(of: isHidden) { _, hidden in if hidden { pointer = nil } }
        .pointerStyle(tile.opens ? .link : nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tile.opens ? .isButton : [])
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
    var pointer: UnitPoint?
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
            if showsFace { TileFace(tint: tint, info: info, progress: progress, pointer: pointer) } else { Color.clear }
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

private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.955 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(Theme.press, value: configuration.isPressed)
    }
}
