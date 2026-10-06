import AppKit
import Combine
import MacSpaceSdk
import SwiftUI

/// Opens the window, or a page in it, from outside the window (the menu bar). The window registers how to open itself
/// (`openWindow`) when it appears; a page asked for before the window is there waits in `pending` until the window takes it.
@MainActor
public final class AppRouter: ObservableObject {
    public static let shared = AppRouter()

    struct Request: Equatable {
        let id: Int
        let destination: Destination
    }

    @Published private(set) var request: Request?
    private var pending: Destination?
    private var counter = 0
    /// SwiftUI's `openWindow`, handed over by the window when it appears: AppKit code has no other way to open a SwiftUI window.
    var openWindow: ((String) -> Void)?

    /// Brings MacSpace forward, opening its window if it is closed, and then the page for `destination`, if any.
    public func open(_ destination: Destination? = nil) {
        NSApp.activate()
        if let window = Self.mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow(MacSpaceWindow.current)
        } else {
            // No window has been open since launch (MacSpace started in the menu bar), so none could hand over `openWindow`. The
            // window scenes claim `macspace://<window id>` (`handlesExternalEvents`); opening it with this very app opens the window.
            if let url = URL(string: "macspace://\(MacSpaceWindow.current)") {
                NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        guard let destination else { return }
        pending = destination
        counter += 1
        request = Request(id: counter, destination: destination)
    }

    /// The page asked for, once: the window that shows it takes it.
    func take() -> Destination? {
        defer { pending = nil }
        return pending
    }

    /// The window of the kind in use, if it is open.
    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MacSpaceWindow.current) == true && ($0.isVisible || $0.isMiniaturized) }
    }
}

/// The menu bar item. A click opens MacSpace; a right click (or Control-click) opens its menu: each module with what its tile says,
/// opening that module's page, then Open, Settings and Quit. While something is being cleaned, the icon's circles leave and come back
/// (`MenuBarIcon`).
@MainActor
public final class StatusItemController: NSObject {
    public static let shared = StatusItemController()

    private var item: NSStatusItem?
    private weak var host: ModuleHost?
    private var observers: Set<AnyCancellable> = []
    private var animation: Task<Void, Never>?
    private var phase: Double = 0

    public func install(host: ModuleHost) {
        self.host = host
        updateVisibility()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateVisibility() } }
            .store(in: &observers)
        host.$isCleaning.removeDuplicates()
            .sink { [weak self] cleaning in MainActor.assumeIsolated { if cleaning { self?.animate() } } }
            .store(in: &observers)
    }

    private func updateVisibility() {
        let shown = GeneralSettings.showsInMenuBar()
        if shown, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = MenuBarIcon.image(phase: phase)
            item.button?.setAccessibilityLabel("MacSpace")
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            self.item = item
        } else if !shown, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            AppRouter.shared.open()
        }
    }

    /// The menu is built when it opens, so it says what the tiles say now. Set on the item only while it shows: with a menu attached,
    /// a left click would open it too.
    private func showMenu() {
        guard let item, let button = item.button else { return }
        item.menu = menu()
        button.performClick(nil)
        item.menu = nil
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        for handle in host?.activeHandles ?? [] {
            let entry = NSMenuItem(title: handle.manifest.name, action: #selector(openModule(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = handle.id
            entry.image = NSImage(systemSymbolName: handle.manifest.symbol, accessibilityDescription: nil)
            if let tile = handle.tile {
                entry.subtitle = tile.status
                if tile.needsAttention { entry.badge = NSMenuItemBadge(string: "!") }
            }
            menu.addItem(entry)
        }
        if host?.activeHandles.isEmpty ?? true {
            menu.addItem(NSMenuItem(title: "No modules are on", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(entry("Open MacSpace", #selector(openApp), key: "o"))
        menu.addItem(entry("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(entry("Quit MacSpace", #selector(quit), key: "q"))
        return menu
    }

    private func entry(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    @objc private func openModule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AppRouter.shared.open(.module(id))
    }

    @objc private func openApp() { AppRouter.shared.open() }
    @objc private func openSettings() { AppRouter.shared.open(.settings) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// The circles leave and come back, round after round, while something is cleaned; the round in progress finishes when it ends.
    private func animate() {
        guard animation == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        animation = Task { @MainActor [weak self] in
            let start = Date()
            while !Task.isCancelled, let self {
                try? await Task.sleep(for: .seconds(1 / MenuBarIcon.frameRate))
                let next = (Date().timeIntervalSince(start) / MenuBarIcon.round).truncatingRemainder(dividingBy: 1)
                if !(self.host?.isCleaning ?? false), next < self.phase { break }
                self.phase = next
                self.item?.button?.image = MenuBarIcon.image(phase: next)
            }
            self?.phase = 0
            self?.item?.button?.image = MenuBarIcon.image(phase: 0)
            self?.animation = nil
        }
    }
}
