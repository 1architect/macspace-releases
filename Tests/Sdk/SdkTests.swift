import XCTest
import MacSpaceSdk

final class SdkTests: XCTestCase {
    func testScreenSurvivesAJSONRoundTrip() throws {
        let action = Action(id: "clean", title: "Clean", symbol: "trash", role: .destructive, parameters: ["id": "x"],
                            confirmation: Confirmation(title: "Clean?", message: "m", confirmTitle: "Clean"), requires: [.privilegedHelper])
        let screen = Screen(title: "T", subtitle: "S", widgets: [
            .banner(Banner(id: "b", severity: .warning, title: "t", message: "m", action: action)),
            .usage(UsageBar(id: "u", title: "Storage", totalBytes: 100, segments: [UsageSegment(id: "s", label: "Apps", bytes: 40, tone: .series(1))], footnote: "f")),
            .chart(BarChart(id: "c", title: "Top", bars: [Bar(id: "a", label: "A", value: 3, valueLabel: "3 GB")])),
            .list(ListWidget(id: "l", title: "L", emptyMessage: "none", rows: [Row(id: "r", title: "R", badge: Badge("new", tone: .positive), steps: ["one"], actions: [action])])),
            .toggles(ToggleList(id: "t", rows: [ToggleRow(id: "tr", title: "Toggle", isOn: true, badge: Badge("risk"), detail: "d", action: action)])),
            .button(ButtonWidget(id: "bt", action: action, footnote: "n")),
            .steps(StepsWidget(id: "st", title: "Steps", steps: ["a", "b"])),
            .text(TextWidget(id: "tx", text: "hello", style: .caption)),
            .section(SectionWidget(id: "se", title: "Section", widgets: [.text(TextWidget(id: "in", text: "inner"))], isCollapsible: true, startsCollapsed: true)),
        ])
        let data = try JSONEncoder().encode(screen)
        XCTAssertEqual(try JSONDecoder().decode(Screen.self, from: data), screen)
        XCTAssertEqual(screen.widgets.map(\.id), ["b", "u", "c", "l", "t", "bt", "st", "tx", "se"])
    }

    func testManifestDecodesFromJSONWithDefaultsInTheModel() throws {
        let manifest = ModuleManifest(id: "com.example.m", name: "M", summary: "s", version: "1.0", symbol: "star",
                                      permissions: [.fullDiskAccess],
                                      options: [OptionDefinition(id: "o", title: "O", kind: .toggle(defaultValue: true)),
                                                OptionDefinition(id: "p", title: "P", kind: .choice(options: [OptionChoice(id: "a", title: "A")], defaultValue: "a"))],
                                      backgroundTasks: [BackgroundTaskDefinition(id: "w", title: "Watch", intervalSeconds: 60)])
        let decoded = try JSONDecoder().decode(ModuleManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.sdkVersion, SdkVersion.current)
    }

    func testActionResultHelpers() {
        XCTAssertEqual(ActionResult.succeeded("ok", restartRequired: true).restartRequired, true)
        XCTAssertFalse(ActionResult.failed("no").refresh)
    }
}
