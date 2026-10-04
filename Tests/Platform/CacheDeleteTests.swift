import XCTest
import MacSpacePlatform

final class CacheDeleteTests: XCTestCase {
    func testItemizedPurgeableKeepsOnlyServices() {
        let result: [String: Any] = [
            "CACHE_DELETE_VOLUME": "/System/Volumes/Data", "CACHE_DELETE_TOTAL_AVAILABLE": NSNumber(value: 13_552_623_866),
            "CACHE_DELETE_NAME_MAP": ["x": "y"],
            "com.apple.mobileassetd.cache-delete": NSNumber(value: 12_388_970_746),
            "com.apple.metadata.mds.cachedelete": NSNumber(value: 12_795_904),
            "com.apple.MAIL": NSNumber(value: 0),
        ]
        let services = CacheDeleteClient.parseItemized(result)
        XCTAssertEqual(services[CacheDeleteService.mobileAsset], 12_388_970_746)
        XCTAssertEqual(services.count, 3)
        XCTAssertNil(services["CACHE_DELETE_TOTAL_AVAILABLE"])
    }

    func testPurgeResultAndFreedBytes() {
        let parsed = CacheDeleteClient.parsePurgeResult(["CACHE_DELETE_AMOUNT": NSNumber(value: 12_042_326_016),
                                                        "CACHE_DELETE_ELAPSED_TIME": NSNumber(value: 4.57)])
        XCTAssertEqual(parsed.purged, 12_042_326_016)
        XCTAssertEqual(parsed.elapsed ?? 0, 4.57, accuracy: 0.001)
        let result = CacheDeletePurgeResult(services: [CacheDeleteService.mobileAsset], purgedBytes: parsed.purged,
                                            freeBytesBefore: 118_617_763_840, freeBytesAfter: 130_660_089_856, elapsedSeconds: 4.57, error: nil)
        XCTAssertEqual(result.freedBytes, 12_042_326_016)
    }

    func testLiveQueryIsReadOnlyAndAnswers() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACSPACE_LIVE_TESTS"] == "1", "live test")
        XCTAssertNotNil(CacheDeleteClient().purgeableByService()?[CacheDeleteService.mobileAsset])
    }
}

