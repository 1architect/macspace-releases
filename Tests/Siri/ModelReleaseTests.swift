import XCTest
import MacSpacePlatform
@testable import MacSpaceSiriPrivileged
@testable import MacSpaceSiri

/// Siri language environment where Apple Intelligence is available exactly when the Siri language matches the system's.
final class CyclingSiriEnvironment: SiriLanguageEnvironment, @unchecked Sendable {
    var system = "pt-BR"
    var siri = "en-US"
    var eligibilityReadable = true
    /// When false, eligibility never turns available (e.g. an unsupported region).
    var canBecomeEligible = true
    var writes: [String] = []
    var slept = 0.0

    func context() -> SiriLanguageContext {
        SiriLanguageContext(systemLanguage: system, siriLanguage: siri, siriEnabled: false,
                            supportedSiriLanguages: ["pt-BR", "en-US", "en-GB"], installedSiriLanguages: ["pt-BR", "en-US"])
    }
    func outputVoice() -> Data? { nil }
    func eligibilityAnswer() -> Int? {
        guard eligibilityReadable else { return nil }
        return siri == system && canBecomeEligible ? AppleIntelligenceLanguageGuard.eligibleAnswer : 2
    }
    func write(siriLanguage: String, outputVoice: Data?) throws { siri = siriLanguage; writes.append(siriLanguage) }
    func loadSavedSettings() -> SavedSiriSettings? { nil }
    func saveSettings(_ settings: SavedSiriSettings?) throws {}
    func sleep(seconds: Double) { slept += seconds }
}

final class ModelReleaseTests: XCTestCase {
    private func purgeResult(error: String? = nil) -> CacheDeletePurgeResult {
        CacheDeletePurgeResult(services: [CacheDeleteService.mobileAsset], purgedBytes: 12_042_326_016,
                               freeBytesBefore: 100, freeBytesAfter: 12_042_326_116, elapsedSeconds: 4.6, error: error)
    }

    func testReleaseCyclesTheLanguageAndPurges() {
        let environment = CyclingSiriEnvironment()
        var purged = 0
        let release = AppleIntelligenceModelRelease(environment: environment, accounts: { AppleIntelligenceAccountsReport(accounts: []) },
                                                    purge: { purged += 1; return self.purgeResult() })
        XCTAssertTrue(release.blockers().isEmpty)
        let result = release.run()
        XCTAssertNil(result.error)
        XCTAssertEqual(environment.writes, ["pt-BR", "en-US"], "available, then back to the original language")
        XCTAssertEqual(result.siriLanguageAfter, "en-US")
        XCTAssertTrue(result.eligibilityVerified)
        XCTAssertEqual(purged, 1)
        XCTAssertEqual(result.purge?.freedBytes, 12_042_326_016)
        XCTAssertEqual(result.steps.map(\.name), ["available", "eligible", "unavailable", "purged"])
    }

    func testRestoresAndDoesNotPurgeWhenAppleIntelligenceNeverBecomesAvailable() {
        let environment = CyclingSiriEnvironment()
        environment.canBecomeEligible = false
        var purged = false
        let result = AppleIntelligenceModelRelease(environment: environment, accounts: { nil }, purge: { purged = true; return self.purgeResult() }).run()
        XCTAssertNotNil(result.error)
        XCTAssertEqual(environment.siri, "en-US")
        XCTAssertFalse(purged)
    }

    func testRunsOnFixedWaitsWithoutFullDiskAccess() {
        let environment = CyclingSiriEnvironment()
        environment.eligibilityReadable = false
        let result = AppleIntelligenceModelRelease(environment: environment, accounts: { nil }, purge: { self.purgeResult() }).run()
        XCTAssertFalse(result.eligibilityVerified)
        XCTAssertEqual(environment.siri, "en-US")
        XCTAssertNotNil(result.purge)
        XCTAssertGreaterThanOrEqual(environment.slept, ModelReleaseTiming().ownershipWait + ModelReleaseTiming().releaseWait)
    }

    func testBlockers() {
        let environment = CyclingSiriEnvironment()
        environment.siri = "pt-BR"
        let accounts = AppleIntelligenceAccountsReport(accounts: [
            AppleIntelligenceAccount(guid: "B", name: "tester", isCurrentUser: false, useCases: ["x_isIFPEnabled_true_language_pt"]),
            AppleIntelligenceAccount(guid: "C", name: nil, isCurrentUser: false, useCases: ["x_isIFPEnabled_true_language_pt"]),
        ])
        let release = AppleIntelligenceModelRelease(environment: environment, accounts: { accounts }, purge: { self.purgeResult() })
        let blockers = release.blockers()
        XCTAssertEqual(blockers.count, 3)
        XCTAssertTrue(blockers[0].contains("not switched off"))
        XCTAssertTrue(blockers[1].contains("tester"))
        XCTAssertTrue(blockers[2].contains("leftovers"))
        let result = release.run()
        XCTAssertFalse(result.executed)
        XCTAssertTrue(environment.writes.isEmpty, "a blocked release changes nothing")
    }
}

