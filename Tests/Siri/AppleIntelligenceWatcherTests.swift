import XCTest
@testable import MacSpaceSiri
import MacSpacePlatform
import MacSpaceSiriPrivileged

final class AppleIntelligenceWatcherTests: XCTestCase {
    private let watcher = AppleIntelligenceWatcher(releaseGrace: 3600)

    private func status(_ state: AppleIntelligenceGuardState, at seconds: TimeInterval) -> AppleIntelligenceGuardStatus {
        AppleIntelligenceGuardStatus(
            generatedAt: Date(timeIntervalSince1970: seconds), state: state, ineligibilitySource: nil,
            languagesMatch: nil, eligible: nil, targetSelected: nil, targetInstalled: nil,
            inputs: AppleIntelligenceGuardInputs(systemLanguage: "pt-BR", siriLanguage: "pt-BR", siriModeAnswer: 4,
                                                 autoSetConfiguration: nil, installedTargetAssets: nil),
            reasons: []
        )
    }

    private func run(_ states: [(AppleIntelligenceGuardState, TimeInterval)]) -> [AppleIntelligenceWatchOutcome] {
        var previous: AppleIntelligenceWatchRecord?
        return states.map { state, time in
            let outcome = watcher.transition(previous: previous, status: status(state, at: time))
            previous = outcome.record
            return outcome
        }
    }

    func testFirstProtectedRunIsSilent() {
        let outcome = run([(.protected, 0)])[0]
        XCTAssertNil(outcome.alert)
        XCTAssertTrue(outcome.transitioned)
        XCTAssertEqual(outcome.record.state, .protected)
    }

    func testLosingProtectionAlertsOnceThenStaysQuiet() {
        let outcomes = run([(.protected, 0), (.atRisk, 10), (.atRisk, 20), (.atRisk, 4000)])
        XCTAssertEqual(outcomes[1].alert?.title, "Apple Intelligence is back on")
        XCTAssertNil(outcomes[2].alert)
        XCTAssertNil(outcomes[3].alert)
        XCTAssertEqual(outcomes[3].record.since, Date(timeIntervalSince1970: 10))
    }

    func testUnknownAlertsBecauseTheMethodMayHaveBroken() {
        XCTAssertEqual(run([(.protected, 0), (.unknown, 5)])[1].alert?.title, "Couldn't check Apple Intelligence")
    }

    func testReleasingIsQuietUntilTheGracePeriodThenAlertsOnce() {
        let outcomes = run([(.releasing, 0), (.releasing, 1800), (.releasing, 3600), (.releasing, 7200)])
        XCTAssertNil(outcomes[0].alert)
        XCTAssertNil(outcomes[1].alert)
        XCTAssertFalse(outcomes[1].record.alerted)
        XCTAssertEqual(outcomes[2].alert?.title, "Apple Intelligence models still on disk")
        XCTAssertNil(outcomes[3].alert)
    }

    func testReturningToProtectedAnnouncesRestoration() {
        let outcomes = run([(.atRisk, 0), (.releasing, 60), (.protected, 120)])
        XCTAssertNil(outcomes[1].alert)
        XCTAssertEqual(outcomes[2].alert?.severity, .info)
        XCTAssertEqual(outcomes[2].alert?.title, "Apple Intelligence is off")
    }

    func testStorePersistsRecordAndRotatesEventLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppleIntelligenceWatchStore(stateURL: root.appendingPathComponent("state.json"),
                                                eventLogURL: root.appendingPathComponent("logs/ai-watch.jsonl"))
        XCTAssertNil(store.load())
        let first = watcher.transition(previous: nil, status: status(.atRisk, at: 0))
        try store.save(first.record)
        XCTAssertEqual(store.load(), first.record)

        try store.append(first, status: status(.atRisk, at: 0))
        try store.append(first, status: status(.atRisk, at: 1))
        let log = try String(contentsOf: store.eventLogURL, encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 2)
        XCTAssertTrue(log.contains("\"state\":\"at-risk\""))

        try Data(count: AppleIntelligenceWatchStore.maximumLogBytes + 1).write(to: store.eventLogURL)
        try store.append(first, status: status(.atRisk, at: 2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.eventLogURL.appendingPathExtension("1").path))
        XCTAssertEqual(try String(contentsOf: store.eventLogURL, encoding: .utf8).split(separator: "\n").count, 1)
    }
}
