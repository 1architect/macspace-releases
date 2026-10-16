// Development builds only (`MACSPACE_DEV`, set by Scripts/Assemble.sh for a -dev build): a release has no design tools.
#if MACSPACE_DEV
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The Screenshots window (Design menu, ⌥⌘S): photographs MacSpace's own window, page after page, for the README. The shots are the
/// window's pixels at the screen's full resolution, written as 8-bit RGBA PNG in the display's color space: never a palette (an
/// optimizer's 256 colors turned every soft gradient into bands). Where a gradient still steps by one level, an optional
/// dither of one level breaks the contour up.
public struct ScreenshotToolView: View {
    public static let windowID = "screenshots"

    @StateObject private var tool = ScreenshotTool()

    public init() {}

    public var body: some View {
        Form {
            Section("Folder") {
                LabeledContent("Save in") {
                    Text(tool.folder.path(percentEncoded: false)).lineLimit(2).truncationMode(.middle).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose…") { tool.chooseFolder() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([tool.folder]) }
                }
            }
            Section("Window") {
                TextField("Width (points)", value: $tool.width, format: .number)
                TextField("Height (points)", value: $tool.height, format: .number)
                Text("The files are twice this on a Retina screen. Leave 0 to keep the window as it is.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Shots") {
                ForEach(ScreenshotTool.shots) { shot in
                    Toggle(shot.name, isOn: Binding(get: { tool.selected.contains(shot.id) }, set: { tool.set(shot.id, $0) }))
                }
            }
            Section("Quality") {
                Toggle("Dither gradients", isOn: $tool.dither)
                Stepper(value: $tool.settleSeconds, in: 1...30) { LabeledContent("Wait for each page", value: "\(tool.settleSeconds) s") }
            }
            Section {
                Button(tool.isRunning ? "Capturing…" : "Capture \(tool.selected.count) shots") { tool.run() }
                    .disabled(tool.isRunning || tool.selected.isEmpty)
                if !tool.status.isEmpty { StatusFlag(text: tool.status, tone: .neutral) }
            }
        }
        .formStyle(.grouped)
    }
}

/// `MacSpace --capture-screenshots [folder]` (a development build): draws the shipped look (every Design menu setting at its default,
/// whatever was left in the defaults), takes all the shots, saves them in the folder (the language's Docs/Screenshots folder when none is
/// given) and quits. The language and number format come from `-AppleLanguages "(fr)" -AppleLocale fr_FR`.
public enum ScreenshotLaunch {
    static let flag = "--capture-screenshots"
    public static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    @MainActor
    public static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag) else { return }
        let folder = arguments.dropFirst(index + 1).first.flatMap { $0.hasPrefix("-") ? nil : URL(fileURLWithPath: $0) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let tool = ScreenshotTool()
            if let folder { tool.folder = folder }
            tool.settleSeconds = 10
            tool.warmupSeconds = 40
            await tool.capture()
            NSLog("MacSpace screenshots: \(tool.status)")
            NSApp.terminate(nil)
        }
    }
}

struct Shot: Identifiable {
    enum Kind { case home(dark: Bool), page(Destination), onboarding }
    let id: String
    let name: String
    let kind: Kind
}

@MainActor
final class ScreenshotTool: ObservableObject {
    static let shots: [Shot] = [
        Shot(id: "SystemData", name: "System Data", kind: .page(.module("com.macspace.system-data"))),
        Shot(id: "OtherSystemFiles", name: "Other System Files", kind: .page(.module("com.macspace.other-system-files"))),
        Shot(id: "Siri", name: "Siri & Apple Intelligence", kind: .page(.module("com.macspace.siri"))),
        Shot(id: "Debloat", name: "Debloat", kind: .page(.module("com.macspace.debloat"))),
        Shot(id: "Settings", name: "Settings", kind: .page(.settings)),
        Shot(id: "Home-Light", name: "Home, light", kind: .home(dark: false)),
        Shot(id: "Home-Dark", name: "Home, dark", kind: .home(dark: true)),
        Shot(id: "Onboarding", name: "Onboarding (first step)", kind: .onboarding),
    ]

    private let defaults = UserDefaults.standard
    @Published var folder: URL { didSet { defaults.set(folder.path, forKey: "screenshots.folder") } }
    @Published var width: Double { didSet { defaults.set(width, forKey: "screenshots.width") } }
    @Published var height: Double { didSet { defaults.set(height, forKey: "screenshots.height") } }
    @Published var dither: Bool { didSet { defaults.set(dither, forKey: "screenshots.dither") } }
    @Published var settleSeconds: Int { didSet { defaults.set(settleSeconds, forKey: "screenshots.settle") } }
    @Published var selected: Set<String>
    /// How long the first shot waits for the modules to read the Mac.
    var warmupSeconds = 8
    @Published var isRunning = false
    @Published var status = ""

