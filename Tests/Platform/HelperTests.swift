import XCTest
import MacSpaceSdk
import ServiceManagement
import MacSpacePlatform

struct EchoHandler: PrivilegedOperationHandler {
    var operations: Set<String> { ["test.echo", "test.fail", "test.caller", "test.delete"] }
    var readOnlyOperations: Set<String> { ["test.echo", "test.fail", "test.caller"] }

    func handle(_ operation: String, arguments: [String: String], caller: PrivilegedCaller) throws -> Data {
        switch operation {
        case "test.echo": return try JSONEncoder().encode(arguments)
        case "test.caller": return try JSONEncoder().encode(["uid": String(caller.uid)])
        case "test.delete": return Data("deleted".utf8)
        default: throw PrivilegedOperationError("handler said no")
        }
    }
}

final class HelperServiceTests: XCTestCase {
    private let service = PrivilegedHelperService(handlers: [EchoHandler()], isAdmin: { $0 == 501 })

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
        XCTAssertEqual(service.operations, ["helper.ping", "test.caller", "test.delete", "test.echo", "test.fail"])
    }

    /// Any account that runs MacSpace or its command-line tool reaches the helper: what changes the Mac is done only for an
    /// administrator, what only reads it for anyone.
    func testOnlyAnAdministratorMayChangeTheMac() {
        XCTAssertNil(service.handle(HelperRequest(operation: "test.delete"), clientUID: 501).error)
        XCTAssertEqual(service.handle(HelperRequest(operation: "test.delete"), clientUID: 502).error, PrivilegedHelperService.needsAdministrator)
        XCTAssertNil(service.handle(HelperRequest(operation: "test.echo"), clientUID: 502).error)
        XCTAssertNil(service.handle(HelperRequest(operation: PrivilegedHelperService.pingOperation), clientUID: 502).error)
    }

    func testAdministratorsAreTheAdminGroup() {
        XCTAssertTrue(AdminAccounts.contains(0))
        // `nobody` is never an administrator.
        XCTAssertFalse(AdminAccounts.contains(uid_t(bitPattern: -2)))
        XCTAssertEqual(AdminAccounts.contains(getuid()), getgrgid(80).map { group in
            var names: [String] = []
            var member = group.pointee.gr_mem
            while let name = member?.pointee { names.append(String(cString: name)); member = member?.advanced(by: 1) }
            return names.contains(NSUserName())
        } ?? false)
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

/// A helper that takes calls and never answers, as one launchd cannot start.
private final class SilentHelper: NSObject, NSXPCListenerDelegate, MacSpaceHelperProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MacSpaceHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {}
}

