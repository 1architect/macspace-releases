import XCTest
import MacSpacePlatform
@testable import MacSpaceDebloatPrivileged

final class DebloatOperationsTests: XCTestCase {
    private let flag = ControlSetting.flag("TestDomain", "Feature")

    private var control: DebloatControl {
        DebloatControl(id: "test.flag", title: "Flag", summary: "", category: .telemetry, mechanism: .featureFlag, risk: .low, restart: .reboot,
                       settings: [flag], validatedBuilds: ["26B5091g"])
    }

    /// The fakes are single-threaded test doubles; the handler's factory only needs to be told they are safe to capture.
    private struct EngineBox: @unchecked Sendable { let engine: DebloatEngine }

    private func handler() -> (DebloatPrivilegedOperations, FakeDebloatSystem) {
        let control = self.control
        let system = FakeDebloatSystem(controls: [control])
        let box = EngineBox(engine: DebloatEngine(controls: [control], system: system, journal: MemoryJournalStore()))
        return (DebloatPrivilegedOperations(engineFactory: { _ in box.engine }), system)
    }

    func testStatusAndApplyAreScopedToControlIdsOnly() throws {
        let (operations, _) = handler()
        let caller = PrivilegedCaller(uid: 501)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let statuses = try decoder.decode([ControlStatus].self, from: operations.handle(DebloatPrivilegedOperations.status, arguments: [:], caller: caller))
        XCTAssertEqual(statuses.map(\.controlID), ["test.flag"])

        XCTAssertThrowsError(try operations.handle(DebloatPrivilegedOperations.apply, arguments: ["controls": "rm -rf /"], caller: caller),
                             "only catalog controls can be named")
        XCTAssertThrowsError(try operations.handle(DebloatPrivilegedOperations.apply, arguments: [:], caller: caller), "applying needs named controls")
        XCTAssertThrowsError(try operations.handle("debloat.shell", arguments: ["controls": "test.flag"], caller: caller))
        XCTAssertEqual(Set(operations.operations), [DebloatPrivilegedOperations.status, DebloatPrivilegedOperations.apply,
                                                     DebloatPrivilegedOperations.revert, DebloatPrivilegedOperations.removeProfile])
    }

    func testArgumentsRoundTripThePlanOptions() {
        let arguments = DebloatPrivilegedOperations.arguments(controlIDs: ["a", "b"], options: DebloatPlanOptions(immediate: true))
        XCTAssertEqual(arguments, ["controls": "a,b", "restoreFallbacks": "false", "immediate": "true"])
    }

    func testTheCallerBecomesTheTargetUser() {
        XCTAssertEqual(DebloatTargetUser.forUID(getuid())?.uid, getuid())
        XCTAssertNil(DebloatTargetUser.forUID(4_000_000))
    }
}
