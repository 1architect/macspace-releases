import XCTest
import MacSpacePlatform
@testable import MacSpaceDebloatPrivileged
import MacSpacePlatform

final class DebloatParserTests: XCTestCase {
    func testProcessListKeepsPathsWithSpaces() {
        let text = """
          1291     1   501 158784    01:02:03 /System/Applications/Siri AI.app/Contents/MacOS/Siri AI
           553     1     0   2048 2-03:04:05 /usr/libexec/configd
        garbage line
        """
        let processes = ProcessListParser.parse(text)
        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].executable, "/System/Applications/Siri AI.app/Contents/MacOS/Siri AI")
        XCTAssertEqual(processes[0].residentBytes, 158784 * 1024)
        XCTAssertEqual(processes[0].elapsedSeconds, 3723)
        XCTAssertEqual(processes[0].name, "Siri AI")
        XCTAssertEqual(processes[1].elapsedSeconds, 2 * 86400 + 3 * 3600 + 4 * 60 + 5)
        XCTAssertEqual(ProcessListParser.elapsedSeconds("05:09"), 309)
        XCTAssertNil(ProcessListParser.elapsedSeconds("x:1"))
    }

    func testLaunchdOverrides() {
        let text = """
        	disabled services = {
        		"com.apple.Siri.agent" => disabled
        		"com.ollama.ollama" => enabled
        		"com.legacy" => true
        	}
        	login item associations = {
        	}
        """
        XCTAssertEqual(LaunchdOverrideParser.parse(text), ["com.apple.Siri.agent": true, "com.ollama.ollama": false, "com.legacy": true])
    }

    func testLaunchdPlistParsing() throws {
        let plist: [String: Any] = [
            "Label": "com.apple.campo",
            "ProgramArguments": ["/System/Applications/Siri AI.app/Contents/MacOS/Siri AI"],
            "Disabled": ["#IfFeatureFlagDisabled": "IntelligenceFlow/Campo", "#Then": true],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let job = try XCTUnwrap(LaunchdJobIndex.parse(plist: data, path: "/x.plist", domain: .gui))
        XCTAssertEqual(job.program, "/System/Applications/Siri AI.app/Contents/MacOS/Siri AI")
        XCTAssertTrue(job.conditionallyDisabled)
        XCTAssertNil(job.disabledByDefault)
        let index = LaunchdJobIndex(jobs: [job])
        XCTAssertEqual(index.jobs(forProgram: job.program!).map(\.label), ["com.apple.campo"])
        XCTAssertNil(index.job(.system, "com.apple.campo"))
    }

    func testDiagnosticHistory() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let plist: [String: Any] = ["AutoSubmit": false, "SeedAutoSubmit": true, "ThirdPartyDataSubmit": false, "LastFullSubmissionSuccess": date]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let history = try XCTUnwrap(DiagnosticSubmissionHistory.parse(data))
        XCTAssertEqual(history.autoSubmit, false)
        XCTAssertEqual(history.seedAutoSubmit, true)
        XCTAssertEqual(history.lastFullSubmissionSuccess, date)
        XCTAssertNil(history.lastFullSubmissionCalled)
    }

    func testEnvironmentParsing() {
        XCTAssertEqual(LiveDebloatSystem.isPrerelease(build: "26B5091g", seedAutoSubmit: nil), true)
        XCTAssertEqual(LiveDebloatSystem.isPrerelease(build: "25A354", seedAutoSubmit: nil), false)
        XCTAssertEqual(LiveDebloatSystem.isPrerelease(build: "22E772610a", seedAutoSubmit: nil), false, "Rapid Security Response")
        XCTAssertEqual(LiveDebloatSystem.isPrerelease(build: "25A354", seedAutoSubmit: true), true)
        XCTAssertNil(LiveDebloatSystem.isPrerelease(build: nil, seedAutoSubmit: nil))
        XCTAssertEqual(LiveDebloatSystem.parseSIP("System Integrity Protection status: disabled."), .disabled)
        XCTAssertEqual(LiveDebloatSystem.parseSIP("System Integrity Protection status: enabled."), .enabled)
        XCTAssertEqual(LiveDebloatSystem.parseSIP("System Integrity Protection status: unknown (Custom Configuration)."), .custom)
        XCTAssertEqual(LiveDebloatSystem.parseSIP(nil), .unknown)
        let enrollment = "Enrolled via DEP: No\nMDM enrollment: Yes (User Approved)\n"
        XCTAssertEqual(LiveDebloatSystem.parseEnrollment(enrollment, prefix: "MDM enrollment:"), true)
        XCTAssertEqual(LiveDebloatSystem.parseEnrollment(enrollment, prefix: "Enrolled via DEP:"), false)
    }

    func testLiveCommandsForDisplay() {
        let system = LiveDebloatSystem(runner: ProcessCommandRunner(), targetUser: DebloatTargetUser(name: "t", uid: 501, home: URL(fileURLWithPath: "/tmp")))
        let host = ControlSetting.preference(.currentHost, "com.example", "Key", desired: .int(2), fallback: .absent)
        XCTAssertEqual(system.command(for: host, value: .value(.int(2))), ["/usr/bin/defaults", "-currentHost", "write", "com.example", "Key", "-int", "2"])
        XCTAssertEqual(system.command(for: host, value: .absent), ["/usr/bin/defaults", "-currentHost", "delete", "com.example", "Key"])
        XCTAssertEqual(system.command(for: .service(.gui, "com.apple.campo"), value: .launchdOverride(disabled: true)),
                       ["/bin/launchctl", "disable", "gui/501/com.apple.campo"])
        XCTAssertEqual(system.command(for: .service(.system, "com.apple.analyticsd"), value: .launchdOverride(disabled: false)),
                       ["/bin/launchctl", "enable", "system/com.apple.analyticsd"])
    }
}

