import SwiftUI
import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

/// Draws a screen with every widget type. With MACSPACE_SNAPSHOT_DIR set it also writes PNGs for a visual check.
@MainActor
final class RenderTests: XCTestCase {
    static let sample = Screen(title: "Sample", widgets: [
        .banner(Banner(id: "b", severity: .warning, title: "2 protections were undone", message: "macOS changed them back.",
                       action: Action(id: "fix", title: "Re-apply", role: .prominent))),
        .usage(UsageBar(id: "u", title: "System Data", totalBytes: 100_000_000_000, segments: [
            UsageSegment(id: "a", label: "Documents history", bytes: 6_340_000_000, tone: .series(0)),
            UsageSegment(id: "b", label: "Messaging media", bytes: 4_700_000_000, tone: .series(1)),
            UsageSegment(id: "c", label: "Caches", bytes: 1_900_000_000, tone: .series(2)),
            UsageSegment(id: "d", label: "Other", bytes: 3_100_000_000, tone: .neutral),
        ], footnote: "Measured on the Data volume")),
        .chart(BarChart(id: "c", title: "Largest items", bars: [
            Bar(id: "1", label: "Document versions", value: 6.34, valueLabel: "6,34 GB", tone: .series(0)),
            Bar(id: "2", label: "WhatsApp", value: 4.7, valueLabel: "4,70 GB", tone: .series(1)),
            Bar(id: "3", label: "Caches", value: 1.9, valueLabel: "1,90 GB", tone: .series(2)),
        ])),
        .list(ListWidget(id: "l", title: "Clean up manually", rows: [
            Row(id: "r1", title: "WhatsApp", subtitle: "Photos, videos and documents", trailing: "4,70 GB", badge: Badge("Manual", tone: .caution),
                symbol: "bubble.left", detail: "Open WhatsApp → Settings → Storage.", steps: ["Open Storage", "Delete large chats"]),
            Row(id: "r2", title: "App caches", trailing: "1,90 GB", badge: Badge("Safe", tone: .positive), symbol: "internaldrive",
                actions: [Action(id: "clean", title: "Clean", role: .prominent)]),
        ])),
        .toggles(ToggleList(id: "t", title: "Protections", footnote: "Some need a restart.", rows: [
            ToggleRow(id: "t1", title: "Diagnostics policy", subtitle: "Stops sending analytics", isOn: true, badge: Badge("Verified", tone: .positive),
                      detail: "Works on beta builds.", action: Action(id: "toggle", title: "Toggle")),
            ToggleRow(id: "t2", title: "Personalized ads", isOn: false, isEnabled: false, badge: Badge("Needs profile", tone: .caution), action: Action(id: "toggle", title: "Toggle")),
        ])),
        .button(ButtonWidget(id: "bt", action: Action(id: "purge", title: "Remove unused system assets", symbol: "trash", role: .prominent), footnote: "Frees about 12 GB.")),
        .steps(StepsWidget(id: "s", title: "Next steps", steps: ["Restart the Mac", "Run the release again"])),
        .section(SectionWidget(id: "se", title: "Details", subtitle: "Collapsible", widgets: [.text(TextWidget(id: "x", text: "Inner text", style: .caption))],
                               isCollapsible: true)),
    ])

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            WidgetForm(widgets: Self.sample.widgets, handler: { _, _, _ in nil }) { EmptyView() }.frame(height: 900)
        }
        .padding(20)
        .frame(width: 760)
        .background(TileBackdrop(tint: .blue))
        .environment(\.colorScheme, .dark)
    }

    private func write(_ view: some View, _ name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let bitmap = try XCTUnwrap(renderer.cgImage)
        guard let directory = ProcessInfo.processInfo.environment["MACSPACE_SNAPSHOT_DIR"] else { return }
        try XCTUnwrap(NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// The sketched dashboard: the bento grid with every kind of tile, on a stand-in for the glass (which needs a real window).
    func testDashboardRenders() throws {
        let blocks = [UsageSegment(id: "m", label: "Managed by macOS", bytes: 15_500, tone: .series(0)),
                      UsageSegment(id: "s", label: "App support files", bytes: 7_700, tone: .series(1)),
                      UsageSegment(id: "a", label: "Apple app data", bytes: 4_700, tone: .series(2)),
                      UsageSegment(id: "h", label: "Homebrew", bytes: 2_900, tone: .series(3)),
                      UsageSegment(id: "c", label: "Caches", bytes: 700, tone: .series(4)),
                      UsageSegment(id: "f", label: "Can be freed", bytes: 415, tone: .caution)]
        let dots: [TileDot] = Array(repeating: .done, count: 11) + [.open, .open, .attention]
        let tiles: [(TileTint, TileInfo, Int)] = [
            (.violet, TileInfo(title: "147 GB used", status: "4.7 GB purgeable", graphic: .gauge(value: 0.3, label: "30%", sublabel: "of 494 GB")), 1),
            (.blue, TileInfo(title: "system data", status: "415 MB can be freed", graphic: .blocks(blocks)), 2),
            (.graphite, TileInfo(title: "siri & AI", status: "AI is on", needsAttention: true,
                                 graphic: .state(on: true, alarming: true, detail: "macOS may download its model", meter: nil, meterIsActionable: false)), 1),
            (.teal, TileInfo(title: "debloat", status: "1 undone by macOS", needsAttention: true, graphic: .dots(dots)), 1),
            (.slate, TileInfo.settings, 1),
        ]
        let size = CGSize(width: Theme.defaultSize.width - 2 * Theme.frame, height: Theme.defaultSize.height - 2 * Theme.frame)
        let placements = Bento.pack(spans: tiles.map(\.2), columns: Bento.columns(for: size.width))
        let rows = Bento.rows(placements)
        let view = ZStack(alignment: .topLeading) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                let frame = Bento.frame(placements[index], columns: 3, rows: rows, in: size)
                ZStack(alignment: .bottomTrailing) {
                    TileFace(tint: tile.0, info: tile.1)
                    TileCaption(title: tile.1.title, status: tile.1.status, size: CaptionSize.tile(height: frame.height)).padding(CaptionSize.tilePadding)
                }
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
                .offset(x: frame.minX, y: frame.minY)
            }
            GlassCircleButton(symbol: "xmark", help: "Close") {}.padding(GlassCircleButton.margin)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .padding(Theme.frame)
        .background(RoundedRectangle(cornerRadius: Theme.windowRadius, style: .continuous).fill(Color(red: 0.86, green: 0.82, blue: 0.78)))
        try write(view, "dashboard.png")
    }

    /// A page: the tile grown to fill the glass, widgets on its deep color.
    func testPageRenders() throws {
        let view = ZStack(alignment: .topLeading) {
            TileFace(tint: .teal, info: TileInfo(title: "debloat", status: "0/14 switched off"), progress: 1)
            VStack(alignment: .leading, spacing: 14) {
                WidgetForm(widgets: Array(Self.sample.widgets.prefix(5)), handler: { _, _, _ in nil }) { EmptyView() }.frame(height: 560)
            }
            .padding(.top, PageInsets.top).padding(.horizontal, PageInsets.side)
            .frame(maxWidth: 760, alignment: .leading)
            GlassCircleButton(symbol: "chevron.left", help: "Back") {}.padding(GlassCircleButton.margin)
        }
        .frame(width: 678, height: 640, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
        try write(view, "page.png")
    }

    /// Renders a screen saved with `MacSpaceCli screen <module>` (MACSPACE_SCREEN_JSON) to MACSPACE_SNAPSHOT_DIR/screen.png.
    func testRendersASavedScreen() throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["MACSPACE_SCREEN_JSON"], let directory = env["MACSPACE_SNAPSHOT_DIR"] else { throw XCTSkip("no saved screen") }
        let screen = try JSONDecoder().decode(Screen.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        let view = VStack(alignment: .leading, spacing: 14) {
            Text(screen.title).font(.largeTitle.weight(.bold))
            WidgetForm(widgets: screen.widgets, handler: { _, _, _ in nil }) { EmptyView() }.frame(height: 1200)
        }
        .padding(20).frame(width: 760).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let bitmap = try XCTUnwrap(renderer.cgImage)
        try XCTUnwrap(NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("screen.png"))
    }

    func testEveryWidgetTypeRenders() throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.height, 400)
        if let directory = ProcessInfo.processInfo.environment["MACSPACE_SNAPSHOT_DIR"] {
            let bitmap = try XCTUnwrap(renderer.cgImage)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("widgets.png"))
        }
    }

    func testTreemapGivesEveryValueAFiniteRectangle() {
        let rects = Treemap.layout([900, 300, 0.000_001, 0, 0], in: CGRect(x: 0, y: 0, width: 300, height: 120))
        XCTAssertEqual(rects.count, 5)
        for rect in rects {
            XCTAssertTrue([rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite), "\(rect)")
            XCTAssertTrue(rect.minX >= -0.01 && rect.maxX <= 300.01 && rect.minY >= -0.01 && rect.maxY <= 120.01, "\(rect)")
        }
    }

    func testBlocksLegendMovesOverALongCaption() {
        let short = TileInfo(title: "cache", status: "1 GB")
        let long = TileInfo(title: "other system files", status: "63,9 MB can be freed")
        let size = CGSize(width: 270, height: 220)
        XCTAssertFalse(TileFace.legendAbove(in: CGSize(width: 520, height: 220), info: long, captionSize: 22))
        XCTAssertFalse(TileFace.legendAbove(in: size, info: short, captionSize: 22))
        XCTAssertTrue(TileFace.legendAbove(in: size, info: long, captionSize: 22))
        XCTAssertLessThan(TileFace.chartArea(in: size, info: long, captionSize: 22).height,
                          TileFace.chartArea(in: size, info: short, captionSize: 22).height)
    }
}

