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

    func testTargetedPresentationAndBackgroundRowActivitySurviveSerialization() throws {
        var row = Row(id: "cloud", title: "Cloud", actions: [Action(id: "free", title: "Free")])
        row.activity = ActionProgress(fraction: 0.4, message: "Removing")
        let screen = Screen(title: "Page", widgets: [.list(ListWidget(id: "rows", rows: [row]))])
        let result = ActionResult(outcome: .succeeded, message: "", presentation: ModulePresentation(tile: Tile(title: "Tile", status: "measured"), screen: screen))
        let roundTrip = try JSONDecoder().decode(ActionResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(roundTrip, result)
        let request = ActionRequest(actionID: "free", rowID: "cloud")
        XCTAssertEqual(try JSONDecoder().decode(ActionRequest.self, from: JSONEncoder().encode(request)), request)
        let legacy = try JSONDecoder().decode(ActionRequest.self, from: Data(#"{"actionID":"free","parameters":{}}"#.utf8))
        XCTAssertNil(legacy.rowID)
    }

    func testManifestDecodesFromJSONWithDefaultsInTheModel() throws {
        let manifest = ModuleManifest(id: "com.example.m", name: "M", summary: "s", version: "1.0", symbol: "star",
                                      permissions: [.fullDiskAccess],
                                      options: [OptionDefinition(id: "o", title: "O", kind: .toggle(defaultValue: true)),
                                                OptionDefinition(id: "p", title: "P", kind: .choice(options: [OptionChoice(id: "a", title: "A"),
                                                                                                                    OptionChoice(id: "b", title: "B", apps: ["com.example.b"])],
                                                                                                    defaultValue: "a"), under: "o")],
                                      backgroundTasks: [BackgroundTaskDefinition(id: "w", title: "Watch", intervalSeconds: 60)])
        let decoded = try JSONDecoder().decode(ModuleManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.sdkVersion, SdkVersion.current)
        // A manifest written before an option could sit under a toggle or name an app still reads.
        let old = try JSONDecoder().decode(OptionDefinition.self, from: Data(#"{"id":"c","title":"C","kind":{"choice":{"options":[{"id":"a","title":"A"}],"defaultValue":"a"}}}"#.utf8))
        XCTAssertNil(old.under)
        if case let .choice(choices, _) = old.kind { XCTAssertNil(choices[0].apps) } else { XCTFail("not a choice") }
    }

    /// A group can let its page choose rows (`Selection`); a row saved before that existed decodes without one, and ids that hold
    /// commas survive the trip through the action's parameter.
    func testASelectionSurvivesTheTripAndOldRowsDecode() throws {
        var group = Row.group(id: "g", title: "G", totalBytes: 3, rows: [Row(id: "a,b", title: "A"), Row(id: "c", title: "C")])
        group.selection = Selection(action: Action(id: "act", title: "Free"), choices: ["a,b": 1, "c": 2], checked: ["c"])
        let decoded = try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(decoded, group)
        XCTAssertNil(try JSONDecoder().decode(Row.self, from: Data(#"{"id":"r","title":"R"}"#.utf8)).selection)
        XCTAssertEqual(Selection.ids(Selection.parameter(["a,b", "c"])), ["a,b", "c"])
        XCTAssertEqual(Selection.ids(nil), [])
        // A choosing page can name its checked rows in the confirmation, and an action say what its button shows while it runs.
        group.selection?.action.confirmation = Confirmation(title: "T", confirmTitle: "Free")
        group.selection?.action.workingTitle = "Freeing space"
        group.selection?.noteNames = ["c": "C"]
        group.selection?.note = "Quits %@."
        XCTAssertEqual(try JSONDecoder().decode(Row.self, from: JSONEncoder().encode(group)), group)
    }

    /// Progress names the rows an action is done with; one written before that existed decodes with none.
    func testProgressCarriesTheFinishedRows() throws {
        let progress = ActionProgress(fraction: 0.5, message: "M", finished: ["a"])
        XCTAssertEqual(try JSONDecoder().decode(ActionProgress.self, from: JSONEncoder().encode(progress)), progress)
        XCTAssertEqual(try JSONDecoder().decode(ActionProgress.self, from: Data(#"{"message":"M"}"#.utf8)).finished, [])
    }

    func testActionResultHelpers() {
        XCTAssertEqual(ActionResult.succeeded("ok", restartRequired: true).restartRequired, true)
        XCTAssertFalse(ActionResult.failed("no").refresh)
    }

    /// A reading's progress reaches every caller, a late one at the fraction reached so far, never backwards, in steps of a percent.
    func testParallelLoadProgressWaitsForEveryPartAndIncludesLateWork() {
        let relay = LoadProgressRelay()
        let parts = relay.parallelParts(weights: [1, 3])
        parts[0](1)
        XCTAssertEqual(relay.fraction, 0.25)
        parts[1](0.5)
        XCTAssertEqual(relay.fraction, 0.625)
        parts[1](0.1)
        XCTAssertEqual(relay.fraction, 0.625, "a delayed report cannot reduce the combined progress")
        parts[1](1)
        XCTAssertEqual(relay.fraction, 1)
        let mixed = LoadProgressRelay()
        mixed.parallelParts(weights: [0.2, 0.65, 0.05, 0.1]).forEach { $0(1) }
        XCTAssertEqual(mixed.fraction, 1, "completed work ends at exactly one despite floating-point weight sums")
    }

    func testLoadProgressRelay() {
        final class Heard: @unchecked Sendable { var values: [Double] = []; let lock = NSLock(); func add(_ v: Double) { lock.withLock { values.append(v) } } }
        let relay = LoadProgressRelay()
        let first = Heard(), late = Heard()
        relay.attach(first.add)
        relay.report(0.2)
        relay.report(0.205)
        relay.report(0.1)
        relay.attach(late.add)
        relay.part(0.5...1)(0.5)
        XCTAssertEqual(first.values, [0.2, 0.75])
        XCTAssertEqual(late.values, [0.2, 0.75])
        XCTAssertEqual(relay.fraction, 0.75)
    }
}
