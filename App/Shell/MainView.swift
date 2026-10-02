import MacSpaceSdk
import SwiftUI

public enum Destination: Hashable {
    case home
    case module(String)
    case settings
}

/// The page that is open over the dashboard, and what it grew from.
struct ZoomLayer: Equatable {
    var destination: Destination
    /// The rectangle the page's card grew from and shrinks back into.
    var origin: CGRect
    /// The tile's parts; nil for Settings, which has no tile.
    var tile: TileGeometry?
}

/// The window. Home is a dashboard of module tiles. Opening one makes the tile itself grow: its card becomes the window, its title
/// and summary widget travel to where the page keeps them, and the rest of the page appears below. The toolbar has a Back button and
/// a Settings button. The sidebar layout is still here, switched off by `showsSidebar`.
public struct MainView: View {
    /// Turns the sidebar layout (Home, the modules and Settings as a list on the left) back on.
    static let showsSidebar = false
    static let openAnimation = Animation.easeInOut(duration: 0.7)
    static let revealAnimation = Animation.easeOut(duration: 0.6).delay(0.3)
    static let closeRevealAnimation = Animation.easeIn(duration: 0.2)
    static let closeAnimation = Animation.easeInOut(duration: 0.6).delay(0.1)

    @ObservedObject var host: ModuleHost
    @ObservedObject var updates: UpdateController

    // Sidebar layout.
    @State private var selection: Destination = .home

    // Zoom layout. `progress` is 0 on the dashboard and 1 with a page fully open; `reveal` is the later animation that brings in the
    // rest of the page. The layer exists while a page is open or moving.
    @State private var layer: ZoomLayer?
    @State private var progress: CGFloat = 0
    @State private var reveal: CGFloat = 0
    @State private var container: CGSize = .zero
    @State private var isMoving = false
    @State private var tiles = TileFrames()
    @State private var pageFrames = PageFrames()
    /// What the toolbar shows. Kept apart from `layer` and changed without animation, so the toolbar never follows the page's animation.
    @State private var chrome: Destination = .home

    public init(host: ModuleHost, updates: UpdateController) {
        self.host = host
        self.updates = updates
    }

    public var body: some View {
        Group {
            if Self.showsSidebar { sidebarLayout } else { zoomLayout }
        }
        .frame(minWidth: 860, minHeight: 560)
        .task { await host.start() }
    }

    // MARK: Zoom layout

    private var openTile: String? {
        if case let .module(id)? = layer?.destination { return id }
        return nil
    }

    private var zoomLayout: some View {
        ZStack(alignment: .topLeading) {
            HomeView(host: host, tiles: tiles, open: { present(.module($0)) }, hiddenTile: openTile)
                .modifier(ZoomFade(progress: progress))
                .allowsHitTesting(layer == nil)
            if let layer, container.width > 0 {
                stage(.card, layer)
                detail(for: layer.destination)
                    .id(layer.destination)
                stage(.travelers, layer)
            }
        }
        .coordinateSpace(name: ZoomSpace.name)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { container = $0 }
        .navigationTitle(title)
        // The toolbar background re-samples whatever is behind it; as pages open and close it flashed darker for ~0.1 s. Fixed instead.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            if chrome != .home {
                ToolbarItem(placement: .navigation) {
                    Button { close() } label: { Label("Back", systemImage: "chevron.left") }
                        .keyboardShortcut(.cancelAction)
                        .help("Back to Home")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { present(.settings) } label: { Label("Settings", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(chrome == .settings)
                    .help("Settings")
            }
        }
    }

    private func stage(_ part: ZoomStageLayer, _ layer: ZoomLayer) -> some View {
        ZoomStage(layer: part, progress: progress, origin: layer.origin, tile: layer.tile, container: container,
                  pageTitle: pageFrames.title, pageHero: pageFrames.hero,
                  header: stageHeader(layer.destination), hero: stageHero(layer.destination))
    }

    private var title: String {
        switch chrome {
        case .home: return "MacSpace"
        case .settings: return "Settings"
        case let .module(id): return host.handle(for: id)?.manifest.name ?? "MacSpace"
        }
    }

    /// Where Settings grows from: the toolbar's Settings button, at the top right of the content.
    private var settingsFrame: CGRect { CGRect(x: max(container.width - 60, 0), y: 0, width: 40, height: 30) }

    /// The tile's real title and summary widget, drawn by the zoom while they travel.
    @ViewBuilder
    private func stageHeader(_ destination: Destination) -> some View {
        if case let .module(id) = destination, let handle = host.handle(for: id) { ModuleTileTitle(manifest: handle.manifest) }
    }

    @ViewBuilder
    private func stageHero(_ destination: Destination) -> some View {
        if case let .module(id) = destination, let summary = host.handle(for: id)?.summary { WidgetView(widget: summary) { _, _ in } }
    }

    private func setChrome(_ destination: Destination) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { chrome = destination }
    }

