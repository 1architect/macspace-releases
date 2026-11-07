import XCTest
import MacSpacePlatform

/// While Apple Intelligence is on, MacSpace never asks macOS to delete system assets: its models download and update through them.
final class SystemAssetGuardTests: XCTestCase {
    private var availability: (@Sendable () -> Bool?)!

    override func setUp() { availability = SystemAssetGuard.appleIntelligenceAvailable }
    override func tearDown() { SystemAssetGuard.appleIntelligenceAvailable = availability }

    private func eligibility(_ answer: Int) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["OS_ELIGIBILITY_DOMAIN_SIRI_MODE": ["os_eligibility_answer_t": answer]],
                                           format: .xml, options: 0)
    }

    func testMacOSsEligibilityAnswerSaysWhetherAppleIntelligenceIsAvailable() throws {
        XCTAssertEqual(SystemAssetGuard.available(inEligibility: try eligibility(4)), true)
        XCTAssertEqual(SystemAssetGuard.available(inEligibility: try eligibility(2)), false)
        XCTAssertNil(SystemAssetGuard.available(inEligibility: Data("not a plist".utf8)))
        for answer in [0, 1, 3, 5, -1] {
            XCTAssertNil(SystemAssetGuard.available(inEligibility: try eligibility(answer)))
        }
    }

    /// Unknown eligibility holds system assets without holding unrelated purge services.
    func testOnlySystemAssetsAreHeldAndOnlyWhileAppleIntelligenceIsOn() {
        SystemAssetGuard.appleIntelligenceAvailable = { true }
        XCTAssertNotNil(SystemAssetGuard.refusal([CacheDeleteService.mobileAsset]))
        XCTAssertNil(SystemAssetGuard.refusal([CacheDeleteService.fsPurgeableData]), "the apps' purgeable files are not its models")
        SystemAssetGuard.appleIntelligenceAvailable = { false }
        XCTAssertNil(SystemAssetGuard.refusal([CacheDeleteService.mobileAsset]), "switched off: releasing its models is the point")
        SystemAssetGuard.appleIntelligenceAvailable = { nil }
        XCTAssertEqual(SystemAssetGuard.refusal([CacheDeleteService.mobileAsset]), SystemAssetGuard.unknownMessage)
        XCTAssertEqual(SystemAssetGuard.refusal([CacheDeleteService.mobileAsset], featureCleanup: true), SystemAssetGuard.unknownMessage)
        XCTAssertNil(SystemAssetGuard.refusal([CacheDeleteService.fsPurgeableData]))
    }

    /// Every way to purge them stops: the purge itself, the one in the CLI's process, and a cleanup, which says why.
    func testEveryPurgeOfSystemAssetsStopsWhileAppleIntelligenceIsOn() throws {
        SystemAssetGuard.appleIntelligenceAvailable = { true }
        let direct = CacheDeleteClient().purge(services: [CacheDeleteService.mobileAsset], freeSpace: { 1 })
        XCTAssertEqual(direct.error, SystemAssetGuard.heldMessage)
        XCTAssertNil(direct.purgedBytes)
        // The CLI is never started: a script that would answer a purge is not run.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-guard-\(UUID().uuidString)")
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-guard-\(UUID().uuidString).sh")
        try "#!/bin/sh\ntouch \(marker.path)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertEqual(CacheDeleteClient.purgeInSubprocess(executable: script, freeSpace: { 1 }).error, SystemAssetGuard.heldMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let retrier = PurgeRetrier()
        let outcome = PurgeRun(service: CacheDeleteService.mobileAsset, retrier: retrier).run()
        XCTAssertTrue(outcome.held)
        XCTAssertFalse(retrier.isRetrying(CacheDeleteService.mobileAsset), "nothing is asked again in the background")
        let result = PurgeRun.result(outcome, what: "unused system assets")
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(result.message, PurgeRun.heldMessage)
    }

    func testUnknownEligibilityStopsAllEntryPointsBeforeMutation() {
        SystemAssetGuard.appleIntelligenceAvailable = { nil }
        let direct = CacheDeleteClient().purge(services: [CacheDeleteService.mobileAsset], freeSpace: { 1 })
        XCTAssertNotNil(direct.error)
        XCTAssertNil(direct.purgedBytes)
        let child = CacheDeleteClient.purgeInSubprocess(executable: URL(fileURLWithPath: "/not-an-executable"),
                                                       featureCleanup: true, freeSpace: { 1 })
        XCTAssertEqual(child.error, SystemAssetGuard.unknownMessage)
        let retrier = PurgeRetrier()
        let outcome = PurgeRun(service: CacheDeleteService.mobileAsset, retrier: retrier, featureCleanup: true).run()
        XCTAssertTrue(outcome.held)
        XCTAssertNil(outcome.estimate)
        XCTAssertEqual(outcome.error, SystemAssetGuard.unknownMessage)
        XCTAssertEqual(PurgeRun.result(outcome, what: "system assets").outcome, .failed)
        XCTAssertFalse(retrier.isRetrying(CacheDeleteService.mobileAsset))
    }

    func testUnknownEligibilityStopsBackgroundRequests() async {
        SystemAssetGuard.appleIntelligenceAvailable = { nil }
        let retrier = PurgeRetrier()
        retrier.schedule(service: CacheDeleteService.mobileAsset, urgency: 1, delays: [0.01], purge: {
            XCTFail("Unknown eligibility must stop the retry before calling purge")
            return CacheDeletePurgeResult(services: [], purgedBytes: 0, freeBytesBefore: 0, freeBytesAfter: 0, elapsedSeconds: 0, error: nil)
        }) { _ in XCTFail("No purge was submitted") }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(retrier.isRetrying(CacheDeleteService.mobileAsset))
    }

    /// Apple Intelligence came on while MacSpace was asking again in the background: it stops asking, and records nothing as kept.
    func testBackgroundRequestsStopWhenAppleIntelligenceComesOn() async {
        SystemAssetGuard.appleIntelligenceAvailable = { true }
        final class Attempts: @unchecked Sendable { var n = 0 }
        let attempts = Attempts()
        let retrier = PurgeRetrier()
        retrier.schedule(service: CacheDeleteService.mobileAsset, urgency: 1, delays: [0.02, 0.02], purge: {
            attempts.n += 1
            return CacheDeletePurgeResult(services: [], purgedBytes: 0, freeBytesBefore: 0, freeBytesAfter: 0, elapsedSeconds: 0, error: nil)
        }) { _ in XCTFail("not told anything: nothing was refused by macOS") }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(attempts.n, 0)
        XCTAssertFalse(retrier.isRetrying(CacheDeleteService.mobileAsset))
    }
}

extension SystemAssetGuardTests {
    func testMalformedButParseableEligibilityRefusesAtBothEntryPoints() throws {
        for value: Any in [true, false, 4.9, 2.5, 4.0, "4", UInt64.max, [4]] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["OS_ELIGIBILITY_DOMAIN_SIRI_MODE": ["os_eligibility_answer_t": value]], format: .xml, options: 0)
            XCTAssertNil(SystemAssetGuard.available(inEligibility: data))
            XCTAssertNil(SystemAssetGuard.reviewedAvailability(inEligibility: data))
        }
    }
}
