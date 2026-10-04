import AppKit
import Foundation

/// Lets a development session drive the window and photograph it, without Screen Recording permission (an app may capture its own
/// windows). Off unless the app was started with `MACSPACE_DEBUG=1`. Commands arrive as the object of the distributed notification
/// `com.macspace.debug`:
///
///     open:<module id> | open:settings | group:<row id> | back | close | capture:<file.png> | frames:<folder>:<count>:<milliseconds> | info:<file.txt> | frame:<x>,<y>,<width>,<height> | glass:on|off | glassElements:on|off | palette:<deep|mono|sketch|nord|paper>
@MainActor
final class DebugRemote: ObservableObject {
    static let shared = DebugRemote()
    static let isEnabled = ProcessInfo.processInfo.environment["MACSPACE_DEBUG"] == "1"

    /// The latest navigation command, for the main view.
    @Published private(set) var command: (id: Int, text: String)?
    private var counter = 0

    private init() {
        guard Self.isEnabled else { return }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.macspace.debug"), object: nil, queue: .main) { note in
            guard let text = note.object as? String else { return }
            MainActor.assumeIsolated { DebugRemote.shared.handle(text) }
        }
    }

    func start() {}

    private func handle(_ text: String) {
        if text.hasPrefix("info:"), let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 }) {
            let info = "frame \(window.frame) styleMask \(window.styleMask.rawValue) resizable \(window.styleMask.contains(.resizable)) key \(window.canBecomeKey) isKey \(window.isKeyWindow) shadow \(window.hasShadow) opaque \(window.isOpaque) class \(type(of: window))"
            try? info.write(toFile: String(text.dropFirst("info:".count)), atomically: true, encoding: .utf8)
        } else if text.hasPrefix("frame:"), let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 }) {
            let numbers = text.dropFirst("frame:".count).split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 4 else { return }
            window.setFrame(NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), display: true, animate: false)
        } else if text.hasPrefix("glassElements:") {
            DesignSettings.shared.glassElements = text == "glassElements:on"
        } else if text.hasPrefix("glass:") {
            DesignSettings.shared.glass = text == "glass:on"
        } else if text.hasPrefix("palette:"), let scheme = PaletteScheme(rawValue: String(text.dropFirst("palette:".count))) {
            DesignSettings.shared.scheme = scheme
        } else if text.hasPrefix("capture:") {
            Self.capture(to: String(text.dropFirst("capture:".count)))
        } else if text.hasPrefix("frames:") {
            let parts = text.split(separator: ":").map(String.init)
            guard parts.count == 4, let count = Int(parts[2]), let interval = Int(parts[3]) else { return }
            Task { @MainActor in
                for index in 0..<count {
                    Self.capture(to: "\(parts[1])/frame-\(String(format: "%03d", index)).png")
                    try? await Task.sleep(for: .milliseconds(interval))
                }
            }
        } else {
            counter += 1
            command = (counter, text)
        }
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// CGWindowListCreateImage is unavailable to Swift on current SDKs but still answers for the app's own windows.
    private static let createImage: CreateImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 }), let createImage,
              let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), 0)?.takeRetainedValue(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            NSLog("MacSpace debug: capture failed")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
