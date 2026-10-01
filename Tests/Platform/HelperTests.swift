import XCTest
import MacSpaceSdk
import ServiceManagement
import MacSpacePlatform

struct EchoHandler: PrivilegedOperationHandler {
    var operations: Set<String> { ["test.echo", "test.fail", "test.caller"] }

    func handle(_ operation: String, arguments: [String: String], caller: PrivilegedCaller) throws -> Data {
        switch operation {
        case "test.echo": return try JSONEncoder().encode(arguments)
        case "test.caller": return try JSONEncoder().encode(["uid": String(caller.uid)])
        default: throw PrivilegedOperationError("handler said no")
        }
    }
}

final class HelperServiceTests: XCTestCase {
    private let service = PrivilegedHelperService(handlers: [EchoHandler()])

    func testRoutesToHandlersAndPassesTheCaller() throws {
        let echo = service.handle(HelperRequest(operation: "test.echo", arguments: ["a": "1"]), clientUID: 501)
        XCTAssertNil(echo.error)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(echo.payload)), ["a": "1"])
        let caller = service.handle(HelperRequest(operation: "test.caller"), clientUID: 777)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(caller.payload)), ["uid": "777"], "handlers act for the calling user, not root")
    }

    func testRefusesWhatItDoesNotKnow() {
        XCTAssertNil(service.handle(HelperRequest(operation: PrivilegedHelperService.pingOperation), clientUID: 501).error)
        XCTAssertEqual(service.handle(HelperRequest(operation: "rm -rf /"), clientUID: 501).error, "Unknown operation rm -rf /.")
        XCTAssertNotNil(service.handle(HelperRequest(operation: "test.echo", protocolVersion: 99), clientUID: 501).error)
        XCTAssertEqual(service.handle(HelperRequest(operation: "test.fail"), clientUID: 501).error, "handler said no")
        XCTAssertEqual(service.operations, ["helper.ping", "test.caller", "test.echo", "test.fail"])
    }
}

final class HelperXPCTests: XCTestCase {
    func testARealXPCRoundTripCarriesPayloadsAndErrors() async throws {
        let service = PrivilegedHelperService(handlers: [EchoHandler()])
        let delegate = PrivilegedHelperListenerDelegate(service: service, clientRequirement: nil)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let client = PrivilegedHelperClient(endpoint: listener.endpoint)

        let echoed = try await client.perform([String: String].self, operation: "test.echo", arguments: ["k": "v"])
        XCTAssertEqual(echoed, ["k": "v"])
        _ = try await client.perform(operation: PrivilegedHelperService.pingOperation, arguments: [:])
        do {
            _ = try await client.perform(operation: "test.fail", arguments: [:])
            XCTFail("expected the helper's error")
        } catch let error as PrivilegedHelperError {
            XCTAssertEqual(error, .helper("handler said no"))
        }
        do {
            _ = try await client.perform(operation: "nope", arguments: [:])
            XCTFail("expected an unknown-operation error")
        } catch let error as PrivilegedHelperError {
            XCTAssertEqual(error, .helper("Unknown operation nope."))
        }
    }
}

final class LazyChannelTests: XCTestCase {
    private func message(_ status: SMAppService.Status) async -> String {
        let channel = LazyPrivilegedChannel(status: { status }, makeClient: { fatalError("must not connect") })
        do { _ = try await channel.perform(operation: "x", arguments: [:]); return "" } catch { return "\(error)" }
    }

    func testSaysWhyTheHelperCannotBeUsed() async {
        let notInstalled = await message(.notRegistered)
        let waiting = await message(.requiresApproval)
        XCTAssertTrue(notInstalled.contains("not installed"), notInstalled)
        XCTAssertTrue(waiting.contains("not approved"), waiting)
    }

    func testPermissionStatusMapping() {
        XCTAssertEqual(PrivilegedHelperInstaller.permissionStatus(.enabled), .granted)
        XCTAssertEqual(PrivilegedHelperInstaller.permissionStatus(.requiresApproval), .missing)
        XCTAssertEqual(PrivilegedHelperInstaller.permissionStatus(.notRegistered), .missing)
        XCTAssertEqual(PrivilegedHelperInstaller.permissionStatus(.notFound), .unknown, "a development build without the bundled plist")
    }
}
