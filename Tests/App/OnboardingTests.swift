import SwiftUI
import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

final class OnboardingTests: XCTestCase {
    /// No welcome: a permission only while it is missing, unless it is the step the user was on (coming back to it after the
    /// relaunch System Settings asks for, the screen shows it arrive), then the end.
    func testFlowLeavesOutWhatIsAlreadyGranted() {
        XCTAssertEqual(Onboarding.flow(fullDiskAccess: .missing, helper: .requiresApproval, notifications: .notDetermined, current: .ready),
                       [.fullDiskAccess, .helper, .notifications, .ready])
        XCTAssertEqual(Onboarding.flow(fullDiskAccess: .granted, helper: .enabled, notifications: .authorized, current: .ready),
                       [.ready], "nothing to ask: onboarding ends at once")
        XCTAssertEqual(Onboarding.flow(fullDiskAccess: .granted, helper: .requiresApproval, notifications: .denied, current: .fullDiskAccess),
                       [.fullDiskAccess, .helper, .ready])
    }

    /// Someone who used MacSpace before onboarding existed does not get it.
    @MainActor
    func testOnlyANewInstallGetsOnboarding() {
        let fresh = Fixtures.defaults()
        XCTAssertFalse(Onboarding.usedBefore(fresh))
        XCTAssertTrue(Onboarding(defaults: fresh, arguments: []).isShowing)

        let used = Fixtures.defaults()
        used.set(Data(), forKey: "module.com.macspace.system-data.lastTile")
        XCTAssertTrue(Onboarding.usedBefore(used))
        XCTAssertFalse(Onboarding(defaults: used, arguments: []).isShowing)
        XCTAssertTrue(Onboarding(defaults: used, arguments: ["--onboarding"]).isShowing, "--onboarding shows it again")
    }
}

/// Draws every step at the window's default size; with MACSPACE_SNAPSHOT_DIR set it writes them as PNGs for a visual check.
@MainActor
final class OnboardingRenderTests: XCTestCase {
    func testEveryStepRenders() throws {
        let host = ModuleHost(modulesDirectory: nil, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions())
        for step in Onboarding.Step.allCases {
            let onboarding = Onboarding(defaults: Fixtures.defaults(), arguments: ["--onboarding"])
            onboarding.go(to: step)
            let view = OnboardingView(onboarding: onboarding, host: host).frame(width: 678, height: 468)
                .environment(\.colorScheme, .dark).environment(\.design, DesignSettings.shared.design)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let bitmap = try XCTUnwrap(renderer.cgImage)
            guard let directory = ProcessInfo.processInfo.environment["MACSPACE_SNAPSHOT_DIR"] else { continue }
            try XCTUnwrap(NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("onboarding-\(step.rawValue).png"))
        }
    }
}
