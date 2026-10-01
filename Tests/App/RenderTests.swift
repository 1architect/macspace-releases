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
            ForEach(Self.sample.widgets) { WidgetView(widget: $0) { _, _ in } }
        }
        .padding(20)
        .frame(width: 760)
        .background(Color(nsColor: .windowBackgroundColor))
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
}