final class CacheDeleteGateTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-cd-\(UUID().uuidString).json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: storeURL) }

    private func client(_ build: String, allowUnverified: Bool = false) -> CacheDeleteClient {
        CacheDeleteClient(build: build, allowUnverified: allowUnverified, store: CacheDeleteValidationStore(url: storeURL))
    }

    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-fake-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testUnverifiedBuildsAreRefusedUntilValidated() throws {
        let unverified = client("27A999")
        try XCTSkipIf(unverified.support == .unavailable, "CacheDelete not present")
        XCTAssertEqual(unverified.support, .unverified)
        XCTAssertNotNil(unverified.refusal)
        XCTAssertNil(unverified.purgeableByService())
        let refused = unverified.purge(services: [CacheDeleteService.mobileAsset], freeSpace: { 1 })
        XCTAssertNotNil(refused.error)
        XCTAssertNil(refused.purgedBytes)
        XCTAssertEqual(client("26B5091g").support, .validated, "validated by hand")
        XCTAssertNil(client("27A999", allowUnverified: true).refusal)
    }

    func testSelfTestInAChildProcessValidatesOrDisablesABuild() throws {
        try XCTSkipIf(client("27A999").support == .unavailable, "CacheDelete not present")
        let passing = try script(#"echo '{"build":"27A999","testedAt":"2027-01-01T00:00:00Z","queryAnswered":true,"serviceFilterHonored":true,"purgeAnswered":true,"detail":"ok"}'"#)
        let crashing = try script("kill -BUS $$")
        let otherBuild = try script(#"echo '{"build":"27A111","testedAt":"2027-01-01T00:00:00Z","queryAnswered":true,"serviceFilterHonored":true,"purgeAnswered":true,"detail":"ok"}'"#)
        defer { [passing, crashing, otherBuild].forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertEqual(client("27A999").ensureValidated(executable: passing), .validated)
        XCTAssertNil(client("27A999").refusal, "the pass is remembered for this build")
        XCTAssertEqual(client("27B100").support, .unverified, "a new build is tested again")

        let crash = client("27B100").validate(executable: crashing)
        XCTAssertFalse(crash.passed)
        XCTAssertTrue(crash.detail.contains("crashed"), crash.detail)
        XCTAssertEqual(client("27B100").support, .failedSelfTest)
        XCTAssertNotNil(client("27B100", allowUnverified: true).refusal, "a failed build stays off even when unverified calls are allowed")
        XCTAssertEqual(client("27B100").ensureValidated(executable: passing), .failedSelfTest, "not retried on the same build")

        XCTAssertFalse(client("27C200").validate(executable: otherBuild).passed, "a result for another build does not count")
    }

    func testAnEmptyAnswerIsTestedAgainButACrashIsNot() throws {
        try XCTSkipIf(client("27A999").support == .unavailable, "CacheDelete not present")
        let then = Date()
        // As recorded in a VM just after it started (26A434): both calls came back, the queries were empty.
        let empty = CacheDeleteSelfTest(build: "27D1", testedAt: then, queryAnswered: false, serviceFilterHonored: false, purgeAnswered: true,
                                        detail: "query: no valid answer; filtered query: 0 services (filter not honored); purge probe: Bad volume")
        XCTAssertTrue(empty.isRetryable)
        client("27D1").store.save(empty)
        XCTAssertEqual(client("27D1").support(now: then.addingTimeInterval(60)), .failedSelfTest, "not straight away")
        XCTAssertEqual(client("27D1").support(now: then.addingTimeInterval(11 * 60)), .unverified, "tested again a few minutes later")

        let leaking = CacheDeleteSelfTest(build: "27D2", testedAt: then, queryAnswered: true, serviceFilterHonored: false, purgeAnswered: true,
                                          detail: "filtered query: 5 services (filter not honored)", filterLeaked: true)
        XCTAssertFalse(leaking.isRetryable, "a purge would clear every service")
        XCTAssertFalse(CacheDeleteSelfTest(build: "27D3", testedAt: then, queryAnswered: false, serviceFilterHonored: false, purgeAnswered: false,
                                           detail: "self-test process crashed (signal 10)").isRetryable)
        XCTAssertFalse(CacheDeleteSelfTest(build: "27D4", testedAt: then, queryAnswered: false, serviceFilterHonored: false, purgeAnswered: true,
                                           detail: "query: no valid answer; filtered query: 3 services (filter not honored)").isRetryable,
                       "an old record whose filter answered for other services")
    }

    func testSubprocessPurgeDecodesResultsAndReportsCrashes() throws {
        let ok = try script(#"echo '{"services":["com.apple.mobileassetd.cache-delete"],"purgedBytes":42,"freeBytesBefore":1,"freeBytesAfter":43,"elapsedSeconds":1.5}'"#)
        let crash = try script("kill -BUS $$")
        let query = try script(#"echo '{"purgeableBytes":163843685}'"#)
        defer { [ok, crash, query].forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertEqual(CacheDeleteClient.purgeInSubprocess(executable: ok, freeSpace: { 1 }).purgedBytes, 42)
        let crashed = CacheDeleteClient.purgeInSubprocess(executable: crash, freeSpace: { 1 })
        XCTAssertTrue(crashed.error?.contains("crashed") == true, crashed.error ?? "")
        XCTAssertEqual(CacheDeleteClient.purgeableInSubprocess(executable: query), 163_843_685)
        XCTAssertNil(CacheDeleteClient.purgeableInSubprocess(executable: crash))
    }

    /// Runs the real self-test through the built CLI (no deletion: the purge targets a nonexistent volume).
    func testLiveSelfTestThroughTheCLI() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACSPACE_LIVE_TESTS"] == "1", "live test")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = products.appendingPathComponent("MacSpaceCli")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "MacSpaceCli not built next to the tests")
        let result = CacheDeleteClient(store: CacheDeleteValidationStore(url: storeURL)).validate(executable: cli)
        XCTAssertTrue(result.passed, result.detail)
    }
}
