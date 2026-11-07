import Foundation
import XCTest
import MacSpacePlatform
import MacSpaceDiskMapPrivileged
@testable import MacSpaceDiskMap

final class DiskStartupItemsTests: DiskSecurityFixtureCase {
    private func fixture(_ body: (String, AppOwner, AppCatalog) throws -> Void) throws {
        let home = "/private/tmp/startup-items-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = home + "/Applications/Example.app"
        try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "org.fixture.example", "CFBundleExecutable": "Example"] as NSDictionary).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        try Data([1]).write(to: URL(fileURLWithPath: app + "/Contents/MacOS/Example"))
        let agent = home + "/Library/LaunchAgents"
        try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
        try (["Label": "org.fixture.example.agent", "ProgramArguments": [app + "/Contents/MacOS/Example", "--background"]] as NSDictionary)
            .write(to: URL(fileURLWithPath: agent + "/example.plist"))
        try (["Label": "org.fixture.unrelated", "Program": "/bin/sh", "AssociatedBundleIdentifiers": ["org.fixture.example"]] as NSDictionary)
            .write(to: URL(fileURLWithPath: agent + "/unrelated.plist"))
        let owner = try XCTUnwrap(AppOwner(path: app))
        try body(home, owner, AppCatalog(owners: [owner]))
    }

    func testReviewIncludesOwnedStartupPlistAndKeepsUnrelatedJobs() throws {
        try fixture { home, owner, catalog in
            let resolver = OwnershipResolver(catalog: catalog)
            let full = resolver.plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary")
            let app = DiskApplication(owner: owner, bytes: 4096, dataPaths: [], removable: true,
                classification: .installedUser, ownership: resolver.claims(for: owner, home: home), plan: full)
            let plan = try XCTUnwrap(DiskUninstallBatch.plan(app))
            XCTAssertEqual(plan.startupItems?.map(\.label), ["org.fixture.example.agent"])
            XCTAssertEqual(Set(plan.targets.map(\.path)), [owner.path, home + "/Library/LaunchAgents/example.plist"])
            var removed: [String] = [], stopped = false
            let result = AppRemovalExecutor.execute(plan: plan, catalog: catalog, home: home, systemLibrary: home + "/SystemLibrary",
                stopStartup: { items in stopped = true; XCTAssertEqual(items.count, 1) }, remove: { path in
                    XCTAssertTrue(stopped); removed.append(path)
                })
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertEqual(removed.last, owner.path)
            XCTAssertFalse(removed.contains { $0.hasSuffix("unrelated.plist") })
            var missing = plan; missing.targets.removeAll { $0.evidence.source == "startupItem" }
            XCTAssertNotNil(AppRemovalExecutor.validate(plan: missing, catalog: catalog, home: home, systemLibrary: home + "/SystemLibrary"))
            XCTAssertTrue(DiskLoginItems.belongs(owner.path, to: owner))
            XCTAssertTrue(DiskLoginItems.belongs(owner.path + "/Contents/Library/LoginItems/Helper.app", to: owner))
            XCTAssertFalse(DiskLoginItems.belongs(owner.path + " Copy", to: owner))
        }
    }

    func testStartupFailureAndChangedPlistPreserveEveryRemovalTarget() throws {
        try fixture { home, owner, catalog in
            let plan = OwnershipResolver(catalog: catalog).plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary")
            var removed: [String] = []
            let failed = AppRemovalExecutor.execute(plan: plan, catalog: catalog, home: home, systemLibrary: home + "/SystemLibrary",
                stopStartup: { _ in throw CocoaError(.fileWriteNoPermission) }, remove: { removed.append($0) })
            XCTAssertFalse(failed.failures.isEmpty); XCTAssertTrue(removed.isEmpty)
            try Data([1, 2, 3]).write(to: URL(fileURLWithPath: home + "/Library/LaunchAgents/example.plist"))
            XCTAssertNotNil(AppRemovalExecutor.validate(plan: plan, catalog: catalog, home: home, systemLibrary: home + "/SystemLibrary"))
        }
    }

    func testEmbeddedAgentsDaemonsAndLoginHelpersAreIncludedWithoutOverlappingTargets() throws {
        try fixture { home, owner, catalog in
            for kind in ["LaunchAgents", "LaunchDaemons"] {
                let root = owner.path + "/Contents/Library/" + kind
                try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
                try (["Label": "org.fixture.example." + kind, "BundleProgram": "Contents/MacOS/Example"] as NSDictionary)
                    .write(to: URL(fileURLWithPath: root + "/job.plist"))
            }
            let helper = owner.path + "/Contents/Library/LoginItems/Helper.app/Contents"
            try FileManager.default.createDirectory(atPath: helper + "/MacOS", withIntermediateDirectories: true)
            try (["CFBundleIdentifier": "org.fixture.example.login", "CFBundleExecutable": "Helper"] as NSDictionary)
                .write(to: URL(fileURLWithPath: helper + "/Info.plist"))
            try Data([1]).write(to: URL(fileURLWithPath: helper + "/MacOS/Helper"))
            let plan = OwnershipResolver(catalog: catalog).plan(for: owner, home: home, systemLibrary: home + "/SystemLibrary")
            XCTAssertEqual(plan.startupItems?.count, 4)
            XCTAssertEqual(plan.startupItems?.filter(\.system).count, 1)
            XCTAssertEqual(plan.targets.count, 2, "Embedded startup files are already covered by their app bundle")
            XCTAssertNil(AppRemovalExecutor.validate(plan: plan, catalog: catalog, home: home, systemLibrary: home + "/SystemLibrary"))
        }
    }

    private final class Runner: CommandRunning, @unchecked Sendable {
        var calls: [[String]] = []
        var program: String?
        var absent = false
        func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
            calls.append(arguments)
            if arguments.first == "print" {
                return CommandResult(stdout: Data(("\tprogram = " + (program ?? "/unrelated") + "\n").utf8), stderr: Data(), exitCode: absent ? 113 : 0)
            }
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }
    }

    func testStopVerifiesLoadedExecutableAndUsesTheCallingUsersDomains() throws {
        try fixture { home, owner, catalog in
            let items = AppStartupItems.discover(owner: owner, catalog: catalog, home: home, systemLibrary: home + "/SystemLibrary")
            let runner = Runner()
            XCTAssertThrowsError(try AppStartupItems.stop(items, uid: 502, runner: runner))
            XCTAssertFalse(runner.calls.contains { $0.first == "bootout" })
            runner.calls = []; runner.program = items.first?.executable
            try AppStartupItems.stop(items, uid: 502, runner: runner)
            XCTAssertEqual(runner.calls.filter { $0.first == "bootout" }.map { $0[1] },
                           ["gui/502/org.fixture.example.agent", "user/502/org.fixture.example.agent"])
            runner.calls = []; runner.absent = true
            try AppStartupItems.stop(items, uid: 502, runner: runner)
            XCTAssertFalse(runner.calls.contains { $0.first == "bootout" })
        }
    }
}
