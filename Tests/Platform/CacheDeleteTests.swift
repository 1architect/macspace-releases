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

final class CacheDeleteSubprocessTests: XCTestCase {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-cd-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testAnyBuildIsAllowedWhereTheFunctionsExist() throws {
        let client = CacheDeleteClient(build: "27Z999")
        try XCTSkipIf(client.support == .unavailable, "CacheDelete not present")
        XCTAssertEqual(client.support, .available, "no build is gated")
        XCTAssertNil(client.refusal)
    }

    func testSubprocessPurgeDecodesResultsAndReportsCrashes() throws {
        let ok = try script(#"echo '{"services":["com.apple.mobileassetd.cache-delete"],"purgedBytes":42,"freeBytesBefore":1,"freeBytesAfter":43,"elapsedSeconds":1.5}'"#)
        let crash = try script("kill -BUS $$")
        let query = try script(#"echo '{"purgeableBytes":163843685}'"#)
        let refused = try script(#"echo '{"error":"CacheDelete is not available on this system."}'; exit 1"#)
        defer { [ok, crash, query, refused].forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertEqual(CacheDeleteClient.purgeInSubprocess(executable: ok, freeSpace: { 1 }).purgedBytes, 42)
        let crashed = CacheDeleteClient.purgeInSubprocess(executable: crash, freeSpace: { 1 })
        XCTAssertTrue(crashed.error?.contains("crashed") == true, crashed.error ?? "")
        XCTAssertEqual(CacheDeleteClient.purgeableInSubprocess(executable: query), 163_843_685)
        XCTAssertNil(CacheDeleteClient.purgeableInSubprocess(executable: crash))
        XCTAssertNil(CacheDeleteClient.purgeableByServiceInSubprocess(executable: refused), "a refusal is not read as an empty answer")
    }

    /// Runs the real self-test through the built CLI (no deletion: the purge targets a nonexistent volume).
    func testLiveSelfTestThroughTheCLI() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACSPACE_LIVE_TESTS"] == "1", "live test")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = products.appendingPathComponent("MacSpaceCli")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "MacSpaceCli not built next to the tests")
        let process = Process()
        process.executableURL = cli
        process.arguments = ["purge-assets", "--self-test"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
