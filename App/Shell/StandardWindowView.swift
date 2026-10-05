import AppKit
import MacSpaceSdk
import SwiftUI

/// The window ids, and which one MacSpace uses: the glass window (`MainView`) or a standard macOS window with a sidebar
/// (`StandardWindowView`), chosen with the Standard Window switch in Settings > Design.
public enum MacSpaceWindow {
    public static let glass = "main"
    public static let standard = "standard"

    @MainActor public static var current: String { DesignSettings.shared.standardWindow ? standard : glass }
}

/// Keeps the window that is open the one the Standard Window switch asks for: when it changes, or when the other window was the
/// one opened (at launch, or from the menu bar), the right one opens and this one closes.
struct WindowKindSwitch: ViewModifier {
    let id: String
    @ObservedObject private var settings = DesignSettings.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content
            .onAppear(perform: follow)
            .onChange(of: settings.standardWindow) { _, _ in follow() }
    }

    private func follow() {
        let wanted = MacSpaceWindow.current
        guard wanted != id else { return }
        // The other window first: closing the last window could quit the app.
        openWindow(id: wanted)
        dismissWindow(id: id)
    }
}

/// The dashboard and the pages in a standard macOS window: a sidebar with the overview and the modules, Settings apart at its foot,
/// and the selected one beside it. The sidebar is drawn by MacSpace, not by a split view. In a window the user placed freely, hiding
/// the sidebar closes the window up by its width and showing it opens the window out again, the page staying where it is; in full
/// screen or tiled to a part of the screen, the window keeps its size and the page takes the room. The window's own buttons give way to the glass window's: ✕ to close, and the sidebar's button.
public struct StandardWindowView: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var updates: UpdateController
    @StateObject private var storage = StorageOverview()
    @ObservedObject private var designSettings = DesignSettings.shared
    @ObservedObject private var remote = DebugRemote.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selection: Destination = .home
    @State private var sidebarShown = true
    /// Which way the last change of page went in the sidebar's order: down slides the new page up from below, up from above.
    @State private var forward = true
    @State private var window = WindowReference()

    static let sidebarWidth: CGFloat = 210
    /// The band at the top for the corner buttons, the title and Refresh.
    static let headerHeight: CGFloat = 56
    static let controlInset: CGFloat = 12
    /// How far the background glass reaches past the window's edges.
    static let glassBleed: CGFloat = 60

    public init(host: ModuleHost, updates: UpdateController) {
        self.host = host
        self.updates = updates
    }

    private var design: Design { designSettings.design }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if sidebarShown {
                    sidebar
                        .frame(width: Self.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                detailColumn
            }
            controls.padding(Self.controlInset)
        }
        .animation(Theme.push, value: sidebarShown)
        .background { windowBackground.ignoresSafeArea() }
        .ignoresSafeArea()
        .environment(\.design, design)
        // The window takes the palette's appearance (dark grounds, dark chrome), so its sidebar matches the pages.
        .preferredColorScheme(design.colorScheme)
        .background(StandardWindowConfigurator(glass: designSettings.standardGlassBackground, reference: window))
        .frame(minWidth: Theme.minimumSize.width, minHeight: Theme.minimumSize.height)
        .task { await host.start() }
        .task { await storage.refresh() }
        .modifier(WindowKindSwitch(id: MacSpaceWindow.standard))
        .onChange(of: remote.command?.id) { _, _ in
            guard let text = remote.command?.text else { return }
            if text == "open:settings" { open(.settings) }
            else if text == "back" { select(.home) }
            else if text == "sidebar" { toggleSidebar() }
            else if text.hasPrefix("open:"), text != "open:colorLab" { open(.module(String(text.dropFirst(5)))) }
        }
    }

    // MARK: Chrome

    /// ✕ closes the window, as on the glass window; beside it, the sidebar's button.
    private var controls: some View {
        HStack(spacing: 8) {
            GlassCircleButton(symbol: "xmark", help: "Close") { dismissWindow(id: MacSpaceWindow.standard) }
            GlassCircleButton(symbol: "sidebar.left", help: sidebarShown ? "Hide the sidebar" : "Show the sidebar") { toggleSidebar() }
        }
    }

    /// The window's solid color, or Liquid Glass over the desktop (Design menu > Standard Window Glass Background).
    @ViewBuilder
    private var windowBackground: some View {
        if designSettings.standardGlassBackground {
            ZStack {
                WindowBlur(cornerRadius: 0, isLight: design.isLight)
                // Larger than the window, so the window cuts off the glass's lit rim: the glass itself shows, its edge does not shine
                // along the window's border.
                GlassPane(corners: .radius(0), style: .clear)
                    .padding(-Self.glassBleed)
            }
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                row("Overview", symbol: "square.grid.2x2", .home)
                Section("Modules") {
                    ForEach(host.dashboardHandles) { handle in
                        row(handle.manifest.name, symbol: handle.manifest.symbol, .module(handle.id))
                    }
                }
            }
            // Settings apart from the modules, at the foot of the sidebar.
            List(selection: selectionBinding) {
                row("Settings", symbol: "gearshape", .settings)
            }
            .frame(height: 44)
            .scrollDisabled(true)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .padding(.top, Self.headerHeight)
        .background {
            if !designSettings.standardGlassBackground { Rectangle().fill(.thinMaterial) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(.primary.opacity(0.08)).frame(width: 1) }
    }

    @ViewBuilder
    private func row(_ title: String, symbol: String, _ destination: Destination) -> some View {
        Group {
            if designSettings.standardSidebarIcons { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .tag(destination)
    }

    /// The sidebar's selection, changed with the page's slide in the direction of the move.
    private var selectionBinding: Binding<Destination?> {
        Binding(get: { selection }, set: { if let new = $0 { select(new) } })
    }

    // MARK: Detail

    /// The page's band at the top (title and Refresh) and the page, on one ground: with the title bar off the band has no color of
    /// its own, so there is no bar.
    private var detailColumn: some View {
        VStack(spacing: 0) {
            if needsHeader { header.frame(height: Self.headerHeight) }
            ZStack {
                page(selection)
                    .id(selection)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .bottom : .top).combined(with: .opacity),
                                            removal: .move(edge: forward ? .top : .bottom).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        // Without the band, Refresh floats in the page's top-right corner, as on the glass window.
        .overlay(alignment: .topTrailing) {
            if !needsHeader { refresh.padding(Self.controlInset) }
        }
        .background { ground(selection).ignoresSafeArea() }
    }

    /// The band only with the title bar. Without it there is no band at all: the corner buttons and Refresh float over the page, as
    /// on the glass window (over the disk tile on the overview), and pages keep the glass window's room for them at the top.
    private var needsHeader: Bool { designSettings.standardTitleBar }

    /// Where a page's content starts: right under the band, or clear of the floating buttons without it.
    private var pageTop: CGFloat { needsHeader ? 8 : PageInsets.scrollTop }

    private var header: some View {
        HStack(spacing: 12) {
            if designSettings.standardTitleBar {
                Text(title(selection))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(design.ink)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            refresh
        }
        // Clear of the corner buttons while they are over the page.
        .padding(.leading, sidebarShown ? 20 : Self.controlInset + 2 * GlassCircleButton.diameter + 8 + 16)
        .padding(.trailing, Self.controlInset)
        .background {
            if designSettings.standardTitleBar {
                // A tint of the page's own ground, not the system's bar material, which stops short of the window's title bar area.
                Rectangle().fill(.primary.opacity(0.05))
                    .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
                    .ignoresSafeArea()
            }
        }
        .animation(Theme.push, value: sidebarShown)
    }

    @ViewBuilder
    private var refresh: some View {
        if case let .module(id) = selection, let handle = host.handle(for: id) { RefreshControl(handle: handle) }
    }

    @ViewBuilder
    private func page(_ destination: Destination) -> some View {
        switch destination {
        case .home, .storage:
            HomeView(host: host, storage: storage, open: open, showsSettingsTile: false)
                .padding(Theme.frame)
                .coordinateSpace(name: ZoomSpace.name)
        case let .module(id):
            if let handle = host.handle(for: id) {
                ScreenView(handle: handle, tint: tint(of: destination))
                    .environment(\.pageScrollTop, pageTop)
            }
        case .settings:
            SettingsPages(host: host, updates: updates)
                .environment(\.pageScrollTop, pageTop)
        }
    }

    /// A page's ground is its tile's color, as in the glass window, where the page is drawn on the tile it grew from. The overview
    /// lies on the window itself.
    @ViewBuilder
    private func ground(_ destination: Destination) -> some View {
        switch destination {
        case .home, .storage: Color.clear
        default: TileBackdrop(tint: tint(of: destination), cornerRadius: 0)
        }
    }

    private func tint(of destination: Destination) -> TileTint {
        if destination == .settings { return .slate }
        return HomeView.tiles(for: host.dashboardHandles).first { $0.destination == destination }?.tint ?? .slate
    }

    private func title(_ destination: Destination) -> String {
        switch destination {
        case .home, .storage: return "MacSpace"
        case let .module(id): return host.handle(for: id)?.manifest.name ?? ""
        case .settings: return host.settingsPage == .cleanupHistory ? "Recent cleanups" : "Settings"
        }
    }

    // MARK: Navigation

    /// The sidebar's order, for the direction of the slide.
    private var order: [Destination] { [.home] + host.dashboardHandles.map { .module($0.id) } + [.settings] }

    /// Hides or shows the sidebar; a freely placed window closes up or opens out by the sidebar's width with it.
    private func toggleSidebar() {
        let showing = !sidebarShown
        if let window = window.window, Self.isFreelyPlaced(window) {
            var frame = window.frame
            let change = Self.sidebarWidth
            if showing {
                frame.origin.x -= change
                frame.size.width += change
            } else {
                let narrower = max(frame.width - change, Theme.minimumSize.width)
                frame.origin.x += frame.width - narrower
                frame.size.width = narrower
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.allowsImplicitAnimation = true
                window.animator().setFrame(frame, display: true)
            }
        }
        withAnimation(Theme.push) { sidebarShown = showing }
    }

    /// Not in full screen, and not tiled to a half, a quarter or the whole of the screen (macOS's tiling leaves a margin of a few
    /// points, hence the tolerance).
    static func isFreelyPlaced(_ window: NSWindow) -> Bool {
        if window.styleMask.contains(.fullScreen) { return false }
        guard let screen = window.screen?.visibleFrame else { return true }
        let frame = window.frame, tolerance: CGFloat = 16
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
        let widths = [screen.width, screen.width / 2]
        let heights = [screen.height, screen.height / 2]
        let tiledWidth = widths.contains { near(frame.width, $0) || near(frame.width, $0 - tolerance) }
        let tiledHeight = heights.contains { near(frame.height, $0) || near(frame.height, $0 - tolerance) }
        let onEdge = (near(frame.minX, screen.minX) || near(frame.maxX, screen.maxX)) && (near(frame.minY, screen.minY) || near(frame.maxY, screen.maxY))
        return !(tiledWidth && tiledHeight && onEdge)
    }

    private func select(_ destination: Destination) {
        guard destination != selection else { return }
        let from = order.firstIndex(of: selection) ?? 0
        let to = order.firstIndex(of: destination) ?? 0
        forward = to >= from
        withAnimation(Theme.push) { selection = destination }
    }

    /// A tile clicked on the overview selects its page.
    private func open(_ destination: Destination) {
        guard destination != .home, destination != .storage else { return }
        if destination == .settings { host.settingsPage = nil }
        select(destination)
    }
}

/// Refresh for the open module in the standard window's band, spinning while the module reads the Mac.
private struct RefreshControl: View {
    @ObservedObject var handle: ModuleHandle

    var body: some View {
        GlassCircleButton(symbol: "arrow.clockwise", help: "Refresh", busy: handle.isBusy) {
            Task { await handle.refresh(reload: true) }
        }
    }
}

/// The standard window's frame: its own buttons hidden (MacSpace draws ✕ and the sidebar's button), no title, movable by its
/// background, and clear behind the content when the background is glass.
/// The standard window, for resizing it with the sidebar.
final class WindowReference {
    weak var window: NSWindow?
}

private struct StandardWindowConfigurator: NSViewRepresentable {
    let glass: Bool
    let reference: WindowReference

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let glass = self.glass, reference = self.reference
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            reference.window = window
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = true }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isOpaque = !glass
            window.backgroundColor = glass ? .clear : .windowBackgroundColor
        }
    }
}