    /// Opens a page. From the dashboard the tile (or the Settings button) grows into it; from another page it just swaps.
    private func present(_ destination: Destination) {
        guard !isMoving else { return }
        let tile: TileGeometry?
        if case let .module(id) = destination { tile = tiles.tiles[id].flatMap { $0.isComplete ? $0 : nil } } else { tile = nil }
        let origin = tile?.card ?? settingsFrame
        setChrome(destination)
        if layer != nil {
            layer = ZoomLayer(destination: destination, origin: origin, tile: tile)
            return
        }
        isMoving = true
        progress = 0
        reveal = 0
        pageFrames.title = .zero
        pageFrames.hero = .zero
        layer = ZoomLayer(destination: destination, origin: origin, tile: tile)
        Task { @MainActor in
            // The page is laid out hidden first, so the zoom knows where to land.
            for _ in 0..<25 where tile != nil && pageFrames.hero == .zero { try? await Task.sleep(for: .milliseconds(16)) }
            withAnimation(Self.openAnimation, completionCriteria: .logicallyComplete) { progress = 1 } completion: { isMoving = false }
            withAnimation(Self.revealAnimation) { reveal = 1 }
        }
    }

    /// The page goes first, then the tile's parts travel back into the tile.
    private func close() {
        guard layer != nil, !isMoving else { return }
        isMoving = true
        setChrome(.home)
        withAnimation(Self.closeRevealAnimation) { reveal = 0 }
        withAnimation(Self.closeAnimation, completionCriteria: .logicallyComplete) { progress = 0 } completion: {
            layer = nil
            isMoving = false
        }
    }

    // MARK: Sidebar layout

    private var sidebarLayout: some View {
        NavigationSplitView {
            List(selection: Binding<Destination?>(get: { selection }, set: { selection = $0 ?? .home })) {
                Label("Home", systemImage: "square.grid.2x2").tag(Destination.home)
                Section("Modules") {
                    ForEach(host.activeHandles) { handle in
                        Label(handle.manifest.name, systemImage: handle.manifest.symbol).tag(Destination.module(handle.id))
                    }
                }
                Section {
                    Label("Settings", systemImage: "gearshape").tag(Destination.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch selection {
            case .home: HomeView(host: host, open: { selection = .module($0) })
            default: detail(for: selection)
            }
        }
    }

    // MARK: Pages

    @ViewBuilder
    private func detail(for destination: Destination) -> some View {
        let zooming = !Self.showsSidebar
        switch destination {
        case .home: EmptyView()
        case let .module(id):
            if let handle = host.handle(for: id) {
                ScreenView(handle: handle, zoom: zooming ? ScreenZoom(progress: progress, reveal: reveal, frames: pageFrames) : nil)
            } else { ContentUnavailableView("Module not found", systemImage: "questionmark.folder") }
        case .settings:
            SettingsView(host: host, updates: updates)
                .modifier(ZoomReveal(part: .stagger(0), progress: zooming ? progress : 1, reveal: zooming ? reveal : 1))
        }
    }
}