final class MenuBarIconTests: XCTestCase {
    func testTheCirclesLeaveAndComeBackOneByOne() {
        XCTAssertEqual(MenuBarIcon.visibility(rank: 0, phase: 0), 1, "the full grid at rest")
        XCTAssertEqual(MenuBarIcon.visibility(rank: 8, phase: 0.5), 0, "all gone in the middle of a round")
        XCTAssertEqual(MenuBarIcon.visibility(rank: 8, phase: 0.999), 1, "all back at its end")
        XCTAssertLessThan(MenuBarIcon.visibility(rank: 0, phase: 0.1), MenuBarIcon.visibility(rank: 5, phase: 0.1), "the first leaves first")
        XCTAssertEqual(Set(MenuBarIcon.order), Set(0..<9))
    }

    /// Writes the animation as a strip to MACSPACE_SNAPSHOT_DIR/menubar-icon.png, to look at it.
    func testRendersTheAnimationStrip() throws {
        guard let directory = ProcessInfo.processInfo.environment["MACSPACE_SNAPSHOT_DIR"] else { throw XCTSkip("no snapshot folder") }
        let frames = 16, cell: CGFloat = 72
        let strip = NSImage(size: NSSize(width: cell * CGFloat(frames), height: cell))
        strip.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: strip.size).fill()
        for index in 0..<frames {
            MenuBarIcon.image(phase: Double(index) / Double(frames)).draw(in: NSRect(x: CGFloat(index) * cell + 4, y: 4, width: cell - 8, height: cell - 8))
        }
        strip.unlockFocus()
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(strip.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("menubar-icon.png"))
    }
}

final class AutoCleanerTests: XCTestCase {
    func testRunsWhenOnAndDue() {
        let now = Date()
        XCTAssertFalse(AutoCleaner.isDue(enabled: false, lastRun: nil, frequency: .daily, now: now))
        XCTAssertTrue(AutoCleaner.isDue(enabled: true, lastRun: nil, frequency: .daily, now: now), "never run: due at once")
        XCTAssertFalse(AutoCleaner.isDue(enabled: true, lastRun: now.addingTimeInterval(-3600), frequency: .daily, now: now))
        XCTAssertTrue(AutoCleaner.isDue(enabled: true, lastRun: now.addingTimeInterval(-90_000), frequency: .daily, now: now))
        XCTAssertFalse(AutoCleaner.isDue(enabled: true, lastRun: now.addingTimeInterval(-90_000), frequency: .weekly, now: now))
    }
}