final class DebloatValueCodingTests: XCTestCase {
    func testSettingValuesRoundTrip() throws {
        let values: [SettingValue] = [.absent, .value(.bool(false)), .value(.int(2)), .value(.string("x")), .launchdOverride(disabled: true)]
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode([SettingValue].self, from: data), values)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""kind":"launchdOverride""#))
    }

    func testPlistValueFromPropertyList() {
        XCTAssertEqual(PlistValue(propertyList: NSNumber(value: true)), .bool(true))
        XCTAssertEqual(PlistValue(propertyList: NSNumber(value: 2)), .int(2))
        XCTAssertEqual(PlistValue(propertyList: "a"), .string("a"))
        XCTAssertNil(PlistValue(propertyList: NSNumber(value: 1.5)))
        XCTAssertNil(PlistValue(propertyList: Date()))
        XCTAssertTrue(PlistValue.bool(true).matches(.int(1)))
        XCTAssertFalse(PlistValue.bool(true).matches(.int(2)))
    }
}

final class DebloatCatalogTests: XCTestCase {
    func testCatalogIntegrity() {
        let controls = DebloatCatalog.controls
        XCTAssertEqual(Set(controls.map(\.id)).count, controls.count, "control ids are unique")
        let settingIDs = controls.flatMap { $0.settings.map(\.id) }
        XCTAssertEqual(Set(settingIDs).count, settingIDs.count, "a setting belongs to one control, so journal entries are unambiguous")
        for control in controls {
            XCTAssertFalse(control.title.isEmpty, control.id)
            XCTAssertTrue(control.id.hasPrefix(control.id.split(separator: ".")[0] + "."), control.id)
            if control.mechanism == .privateSurface {
                XCTAssertNotNil(control.applyCommand, control.id)
                XCTAssertTrue(control.settings.isEmpty, control.id)
            } else {
                XCTAssertFalse(control.settings.isEmpty, control.id)
            }
            let expectedKind: ControlSetting.Kind? = [.launchdOverride: .launchdService, .featureFlag: .featureFlag,
                                                       .configurationProfile: .managedPreference, .systemTool: .systemTool][control.mechanism]
            if let expectedKind { XCTAssertTrue(control.settings.allSatisfy { $0.kind == expectedKind }, control.id) }
            XCTAssertFalse(control.settings.contains { $0.kind == .managedPreference } && control.mechanism != .configurationProfile, control.id)
            for setting in control.settings {
                if let preference = setting.preference, let fallback = preference.fallback {
                    XCTAssertFalse(fallback.matches(setting.desiredValue), "\(setting.id) fallback equals the debloated value")
                }
                if let service = setting.launchd { XCTAssertTrue(service.label.hasPrefix("com.apple."), setting.id) }
            }
        }
    }

