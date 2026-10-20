import AppKit
import SwiftUI

/// Lets go of the window's pages as soon as it is closed. SwiftUI keeps a closed window and everything in it, so that it can show it
/// again at once: the dashboard's whole view tree stayed while MacSpace ran on in the menu bar or in the background (Issue 11). Once no
/// window of MacSpace is open, the window's content is dropped (`ReleasableContent`), and it is built again when a window is next on
/// screen, which then opens as it does at launch: the glass growing in and the tiles coming in one after another.
///
/// Built again only once the window is visible, never while it is still hidden: built hidden, the window's opening animations had
/// already played when it appeared (an earlier attempt).
@MainActor
public final class ClosedWindowRelease: ObservableObject {
    public static let shared = ClosedWindowRelease()

    @Published private(set) var isReleased = false
    private var observers: [NSObjectProtocol] = []
    private let keepsRunning: () -> Bool
    private let hasOpenWindow: (NSWindow?) -> Bool

    init(keepsRunning: @escaping () -> Bool = { GeneralSettings.keepsRunning() },
         hasOpenWindow: @escaping (NSWindow?) -> Bool = { BackgroundPresence.hasOpenWindow(besides: $0) }) {
        self.keepsRunning = keepsRunning
        self.hasOpenWindow = hasOpenWindow
    }

    public func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // SwiftUI hides a window scene's window when it is closed, so that it can show it again, rather than closing it: the close
        // alone posts nothing to count on. Every change that can hide or show a window is a moment to look again.
        let windowChanges: [Notification.Name] = [NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification,
                                                  NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                                                  NSWindow.didDeminiaturizeNotification]
        for name in windowChanges {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let closing = name == NSWindow.willCloseNotification ? notification.object as? NSWindow : nil
                // After the change has settled: a window just closing or ordered out still counts as visible.
                DispatchQueue.main.async { MainActor.assumeIsolated { ClosedWindowRelease.shared.windowsChanged(closing: closing) } }
            })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { ClosedWindowRelease.shared.windowsChanged(closing: nil) } }
            })
        }
    }

    /// A window of MacSpace shown, hidden or closed: with one open (on screen or in the Dock) the content stays or is built again;
    /// with none, it goes. Quitting with the last window, there is nothing to keep.
    func windowsChanged(closing: NSWindow?) {
        if hasOpenWindow(closing) {
            if isReleased { isReleased = false }
        } else if keepsRunning(), !isReleased {
            release()
        }
    }

    /// Drops the window's content now.
    func release() {
        isReleased = true
    }
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