final class HelperTimeoutTests: XCTestCase {
    /// A call nobody answers ends with an error instead of keeping the page that asked loading forever.
    func testACallThatIsNeverAnsweredEnds() async throws {
        let silent = SilentHelper()
        let listener = NSXPCListener.anonymous()
        listener.delegate = silent
        listener.resume()
        defer { listener.invalidate() }
        let client = PrivilegedHelperClient(endpoint: listener.endpoint)
        let started = Date()
        do {
            _ = try await client.perform(operation: PrivilegedHelperService.pingOperation, arguments: [:], timeout: 0.5)
            XCTFail("expected no answer")
        } catch let error as PrivilegedHelperError {
            guard case .noAnswer = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// A helper that does not answer is not asked again for a while: the pages that need it each failed only after waiting as long.
    func testAHelperThatDoesNotAnswerIsNotAskedAgainAtOnce() async throws {
        let silent = SilentHelper()
        let listener = NSXPCListener.anonymous()
        listener.delegate = silent
        listener.resume()
        defer { listener.invalidate() }
        final class Made: @unchecked Sendable { var count = 0; let endpoint: NSXPCListenerEndpoint; init(_ endpoint: NSXPCListenerEndpoint) { self.endpoint = endpoint } }
        let made = Made(listener.endpoint)
        let health = HelperHealth()
        let channel = LazyPrivilegedChannel(status: { .enabled }, makeClient: { made.count += 1; return PrivilegedHelperClient(endpoint: made.endpoint) },
                                            pingTimeout: 0.3, health: health)
        await XCTAssertThrowsAsync { _ = try await channel.perform(operation: "systemdata.measure", arguments: [:]) }
        XCTAssertEqual(made.count, 1, "no answer is not retried on a new connection")
        XCTAssertFalse(health.answers, "Settings shows it as not responding")
        let started = Date()
        await XCTAssertThrowsAsync { _ = try await channel.perform(operation: "systemdata.measure", arguments: [:]) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "the next call fails at once")
        XCTAssertEqual(made.count, 1)
    }
}

private func XCTAssertThrowsAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await body(); XCTFail("expected an error", file: file, line: line) } catch {}
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
        XCTAssertEqual(PrivilegedHelperInstaller.permissionStatus(.enabled, answers: true), .granted)
        XCTAssertEqual(PrivilegedHelperInstaller.permissionStatus(.enabled, answers: false), .missing, "enabled for macOS, but it does not answer")
        XCTAssertEqual(PrivilegedHelperInstaller.permissionStatus(.requiresApproval), .missing)
        XCTAssertEqual(PrivilegedHelperInstaller.permissionStatus(.notRegistered), .missing)
        XCTAssertEqual(PrivilegedHelperInstaller.permissionStatus(.notFound), .unknown, "a development build without the bundled plist")
    }

    func testPingReportsWhichBinaryTheHelperStartedFromSoAnUpdateCanBeNoticed() throws {
        let service = PrivilegedHelperService(handlers: [], launchFingerprint: "100.5-2048")
        let ping = service.handle(HelperRequest(operation: PrivilegedHelperService.pingOperation), clientUID: 501)
        XCTAssertEqual(String(decoding: try XCTUnwrap(ping.payload), as: UTF8.self), "100.5-2048")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString)")
        try Data(count: 10).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let first = try XCTUnwrap(HelperFingerprint.of(path: file.path))
        try Data(count: 20).write(to: file)
        XCTAssertNotEqual(HelperFingerprint.of(path: file.path), first, "replacing the binary changes its fingerprint")
        XCTAssertNil(HelperFingerprint.of(path: "/nonexistent"))
    }

    /// Installing a new build used to unregister and register the helper, which made macOS ask for approval again every time.
    func testAReplacedHelperStepsDownInsteadOfBeingRegisteredAgain() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString)")
        try Data("old".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let launched = try XCTUnwrap(HelperFingerprint.of(path: file.path))
        XCTAssertFalse(HelperFingerprint.isStale(launched: launched, path: file.path))
        Thread.sleep(forTimeInterval: 0.01)
        try Data("new build".utf8).write(to: file)
        XCTAssertTrue(HelperFingerprint.isStale(launched: launched, path: file.path), "the app was replaced: the helper steps down")
        XCTAssertFalse(HelperFingerprint.isStale(launched: launched, path: "/nonexistent"), "an app being copied is not a reason to quit")
    }

    func testAFailedConnectionIsReplacedByANewOneOnTheNextTry() async throws {
        final class Flaky: PrivilegedChannel, @unchecked Sendable {
            let fails: Bool
            init(fails: Bool) { self.fails = fails }
            func perform(operation: String, arguments: [String: String]) async throws -> Data {
                if fails { throw PrivilegedHelperError.connection("invalidated") }
                return Data("ok".utf8)
            }
        }
        final class Made: @unchecked Sendable { var count = 0 }
        let made = Made()
        let channel = LazyPrivilegedChannel(status: { .enabled }, makeClient: { made.count += 1; return Flaky(fails: made.count == 1) })
        let data = try await channel.perform(operation: "x", arguments: [:])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok", "the retry used a fresh connection")
        XCTAssertEqual(made.count, 2)
        _ = try await channel.perform(operation: "x", arguments: [:])
        XCTAssertEqual(made.count, 2, "a working connection is kept")
    }

    func testNotFoundReasonNamesTheLikelyCause() {
        let quarantined = PrivilegedHelperInstaller.notFoundReason(bundlePath: "/Applications/MacSpace.app", quarantined: true, containsLaunchDaemon: true)
        XCTAssertTrue(quarantined.contains("xattr -dr com.apple.quarantine"))
        let translocated = PrivilegedHelperInstaller.notFoundReason(bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/MacSpace.app", quarantined: false, containsLaunchDaemon: true)
        XCTAssertTrue(translocated.contains("xattr -dr com.apple.quarantine"))
        XCTAssertTrue(PrivilegedHelperInstaller.notFoundReason(bundlePath: "/Users/x/Downloads/MacSpace.app", quarantined: false, containsLaunchDaemon: true).contains("Applications folder"))
        XCTAssertTrue(PrivilegedHelperInstaller.notFoundReason(bundlePath: "/Applications/MacSpace.app", quarantined: false, containsLaunchDaemon: false).contains("does not contain the helper"))
        XCTAssertTrue(PrivilegedHelperInstaller.notFoundReason(bundlePath: "/Applications/MacSpace.app", quarantined: false, containsLaunchDaemon: true).contains("helper --register"))
    }

    func testMachineKnowsWhetherItIsAVirtualMachine() {
        XCTAssertEqual(Machine.isVirtualMachine, sysctlValue("kern.hv_vmm_present") == 1)
    }

    private func sysctlValue(_ name: String) -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : 0
    }

    func testHelperIsInstalledOnlyFromAnApplicationsFolder() {
        XCTAssertTrue(PrivilegedHelperInstaller.isInApplicationsFolder("/Applications/MacSpace.app"))
        XCTAssertTrue(PrivilegedHelperInstaller.isInApplicationsFolder("/Users/me/Applications/MacSpace.app"))
        XCTAssertFalse(PrivilegedHelperInstaller.isInApplicationsFolder("/Users/me/Developer/macspace-releases/Build/MacSpace.app"),
                       "a helper registered from the build folder stayed tied to a copy every build replaces")
    }
}

