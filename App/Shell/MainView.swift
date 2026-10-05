import MacSpaceSdk
import SwiftUI

public enum Destination: Hashable {
    case home
    case storage
    case module(String)
    case settings
}

/// The page that is open over the dashboard, and the tile it grew from.
struct ZoomLayer: Equatable {
    var destination: Destination
    var origin: CGRect
    var tint: TileTint
}

/// The window: a pane of glass holding a bento grid of tiles. Opening a tile makes it grow until it fills the glass, its caption
/// staying in the corner, while the other tiles recede; then the page comes in on it. Back reverses all of it and can interrupt it.
/// The glass circle in the top-left corner closes the window on the dashboard and goes back from a page.
/// The edge macOS draws around its windows: a dark hairline outside that separates the window from what is behind it, and a light
/// one just inside, brighter at the top, as if lit from above.
private struct WindowBorder: View {
    let cornerRadius: CGFloat
    let light: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.strokeBorder(Color.black.opacity(light ? 0.22 : 0.55), lineWidth: 1)
            shape.inset(by: 1)
                .strokeBorder(LinearGradient(colors: [.white.opacity(light ? 0.5 : 0.24), .white.opacity(light ? 0.2 : 0.08)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Refresh for the open module, spinning while the module reads the Mac.
private struct RefreshButton: View {
    @ObservedObject var handle: ModuleHandle

    var body: some View {
        GlassCircleButton(symbol: "arrow.clockwise", help: "Refresh", busy: handle.isBusy) {
            Task { await handle.refresh(reload: true) }
        }
    }
}

public struct MainView: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var updates: UpdateController
    @StateObject private var storage = StorageOverview()
    @ObservedObject private var remote = DebugRemote.shared
    @ObservedObject private var designSettings = DesignSettings.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The glass is in: it grows in when the window opens and shrinks away before it closes.
    @State private var windowShown = false
    /// The window is closing: the tiles leave, then the glass, then the window goes.
    @State private var windowClosing = false

    /// `progress` is 0 on the dashboard and 1 with a page fully open; `reveal` brings in the page's content after the card has grown.
    /// The layer exists while a page is open or moving.
    @State private var layer: ZoomLayer?
    @State private var progress: CGFloat = 0
    @State private var reveal: CGFloat = 0
    @State private var container: CGSize = .zero
    @State private var isOpen = false
    /// Bumped by every open and close, so a movement that was interrupted does not finish the one that replaced it.
    @State private var generation = 0
    @State private var frames = TileFrames()
    /// A page has finished opening and covers the dashboard, which then stops drawing its tiles, and the window's glass, which the
    /// page's own glass replaces (two window-sized layers of glass, one over the other, were blended on every frame the page scrolled).
    @State private var pageSettled = false
    /// The page Settings was opened over with Command-comma: Back returns to it instead of to the dashboard.
    @State private var returnTo: ZoomLayer?
    /// Which way the last swap of one page for another went: forward slides the new page in from the right, back from the left.
    @State private var swapForward = true

    public init(host: ModuleHost, updates: UpdateController) {
        self.host = host
        self.updates = updates
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            GlassBackdrop(showsGlass: !pageSettled, glassFade: layer == nil ? 0 : progress)
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
            // The size comes from a GeometryReader, which takes whatever the window gives it. Measured from the content instead, the
            // open page (sized to the last measurement) held the content at its old size, and the window could grow but not shrink.
            GeometryReader { proxy in
                content(proxy.size)
            }
            .coordinateSpace(name: ZoomSpace.name)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { container = $0 }
            .padding(Theme.frame)
            cornerControls
                .padding(Theme.frame + GlassCircleButton.margin)
        }
        // Nothing draws outside the glass: a lifted tile's shadow spilling past it left a stray shadow and edge, which macOS then
        // copied into the window's own shadow.
        .clipShape(designSettings.clipWindow ? AnyShape(RoundedRectangle(cornerRadius: Theme.windowRadius, style: .continuous)) : AnyShape(Rectangle()))
        .overlay {
            if designSettings.windowBorder {
                WindowBorder(cornerRadius: designSettings.clipWindow ? Theme.windowRadius : 0, light: designSettings.design.isLight)
            }
        }
        // Glass tiles do not take part in the scale (their AppKit glass followed it late, ghosting while the tiles loaded): with
        // Liquid Glass tiles the window only fades in.
        .scaleEffect(windowShown || reduceMotion || designSettings.glass ? 1 : 0.94)
        .opacity(windowShown ? 1 : 0)
        .environment(\.design, designSettings.design)
        .animation(.smooth(duration: 0.45), value: designSettings.design)
        .background { shortcuts }
        .padding(Theme.resizeMargin)
        // The shadow comes in once the glass has grown in, and leaves before the glass shrinks away when the window closes.
        .background(GlassWindowConfigurator(shadow: designSettings.windowShadow && windowShown && !windowClosing, radius: designSettings.windowRadius))
        .ignoresSafeArea()
        .frame(minWidth: Theme.minimumSize.width + 2 * Theme.resizeMargin, minHeight: Theme.minimumSize.height + 2 * Theme.resizeMargin)
        .task { await host.start() }
        .task { await storage.refresh() }
        .modifier(WindowKindSwitch(id: MacSpaceWindow.glass))
        .task {
            // A moment after the window appears, so the glass animates in instead of landing in the first frame.
            windowClosing = false
            try? await Task.sleep(for: .milliseconds(30))
            withAnimation(Theme.windowIn) { windowShown = true }
        }
        .onDisappear { windowShown = false; windowClosing = false }
        .onChange(of: remote.command?.id) { _, _ in
            guard let text = remote.command?.text else { return }
            if text == "close" { close() }
            else if text == "open:settings" { present(.settings) }
            else if text == "open:colorLab" { openWindow(id: ColorLabView.windowID) }
            else if text == "back" { close() }
            else if text.hasPrefix("group:"), case let .module(id)? = layer?.destination { host.handle(for: id)?.openGroup = String(text.dropFirst(6)) }
            else if text.hasPrefix("open:") { present(.module(String(text.dropFirst(5)))) }
            else if text.hasPrefix("pill:"), case let .module(id)? = layer?.destination, let handle = host.handle(for: id) {
                let parts = text.split(separator: ":").map(String.init)
                switch parts[1] {
                case "working": handle.previewPill(cleaning: true, progress: ActionProgress(fraction: parts.count > 2 ? Double(parts[2]) : nil, message: "Freeing space…"), result: nil)
                case "done": handle.previewPill(cleaning: false, progress: nil, result: .succeeded("Freed 712,7 MB"))
                case "later": handle.previewPill(cleaning: false, progress: nil, result: ActionResult(outcome: .succeeded, message: "Finishing in the background"))
                case "fail": handle.previewPill(cleaning: false, progress: nil, result: .failed("Couldn't free it"))
                case "long": handle.previewPill(cleaning: false, progress: nil, result: .failed("Install the helper in Settings, then switch Apple Intelligence off again from this page."))
                default: handle.previewPill(cleaning: false, progress: nil, result: nil)
                }
            }
        }
    }

    private func content(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            HomeView(host: host, storage: storage, frames: frames, open: present, hiddenTile: layer?.destination, closing: windowClosing,
                     dormant: pageSettled)
                .modifier(ZoomFade(progress: progress, scales: !designSettings.glass))
                .allowsHitTesting(layer == nil)
            if let layer, size.width > 0 {
                // An open page covers the whole window, glass frame included. It is drawn larger than the dashboard, so it sits in a box of
                // the dashboard's size: left loose, it made the stack larger, the dashboard was laid out at that size, and every tile
                // jumped while a page opened or closed.
                let full = CGRect(x: -Theme.frame, y: -Theme.frame, width: size.width + 2 * Theme.frame, height: size.height + 2 * Theme.frame)
                ZStack(alignment: .topLeading) {
                    card(layer, in: size, target: full, face: true)
                    page(for: layer.destination)
                        .id(layer.destination)
                        .frame(width: full.width, height: full.height)
                        // One page swapped for another (Command-comma over a module's page, and Back to it) slides across.
                        .transition(.asymmetric(insertion: .move(edge: swapForward ? .trailing : .leading).combined(with: .opacity),
                                                removal: .move(edge: swapForward ? .leading : .trailing).combined(with: .opacity)))
                        .overlay(alignment: .top) {
                            // The band behind the corner buttons and the title moves the window, like a title bar.
                            Color.clear
                                .frame(height: PageInsets.top - 8)
                                .contentShape(Rectangle())
                                .gesture(WindowDragGesture())
                                .allowsWindowActivationEvents(true)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.windowRadius, style: .continuous))
                        .offset(x: full.minX, y: full.minY)
                        .allowsHitTesting(isOpen)
                    card(layer, in: size, target: full, face: false)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func title(for destination: Destination) -> String {
        switch destination {
        case let .module(id):
            guard let handle = host.handle(for: id) else { return "" }
            // On a group's page: the module, then the group.
            if let group = handle.openGroup, let screen = handle.screen, let row = ScreenView.row(group, in: screen.widgets) {
                return "\(handle.manifest.name) › \(row.title)"
            }
            return handle.manifest.name
        case .settings: return host.settingsPage == .cleanupHistory ? "Settings › Recent cleanups" : "Settings"
        case .home, .storage: return ""
        }
    }

    /// Top left: ✕ or back, then the page's title. Top right, on a module's page: its Refresh, as far from the window's edges as Back.
    private var cornerControls: some View {
        HStack(spacing: 8) {
            GlassCircleButton(symbol: isOpen ? "chevron.left" : "xmark", help: isOpen ? "Back" : "Close") {
                isOpen ? close() : closeWindow()
            }
            if isOpen, let destination = layer?.destination {
                PageTitle(host: host, destination: destination, title: title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(designSettings.design.ink)
                    .shadow(color: .black.opacity(designSettings.design.isLight ? 0 : 0.12), radius: 4, y: 1)
                    .padding(.leading, 4)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .offset(x: -10)))
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 8)
            if isOpen, case let .module(id)? = layer?.destination, let handle = host.handle(for: id) {
                RefreshButton(handle: handle)
                    .transition(.opacity)
            }
        }
        .animation(Theme.hover, value: isOpen)
    }

    /// Keyboard: Escape goes back, Command-comma opens Settings.
    private var shortcuts: some View {
        Group {
            Button("Back") { close() }.keyboardShortcut(.cancelAction)
            Button("Settings") { present(.settings) }.keyboardShortcut(",", modifiers: .command)
            Button("Close Window") { closeWindow() }.keyboardShortcut("w", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func card(_ layer: ZoomLayer, in size: CGSize, target: CGRect, face: Bool) -> some View {
        ZoomCard(progress: progress, origin: layer.origin, target: target, container: size) { p in
            TileContent(destination: layer.destination, tint: layer.tint, host: host, storage: storage,
                        captionSize: CaptionSize.tile(height: layer.origin.height), progress: p,
                        showsFace: face, showsCaption: !face, captionOpacity: 1 - ZoomMath.ramp(p, 0.05, 0.45))
        }
    }

    @ViewBuilder
    private func page(for destination: Destination) -> some View {
        switch destination {
        case let .module(id):
            if let handle = host.handle(for: id) {
                ScreenView(handle: handle, tint: layer?.tint ?? .slate, reveal: reveal)
            }
        case .settings:
            SettingsPages(host: host, updates: updates)
                .modifier(ZoomReveal(index: 1, reveal: reveal))
        case .home, .storage:
            EmptyView()
        }
    }

    /// Opens a page: the tile grows into it. From another page (Command-comma over a module's page) the new page slides in over it,
    /// and Back slides back to the page it came from.
    private func present(_ destination: Destination) {
        guard destination != .storage, destination != .home else { return }
        if case let .module(id) = destination, host.handle(for: id) == nil { return }
        let tint = HomeView.tiles(for: host.dashboardHandles).first { $0.destination == destination }?.tint ?? .slate
        let origin = frames.frame(of: destination) ?? CGRect(origin: .zero, size: container)
        if let current = layer {
            guard isOpen, current.destination != destination else { return }
            returnTo = current
            swapForward = true
            if destination == .settings { host.settingsPage = nil }
            withAnimation(Theme.push) { layer = ZoomLayer(destination: destination, origin: origin, tint: tint) }
            return
        }
        generation += 1
        progress = 0
        reveal = 0
        returnTo = nil
        swapForward = true
        if destination == .settings { host.settingsPage = nil }
        layer = ZoomLayer(destination: destination, origin: origin, tint: tint)
        withAnimation(Theme.hover) { isOpen = true }
        let current = generation
        withAnimation(Theme.open, completionCriteria: .removed) { progress = 1 } completion: {
            if generation == current { pageSettled = true }
        }
        withAnimation(.smooth(duration: 0.5).delay(0.22)) { reveal = 1 }
    }

    /// The tiles leave in reverse order, then the glass shrinks away, then the window closes.
    private func closeWindow() {
        guard !windowClosing else { return }
        windowClosing = true
        let tiles = HomeView.depopulateDuration(tiles: HomeView.tiles(for: host.dashboardHandles).count)
        // The glass starts going while the last tiles are still leaving.
        let glassDelay = tiles * 0.6
        withAnimation(Theme.windowOut.delay(glassDelay)) { windowShown = false }
        Task {
            try? await Task.sleep(for: .seconds(glassDelay + 0.3))
            dismissWindow(id: "main")
        }
    }

    /// The page goes first, then the card shrinks back into its tile. Works mid-opening too: the card turns around where it is.
    private func close() {
        guard let open = layer, isOpen else { return }
        // A group's page goes back to its module's page.
        if case let .module(id) = open.destination, let handle = host.handle(for: id), handle.openGroup != nil {
            handle.openGroup = nil
            return
        }
        // A page over Settings goes back to Settings.
        if open.destination == .settings, host.settingsPage != nil {
            host.settingsPage = nil
            return
        }
        // Settings opened over a page goes back to that page.
        if let previous = returnTo {
            returnTo = nil
            swapForward = false
            withAnimation(Theme.push) { layer = ZoomLayer(destination: previous.destination, origin: frames.frame(of: previous.destination) ?? previous.origin,
                                                          tint: previous.tint) }
            return
        }
        // The tiles are drawn again before the card starts shrinking onto them.
        pageSettled = false
        generation += 1
        let current = generation
        // The window may have been resized while the page was open.
        if let tile = frames.frame(of: open.destination) { layer?.origin = tile }
        withAnimation(Theme.hover) { isOpen = false }
        withAnimation(.easeIn(duration: 0.15)) { reveal = 0 }
        withAnimation(Theme.close.delay(0.05), completionCriteria: .removed) { progress = 0 } completion: {
            if generation == current { layer = nil }
        }
        Task { await storage.refresh() }
    }
}

/// The open page's name next to the corner buttons. A module's page is watched, so the name follows into and out of a group's page.
private struct PageTitle: View {
    @ObservedObject var host: ModuleHost
    let destination: Destination
    let title: (Destination) -> String

    var body: some View {
        if case let .module(id) = destination, let handle = host.handle(for: id) {
            ModulePageTitle(handle: handle) { title(destination) }
        } else {
            Text(title(destination))
        }
    }
}

private struct ModulePageTitle: View {
    @ObservedObject var handle: ModuleHandle
    let text: () -> String

    var body: some View {
        Text(text())
            .contentTransition(.opacity)
            .animation(Theme.push, value: handle.openGroup)
    }
}

/// Settings, or the page open over it, sliding in from the right as a group's page does.
struct SettingsPages: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var updates: UpdateController

    var body: some View {
        ZStack(alignment: .topLeading) {
            if host.settingsPage == .cleanupHistory {
                CleanupHistoryPage()
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            } else {
                SettingsView(host: host, updates: updates)
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .animation(Theme.push, value: host.settingsPage)
    }
}
