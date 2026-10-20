import AppKit
import SwiftUI

/// Lets go of the closed window's pages after a while. SwiftUI keeps a closed window and everything in it, so that it can show it again
/// at once: the dashboard's whole view tree, about 40 MB, stayed while MacSpace ran on in the menu bar or in the background (Issue 11).
/// Ten minutes after the last window closed, the window's content is dropped (`ReleasableContent`), and it is built again when the
/// window is next on screen: it then opens as it does at launch, the glass growing in and the tiles coming in one after another.
///
/// Built again only once the window is visible, never while it is still hidden: built hidden, the window's opening animations had
/// already played when it appeared (an earlier attempt, which also dropped the pages at once and rebuilt them on every reopen).
@MainActor
public final class ClosedWindowRelease: ObservableObject {
    public static let shared = ClosedWindowRelease()

    @Published private(set) var isReleased = false
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private let delay: Duration
    private let keepsRunning: () -> Bool
    private let hasOpenWindow: (NSWindow?) -> Bool

    init(delay: Duration = ClosedWindowRelease.defaultDelay, keepsRunning: @escaping () -> Bool = { GeneralSettings.keepsRunning() },
         hasOpenWindow: @escaping (NSWindow?) -> Bool = { BackgroundPresence.hasOpenWindow(besides: $0) }) {
        self.delay = delay
        self.keepsRunning = keepsRunning
        self.hasOpenWindow = hasOpenWindow
    }

    /// Ten minutes: a window closed and opened again soon after keeps its pages and opens at once. A development build can shorten
    /// it, in seconds, for measuring (`memory.releaseClosedWindowAfter`).
    static var defaultDelay: Duration {
        #if MACSPACE_DEV
        let seconds = UserDefaults.standard.double(forKey: "memory.releaseClosedWindowAfter")
        if seconds > 0 { return .seconds(seconds) }
        #endif
        return .seconds(600)
    }

    public func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            let closing = notification.object as? NSWindow
            // After the window is gone, so it no longer counts as open.
            DispatchQueue.main.async { MainActor.assumeIsolated { ClosedWindowRelease.shared.windowClosed(closing) } }
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    if window.isVisible, BackgroundPresence.isAppWindow(window) { ClosedWindowRelease.shared.restore() }
                }
            })
        }
    }

    /// A window closed: once no other is open, the pages go after `delay`, unless one opens first. Quitting with the last window, there
    /// is nothing to keep.
    func windowClosed(_ closing: NSWindow?) {
        guard keepsRunning(), !hasOpenWindow(closing) else { return }
        pending?.cancel()
        pending = Task { [weak self, delay] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !self.hasOpenWindow(nil) else { return }
            self.release()
        }
    }

    /// Drops the window's content now.
    func release() {
        pending = nil
        isReleased = true
    }

    /// A window of MacSpace is on screen: its content is built again if it was dropped.
    func restore() {
        pending?.cancel()
        pending = nil
        if isReleased { isReleased = false }
    }

    var isPending: Bool { pending != nil }
}

/// A window's content, dropped while `ClosedWindowRelease` has let it go.
public struct ReleasableContent<Content: View>: View {
    @ObservedObject private var release = ClosedWindowRelease.shared
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        if release.isReleased {
            Color.clear
        } else {
            content()
        }
    }
}