final class OrphanSubscriptionTests: XCTestCase {
    let me = "2A106008-EC1C-41AD-B02F-950839090C0A"
    let gone = "DA594B82-09A5-4EE9-AD82-A5FE1448F425"

    func testPlanCountsOnlyAccountsThatNoLongerExist() {
        let rows: [[String: String]] = [
            ["k1": "com.apple.Settings.AppleIntelligence_isIFPEnabled_true_language_pt", "k4": gone],
            ["k1": "assistant.pt_BR", "k4": gone],
            ["k1": "assistant.en_US", "k4": me],
        ]
        let plan = OrphanSubscriptionCleaner.plan(databasePath: "/db", subscriptions: rows, userInformation: [["k0": gone], ["k0": me]],
                                                  existing: [me, "FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000000"], currentUser: me.lowercased())
        XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.accounts, [OrphanSubscriptionAccount(guid: gone, subscriptions: 2, appleIntelligenceUseCases: 1)])
        XCTAssertEqual(plan.rowCount, 2)
    }

    func testRefusesWithoutATrustworthyAccountList() {
        let rows: [[String: String]] = [["k1": "x", "k4": me]]
        XCTAssertNotNil(OrphanSubscriptionCleaner.plan(databasePath: "/db", subscriptions: rows, userInformation: [], existing: [], currentUser: me).refusal)
        XCTAssertNotNil(OrphanSubscriptionCleaner.plan(databasePath: "/db", subscriptions: rows, userInformation: [], existing: [gone], currentUser: me).refusal,
                        "a list without the current user is wrong")
        XCTAssertTrue(OrphanSubscriptionCleaner.isGUID(gone))
        XCTAssertFalse(OrphanSubscriptionCleaner.isGUID("x'); DROP TABLE Subscriptions; --"))
    }

    func testExecuteBacksUpRemovesAndVerifies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-uaf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("UAFAssetSubscriptions.db").path
        let setup = UAFSubscriptionDatabase.write(database, """
        CREATE TABLE Subscriptions (k0 TEXT NOT NULL, k1 TEXT NOT NULL, k2 BLOB, k3 REAL, k4 TEXT NOT NULL, k5 REAL);
        CREATE TABLE UserInformation (k0 TEXT PRIMARY KEY NOT NULL, k1 REAL, k2 TEXT NOT NULL);
        INSERT INTO Subscriptions (k0, k1, k4) VALUES ('model-catalog', 'a_isIFPEnabled_true_language_pt', '\(gone)');
        INSERT INTO Subscriptions (k0, k1, k4) VALUES ('siritts', 'voice', '\(gone)');
        INSERT INTO Subscriptions (k0, k1, k4) VALUES ('siritts', 'voice', '\(me)');
        INSERT INTO UserInformation VALUES ('\(gone)', 0, '/Local/Default');
        INSERT INTO UserInformation VALUES ('\(me)', 0, '/Local/Default');
        """)
        XCTAssertEqual(setup.status, 0, setup.message)

        let backups = directory.appendingPathComponent("backups")
        func cleaner(root: Bool) -> OrphanSubscriptionCleaner {
            OrphanSubscriptionCleaner(databasePath: database, existingGUIDs: { [self.me] }, currentUserGUID: me,
                                      backupDirectory: backups, isRoot: { root })
        }
        XCTAssertNotNil(cleaner(root: false).execute().error, "requires root")
        XCTAssertEqual(UAFSubscriptionDatabase.query(database, "SELECT count(*) AS n FROM Subscriptions;")?.first?["n"], "3")

        let result = cleaner(root: true).execute()
        XCTAssertNil(result.error)
        XCTAssertTrue(result.executed)
        XCTAssertTrue(result.restartRequired)
        XCTAssertEqual(result.remainingRows, 0)
        XCTAssertEqual(result.integrity, "ok")
        XCTAssertEqual(UAFSubscriptionDatabase.query(database, "SELECT k4 FROM Subscriptions;")?.map { $0["k4"] }, [me])
        XCTAssertEqual(UAFSubscriptionDatabase.query(database, "SELECT k0 FROM UserInformation;")?.map { $0["k0"] }, [me])
        let backup = try XCTUnwrap(result.backupPath)
        XCTAssertEqual(UAFSubscriptionDatabase.query(backup + "/UAFAssetSubscriptions.db", "SELECT count(*) AS n FROM Subscriptions;")?.first?["n"], "3")
        XCTAssertTrue(cleaner(root: true).plan()?.isEmpty == true)
    }
}