    func testTheCatalogShipsOnlyControlsThatWork() {
        XCTAssertEqual(DebloatCatalog.controls.count, 15)
        for control in DebloatCatalog.controls {
            XCTAssertNil(control.replacedBy, control.id)
            XCTAssertNotEqual(control.mechanism, .privateSurface, "Apple Intelligence itself belongs to the Siri module")
            XCTAssertTrue(control.ineffectiveWithSIPBuilds.isEmpty, control.id)
        }
        // launchd overrides other than the RemovableServices ones are cleared at boot with SIP on, so none are shipped.
        let launchdControls = DebloatCatalog.controls.filter { $0.mechanism == .launchdOverride }.map(\.id)
        XCTAssertEqual(launchdControls, ["diagnostics.crash-reporter"])
    }

    func testAnalyticsUseTheSettingOnReleaseBuildsAndTheProfileOnBetas() throws {
        var environment = DebloatEnvironment(productVersion: "27.0", build: "26A434", isPrerelease: false, sip: .enabled, mdmEnrolled: false,
                                             depEnrolled: false, architecture: "arm64", userName: "u", uid: 501, runningAsRoot: false, fullDiskAccess: true)
        func offered() -> [String] { DebloatCatalog.controls.filter { $0.isOffered(in: environment) }.map(\.id).filter { $0.hasPrefix("telemetry.diagnostics") } }
        XCTAssertEqual(offered(), ["telemetry.diagnostics"], "a release build asks for no profile")
        XCTAssertEqual(try XCTUnwrap(DebloatCatalog.control("telemetry.diagnostics")).mechanism, .systemPreference)
        environment.isPrerelease = true
        XCTAssertEqual(offered(), ["telemetry.diagnostics-policy"], "a beta submits whatever the setting says; only the profile stops it")
        environment.isPrerelease = nil
        XCTAssertEqual(offered(), ["telemetry.diagnostics"], "an unknown build counts as a release")
        XCTAssertEqual(DebloatCatalog.controls.filter { $0.isOffered(in: environment) }.count, 14)
    }

    func testRestrictionKeysExistOnThisBuild() throws {
        // The catalog targets macOS 27; older hosts (the macOS 15 CI runner) lack keys such as allowImageWand.
        try XCTSkipUnless(LiveDebloatSystem.systemFeatureExists(domain: "IntelligenceFlow", feature: "Campo"), "host predates macOS 27")
        let path = "/System/Library/PrivateFrameworks/ManagedConfiguration.framework/defaultSettings.plist"
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path) ?? nil, "no ManagedConfiguration defaults on this host")
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        let known = Set(((root["restrictedBool"] as? [String: Any]) ?? [:]).keys)
        for control in DebloatCatalog.controls {
            for managed in control.settings.compactMap(\.managed) where managed.payloadType == "com.apple.applicationaccess" {
                XCTAssertTrue(known.contains(managed.key), "\(control.id): \(managed.key)")
            }
        }
    }

    func testOnlyMeasuredControlsClaimValidation() {
        let validated = DebloatCatalog.controls.filter { !$0.validatedBuilds.isEmpty }.map(\.id)
        XCTAssertEqual(validated, ["telemetry.diagnostics-policy", "siri.siri-ai-flag", "ai.visual-intelligence",
                                   "ai.generative-indexing", "diagnostics.tailspin", "diagnostics.crash-reporter"])
    }
}