    init() {
        folder = defaults.string(forKey: "screenshots.folder").map { URL(fileURLWithPath: $0) } ?? Self.defaultFolder()
        width = defaults.object(forKey: "screenshots.width") as? Double ?? 744
        height = defaults.object(forKey: "screenshots.height") as? Double ?? 624
        dither = defaults.object(forKey: "screenshots.dither") as? Bool ?? true
        settleSeconds = defaults.object(forKey: "screenshots.settle") as? Int ?? 6
        selected = Set(Self.shots.map(\.id))
    }

    /// Docs/Screenshots/<language> of the repository this build came from (Build/Dev/MacSpace.app lives three folders below it).
    private static func defaultFolder() -> URL {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let build = Bundle.main.bundleURL.pathComponents
        if let index = build.lastIndex(of: "Build") {
            let root = URL(fileURLWithPath: NSString.path(withComponents: Array(build[..<index])))
            let folder = root.appendingPathComponent("Docs/Screenshots/\(language)")
            if FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path) { return folder }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent("MacSpace Screenshots")
    }

    func set(_ id: String, _ on: Bool) {
        if on { selected.insert(id) } else { selected.remove(id) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        Task { @MainActor in
            await capture()
            isRunning = false
        }
    }

    func capture() async {
        let design = DesignSettings.shared
        let appearance = design.appearanceMode
        defer { design.appearanceMode = appearance }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            status = "Could not make the folder: \(error.localizedDescription)"
            return
        }
        AppRouter.shared.open()
        try? await Task.sleep(for: .seconds(1))
        guard let window = AppRouter.mainWindow else { status = "MacSpace's window is not open."; return }
        if width > 0, height > 0 {
            let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
            window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height), display: true)
        }
        // The first shot waits for every module to finish reading the Mac: a tile that is still loading says so, and the tiles move
        // into their places when the figures arrive.
        status = "Waiting for the modules to read the Mac…"
        try? await Task.sleep(for: .seconds(Double(warmupSeconds)))
        var written: [String] = []
        for shot in Self.shots where selected.contains(shot.id) {
            status = "Capturing \(shot.name)…"
            switch shot.kind {
            case let .home(dark):
                design.appearanceMode = dark ? .night : .day
                AppRouter.shared.open(.home)
            case let .page(destination):
                design.appearanceMode = .day
                AppRouter.shared.open(.home)
                try? await Task.sleep(for: .seconds(1.5))
                AppRouter.shared.open(destination)
            case .onboarding:
                design.appearanceMode = .day
                AppRouter.shared.open(.home)
                try? await Task.sleep(for: .seconds(1.5))
                Onboarding.shared.restart()
            }
            try? await Task.sleep(for: .seconds(Double(settleSeconds)))
            window.orderFrontRegardless()
            guard let image = Self.image(of: window), let data = Self.png(image, dither: dither) else {
                status = "Could not capture \(shot.name)."
                return
            }
            do { try data.write(to: folder.appendingPathComponent("\(shot.id).png")) } catch {
                status = "Could not write \(shot.id).png: \(error.localizedDescription)"
                return
            }
            written.append(shot.id)
            if case .onboarding = shot.kind { Onboarding.shared.finish() }
        }
        AppRouter.shared.open(.home)
        status = "Saved \(written.count) shots in \(folder.lastPathComponent)."
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: Image

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// CGWindowListCreateImage is unavailable to Swift on current SDKs but still answers for the app's own windows, with no Screen
    /// Recording permission.
    private static let createImage: CreateImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    /// The window alone at the screen's full resolution, without its shadow (the window list's "including window", "best
    /// resolution" and "ignore framing").
    private static func image(of window: NSWindow) -> CGImage? {
        createImage?(.null, 1 << 3, UInt32(window.windowNumber), (1 << 3) | (1 << 0))?.takeRetainedValue()
    }

    /// An 8-bit RGBA PNG in the image's own color space. Where a pixel is opaque and a neighbor above or to the left differs by one or
    /// two levels (a gradient's steps), one level of noise breaks the step into grain; flat color and edges stay exact.
    private static func png(_ image: CGImage, dither: Bool) -> Data? {
        let width = image.width, height = image.height
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        if dither {
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            let original = pixels
            func noise() -> Int {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return Int(state % 3) - 1
            }
            for y in 1..<height {
                for x in 1..<width {
                    let i = (y * width + x) * 4
                    guard original[i + 3] == 255 else { continue }
                    var steps = false
                    for neighbor in [i - 4, i - width * 4] where original[neighbor + 3] == 255 {
                        for c in 0..<3 {
                            let d = abs(Int(original[i + c]) - Int(original[neighbor + c]))
                            if d == 1 || d == 2 { steps = true }
                        }
                    }
                    if steps {
                        let n = noise()
                        for c in 0..<3 { pixels[i + c] = UInt8(max(0, min(255, Int(pixels[i + c]) + n))) }
                    }
                }
            }
        }
        let output = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let output else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
#endif
