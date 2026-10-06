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
        // The other window first: closing the last window could quit the app. This one closes a moment later, once it is fully on
        // screen: closed from its first appearance, it stayed as an empty frame with its shadow window beside it.
        openWindow(id: wanted)
        let id = self.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            dismissWindow(id: id)
            for window in NSApp.windows where window.identifier?.rawValue.hasPrefix(id) == true && window.isVisible {
                for child in window.childWindows ?? [] { child.orderOut(nil) }
                window.close()
            }
        }
    }
}

/// The dashboard and the pages in a standard macOS window: a sidebar with the overview and the modules, Settings apart at its foot,
/// and beside it the glass window's own canvas (`MainView`, embedded): tiles zoom open into their pages, Back zooms them closed, and
/// pages slide over one another, as on the glass window; the sidebar drives the same motions.
///
/// With the sidebar, the window's own close, minimize and zoom buttons and the sidebar's button stand where macOS puts them. Hiding
/// the sidebar takes them away and the canvas shows the glass window's ✕ with the sidebar's button beside it. In a window the user
/// placed freely, hiding the sidebar closes the window up by its width (the page keeping its width, the sidebar sliding under the
/// window's moving edge) and showing it opens it out again; in full screen or tiled, the window keeps its size.
public struct StandardWindowView: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var updates: UpdateController
    @ObservedObject private var designSettings = DesignSettings.shared
    @ObservedObject private var remote = DebugRemote.shared
    @ObservedObject private var router = AppRouter.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @StateObject private var navigator = CanvasNavigator()
    @StateObject private var window = WindowReference()
    @State private var sidebarShown = true
    /// The canvas's width held while the window resizes with the sidebar; nil lets it follow the window.
    @State private var pinnedDetailWidth: CGFloat?
    /// The sidebar slides over the canvas (full screen, tiled) rather than with the window's edge.
    @State private var sidebarSlides = false

    static let sidebarWidth: CGFloat = 210
    /// The band at the top with the title (Design menu > Standard Window Title Bar).
    static let headerHeight: CGFloat = 52
    /// How far the background glass reaches past the window's edges.
    static let glassBleed: CGFloat = 60

    public init(host: ModuleHost, updates: UpdateController) {
        self.host = host
        self.updates = updates
    }

    private var design: Design { designSettings.design }

    public var body: some View {
        // The columns lie in an overlay, aligned to the trailing edge, so they never set the window's size: while a freely placed
        // window closes up or opens out, the canvas keeps its width and nothing is laid out again on the way.
        Color.clear.overlay(alignment: .trailing) {
            HStack(spacing: 0) {
                if sidebarShown {
                    sidebar
                        .frame(width: Self.sidebarWidth)
                        .transition(sidebarSlides ? .move(edge: .leading) : .identity)
                }
                detailColumn
                    .frame(width: pinnedDetailWidth)
            }
        }
        .animation(sidebarSlides ? .smooth(duration: 0.35) : nil, value: sidebarShown)
        .background { windowBackground.ignoresSafeArea() }
        .ignoresSafeArea()
        .environment(\.design, design)
        // The window takes the palette's appearance (dark grounds, dark chrome), so its sidebar matches the pages.
        .preferredColorScheme(design.colorScheme)
        .background(StandardWindowConfigurator(glass: designSettings.standardGlassBackground, background: NSColor(design.systemWindowColor), reference: window))
        .frame(minWidth: Theme.minimumSize.width, minHeight: Theme.minimumSize.height)
        .modifier(WindowKindSwitch(id: MacSpaceWindow.standard))
        .onAppear {
            navigator.closeWindow = { dismissWindow(id: MacSpaceWindow.standard) }
            navigator.toggleSidebar = toggleSidebar
            navigator.showsTitle = designSettings.standardTitleBar
        }
        .onChange(of: designSettings.standardTitleBar) { _, shown in navigator.showsTitle = shown }
        .onChange(of: remote.command?.id) { _, _ in
            if remote.command?.text == "sidebar" { toggleSidebar() }
        }
        .onAppear { AppRouter.shared.openWindow = { [openWindow] id in openWindow(id: id) } }
        // A page asked for from the menu bar.
        .onChange(of: router.request?.id, initial: true) { _, _ in
            guard let destination = router.take() else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                navigator.go(destination)
            }
        }
    }

    /// The window's solid color, or Liquid Glass over the desktop (Design menu > Standard Window Glass Background).
    @ViewBuilder
    private var windowBackground: some View {
        if designSettings.standardGlassBackground {
            ZStack {
                WindowBlur(cornerRadius: 0, isLight: design.backgroundIsLight)
                // Larger than the window, so the window cuts off the glass's lit rim: the glass itself shows, its edge does not shine
                // along the window's border.
                GlassPane(corners: .radius(0), style: .clear)
                    .padding(-Self.glassBleed)
            }
        } else {
            design.systemWindowColor
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
        .padding(.top, window.buttonsCenterY + 26)
        // The sidebar's button where macOS puts it: at the sidebar's top right, level with the window's buttons. It slides away with
        // the sidebar.
        .overlay(alignment: .topTrailing) {
            GlassCircleButton(symbol: "sidebar.left", help: "Hide the sidebar") { toggleSidebar() }
                .padding(.top, max(window.buttonsCenterY - GlassCircleButton.diameter / 2, 4))
                .padding(.trailing, 10)
        }
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

    /// The sidebar's selection is what the canvas shows; choosing asks the canvas to go there, with its own motion.
    private var selectionBinding: Binding<Destination?> {
        Binding(get: { navigator.shown == .storage ? .home : navigator.shown },
                set: { if let new = $0, new != navigator.shown { navigator.go(new) } })
    }

    // MARK: Canvas

    private var detailColumn: some View {
        VStack(spacing: 0) {
            if designSettings.standardTitleBar {
                Text(title(navigator.shown))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(design.ink)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, sidebarShown ? 20 : 112)
                    .frame(height: Self.headerHeight)
                    .background {
                        Rectangle().fill(.primary.opacity(0.05))
                            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
                            .ignoresSafeArea()
                    }
                    .animation(.smooth(duration: 0.3), value: navigator.shown)
            }
            MainView(host: host, updates: updates, navigator: navigator, embedded: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    private func title(_ destination: Destination) -> String {
        switch destination {
        case .home, .storage: return "MacSpace"
        case let .module(id): return host.handle(for: id)?.manifest.name ?? ""
        case .settings: return "Settings"
        }
    }

    // MARK: Sidebar motion

    /// Hides or shows the sidebar, with the window's own buttons. A freely placed window closes up or opens out by the sidebar's
    /// width: the canvas is held at its width while AppKit moves the window's left edge, so the sidebar slides under the edge or out
    /// from it and nothing reflows. In full screen or tiled, the window keeps its size and the sidebar slides over.
    private func toggleSidebar() {
        let showing = !sidebarShown
        window.setButtonsVisible(showing)
        withAnimation(.smooth(duration: 0.3)) { navigator.sidebarShown = showing }
        guard let nsWindow = window.window, Self.isFreelyPlaced(nsWindow) else {
            sidebarSlides = true
            sidebarShown = showing
            return
        }
        sidebarSlides = false
        let width = Self.sidebarWidth
        var frame = nsWindow.frame
        pinnedDetailWidth = frame.width - (sidebarShown ? width : 0)
        if showing {
            frame.origin.x -= width
            frame.size.width += width
            sidebarShown = true
        } else {
            let narrower = max(frame.width - width, Theme.minimumSize.width)
            frame.origin.x += frame.width - narrower
            frame.size.width = narrower
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            nsWindow.animator().setFrame(frame, display: true)
        }, completionHandler: {
            Task { @MainActor in
                if !showing { sidebarShown = false }
                pinnedDetailWidth = nil
            }
        })
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

}

/// The standard window, for resizing it with the sidebar, and where its close, minimize and zoom buttons are (in the content's
/// coordinates, from the top left), for the sidebar's button beside them.
@MainActor
final class WindowReference: ObservableObject {
    weak var window: NSWindow?
    @Published var buttonsMaxX: CGFloat = 78
    @Published var buttonsCenterY: CGFloat = 26

    /// Fades the window's close, minimize and zoom buttons out (the sidebar hidden) or back in.
    func setButtonsVisible(_ visible: Bool) {
        guard let window else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        if visible { buttons.forEach { $0.isHidden = false } }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            buttons.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
        }, completionHandler: {
            Task { @MainActor in if !visible { buttons.forEach { $0.isHidden = true } } }
        })
    }
}

/// The standard window's frame: its own buttons kept, no title, movable by its background, and clear behind the content when the
/// background is glass.

private struct StandardWindowConfigurator: NSViewRepresentable {
    let glass: Bool
    let background: NSColor
    let reference: WindowReference

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let glass = self.glass, background = self.background, reference = self.reference
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            reference.window = window
            // An empty unified toolbar gives the window's buttons the place macOS gives them in a window with a toolbar.
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: "MacSpaceStandardWindow")
                toolbar.showsBaselineSeparator = false
                window.toolbar = toolbar
                window.toolbarStyle = .unified
            }
            if let zoom = window.standardWindowButton(.zoomButton), let superview = zoom.superview, let content = window.contentView {
                let rect = content.convert(superview.convert(zoom.frame, to: nil), from: nil)
                let maxX = rect.maxX
                let centerY = content.isFlipped ? rect.midY : content.bounds.height - rect.midY
                if reference.buttonsMaxX != maxX { reference.buttonsMaxX = maxX }
                if reference.buttonsCenterY != centerY { reference.buttonsCenterY = centerY }
            }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isOpaque = !glass
            window.backgroundColor = glass ? .clear : background
        }
    }
}