final class ConfigurationProfilesTests: XCTestCase {
    /// The shape `system_profiler SPConfigurationProfileDataType -json` gives without root (macOS 27, 2026-10-04).
    func testFindsTheMacSpaceProfileAmongTheDeviceProfiles() throws {
        let json = """
        {"SPConfigurationProfileDataType":[
          {"_name":"User Configuration Profiles (501)","_items":[{"_name":"ManagedSettings User Settings",
            "spconfigprofile_profile_identifier":"com.apple.ManagedSettings.macOS.7BE22211"}]},
          {"_name":"spconfigprofile_section_deviceconfigprofiles","_items":[{"_name":"MacSpace: Share analytics with Apple",
            "spconfigprofile_profile_identifier":"com.macspace.policies.set-10f13ddcaa46",
            "_items":[{"_name":"com.apple.SubmitDiagInfo","spconfigprofile_payload_identifier":"com.macspace.policies.set-10f13ddcaa46.x"}]}]}
        ]}
        """
        let identifiers = try XCTUnwrap(ConfigurationProfiles.parse(Data(json.utf8)))
        XCTAssertEqual(identifiers, ["com.apple.ManagedSettings.macOS.7BE22211", "com.macspace.policies.set-10f13ddcaa46"])
        XCTAssertEqual(ConfigurationProfiles.status(identifiers), .granted)
        XCTAssertEqual(ConfigurationProfiles.status(["com.apple.ManagedSettings.macOS.7BE22211"]), .missing, "another profile is not MacSpace's")
    }

    func testAnswersFromTheLastReadingAndUnknownBeforeTheFirst() {
        let profiles = ConfigurationProfiles(read: { ["com.macspace.policies.set-1"] })
        profiles.refreshNow()
        XCTAssertEqual(profiles.status(), .granted)
        XCTAssertEqual(ConfigurationProfiles(read: { nil }).status(), .unknown)
    }

    /// This Mac, read-only: the profile check runs without root.
    func testReadsTheInstalledProfilesWithoutRoot() throws {
        XCTAssertNotNil(ConfigurationProfiles.readInstalled())
    }
}

final class CodeIntegrityTests: XCTestCase {
    func testAMissingOrUnsignedBundleIsNotIntact() throws {
        XCTAssertFalse(CodeIntegrity.isIntact(URL(fileURLWithPath: "/nonexistent/MacSpace.app")))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unsigned-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(CodeIntegrity.isIntact(folder))
    }

    func testASignedSystemAppIsIntact() {
        XCTAssertTrue(CodeIntegrity.isIntact(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
    }
}
