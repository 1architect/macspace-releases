import AppKit
import Foundation
import MacSpacePlatform
import SQLite3

/// Lets a development session drive the window and photograph it, without Screen Recording permission (an app may capture its own
/// windows). Off unless the app was started with `MACSPACE_DEBUG=1`. Commands arrive as the object of the distributed notification
/// `com.macspace.debug`:
///
///     open:<module id> | open:settings | group:<row id> | back | close | capture:<file.png> | frames:<folder>:<count>:<milliseconds> | info:<file.txt> | frame:<x>,<y>,<width>,<height> | glass:on|off | glassElements:on|off | palette:<deep|mono|sketch|nord|paper> | background:<palette|system|light|dark> | pill:<idle|working[:fraction]|done|later|fail|long> | open:colorLab | standardWindow:on|off | titleBar:on|off | sidebarIcons:on|off | standardGlass:on|off | sidebar | radius:<tile>:<window> | captureTitled:<window title>:<file.png> | capturePopover:<file.png> | du:<depth>:<file.tsv>:<folder> | settings:<file.json> | sql:<out.txt>|<database>|<query>
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
        } else if text.hasPrefix("sidebarIcons:") {
            DesignSettings.shared.standardSidebarIcons = text == "sidebarIcons:on"
        } else if text.hasPrefix("standardGlass:") {
            DesignSettings.shared.standardGlassBackground = text == "standardGlass:on"
        } else if text.hasPrefix("titleBar:") {
            DesignSettings.shared.standardTitleBar = text == "titleBar:on"
        } else if text.hasPrefix("radius:") {
            // radius:<tile>:<window>
            let values = text.split(separator: ":").dropFirst().compactMap { Double($0) }
            if values.count == 2 { DesignSettings.shared.tileRadius = values[0]; DesignSettings.shared.windowRadius = values[1] }
        } else if text.hasPrefix("standardWindow:") {
            DesignSettings.shared.standardWindow = text == "standardWindow:on"
        } else if text.hasPrefix("background:"), let mode = BackgroundAppearance(rawValue: String(text.dropFirst("background:".count))) {
            DesignSettings.shared.backgroundAppearance = mode
        } else if text.hasPrefix("glass:") {
            DesignSettings.shared.glass = text == "glass:on"
        } else if text.hasPrefix("palette:"), let scheme = PaletteScheme(rawValue: String(text.dropFirst("palette:".count))) {
            DesignSettings.shared.scheme = scheme
        } else if text.hasPrefix("sql:") {
            // sql:<out.txt>|<database>|<query>: one read-only query with the app's own access, rows tab-separated.
            let parts = text.dropFirst("sql:".count).split(separator: "|", maxSplits: 2).map(String.init)
            if parts.count == 3 { Task.detached(priority: .utility) { DebugSQL.run(parts[2], database: parts[1], to: parts[0]) } }
        } else if text.hasPrefix("settings:") {
            // settings:<file.json>, the disk as System Settings divides it (`SettingsStorage`), measured with the app's own access.
            let file = String(text.dropFirst("settings:".count))
            Task.detached(priority: .utility) {
                guard let reading = SettingsStorageMeter().measure() else { return }
                var json: [String: Any] = ["capacity": reading.capacity, "used": reading.used, "macOS": reading.macOS, "systemData": reading.systemData]
                for category in reading.categories { json[category.id] = category.bytes }
                if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: file))
                }
            }
        } else if text.hasPrefix("du:") {
            // du:<depth>:<file.tsv>:<folder>, sized with the app's own Full Disk Access (a shell usually has none).
            let parts = text.dropFirst("du:".count).split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3, let depth = Int(parts[0]) {
                Task.detached(priority: .utility) { DiskTally.write(root: parts[2], depth: depth, to: parts[1]) }
            }
        } else if text.hasPrefix("captureTitled:") {
            // captureTitled:<window title>:<file.png>
            let parts = text.dropFirst("captureTitled:".count).split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { Self.capture(to: parts[1], title: parts[0]) }
        } else if text.hasPrefix("capturePopover:") {
            // The balloon an (i) opened (`InfoButton`): a window of its own.
            let path = String(text.dropFirst("capturePopover:".count))
            let windows = NSApp.windows.filter { $0.isVisible }
            try? windows.map { "\(type(of: $0)) \($0.frame)" }.joined(separator: "\n").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            if let popover = windows.filter({ String(describing: type(of: $0)).contains("Popover") }).max(by: { $0.frame.width < $1.frame.width }) {
                Self.capture(to: path, window: popover)
            }
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

    static func capture(to path: String, title: String? = nil, window: NSWindow? = nil) {
        guard let window = window ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 && (title == nil || $0.title == title) }), let createImage,
              let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), 0)?.takeRetainedValue(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            NSLog("MacSpace debug: capture failed")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// For finding what the System Data scan leaves out: every folder down to `depth` under a root, with the space its files take
/// (allocated size, other volumes skipped) and the folders that could not be listed. Written as `bytes<TAB>unreadable<TAB>path`,
/// largest first, with a line `#done` at the end.
enum DiskTally {
    static func write(root: String, depth: Int, to path: String) {
        let rootURL = URL(fileURLWithPath: root)
        let rootComponents = rootURL.standardizedFileURL.pathComponents.count
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .volumeIdentifierKey]
        let rootVolume = (try? rootURL.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        var bytes: [String: UInt64] = [:]
        var unreadable: [String: Int] = [:]
        func bucket(_ url: URL) -> String {
            let components = url.standardizedFileURL.pathComponents
            return NSString.path(withComponents: Array(components.prefix(min(components.count, rootComponents + depth))))
        }
        let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: []) { url, _ in
            unreadable[bucket(url), default: 0] += 1
            return true
        }
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                if let volume = values.volumeIdentifier as? NSObject, let rootVolume, !volume.isEqual(rootVolume) { enumerator?.skipDescendants() }
                continue
            }
            let size = UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            bytes[bucket(url.deletingLastPathComponent()), default: 0] += size
        }
        // Each folder's figure includes its subfolders' (down to `depth`).
        var totals: [String: UInt64] = [:]
        for (folder, size) in bytes {
            var components = URL(fileURLWithPath: folder).pathComponents
            while components.count >= rootComponents {
                totals[NSString.path(withComponents: components), default: 0] += size
                components.removeLast()
            }
        }
        let lines = totals.sorted { $0.value > $1.value }.map { "\($0.value)\t\(unreadable[$0.key] ?? 0)\t\($0.key)" }
            + unreadable.filter { totals[$0.key] == nil }.map { "0\t\($0.value)\t\($0.key)" } + ["#done"]
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Read-only SQLite queries for development (`sql:`), with the app's Full Disk Access.
enum DebugSQL {
    static func run(_ query: String, database: String, to file: String) {
        var db: OpaquePointer?
        var output = ""
        if sqlite3_open_v2("file:\(database)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
            output = "open failed: \(String(cString: sqlite3_errmsg(db)))"
        } else {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) != SQLITE_OK {
                output = "prepare failed: \(String(cString: sqlite3_errmsg(db)))"
            } else {
                while sqlite3_step(statement) == SQLITE_ROW {
                    output += (0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "NULL" }.joined(separator: "\t") + "\n"
                }
            }
            sqlite3_finalize(statement)
        }
        sqlite3_close(db)
        try? output.write(toFile: file, atomically: true, encoding: .utf8)
    }
}
