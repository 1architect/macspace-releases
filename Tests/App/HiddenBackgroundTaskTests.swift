import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

final class HiddenBackgroundTaskTests: XCTestCase {
    /// A hidden task is the module's decision: a stored choice from when it had a switch no longer stops it.
    func testHiddenTaskFollowsItsDefaultWhateverWasStored() {
        var manifest = ModuleManifest(id: "test.hidden", name: "Test", summary: "", version: "1", symbol: "star")
        manifest.backgroundTasks = [BackgroundTaskDefinition(id: "watch", title: "Watch", defaultEnabled: true, intervalSeconds: 900, hidden: true),
                                    BackgroundTaskDefinition(id: "free", title: "Free", defaultEnabled: true, intervalSeconds: 300)]
        let settings = SettingsStore(defaults: Fixtures.defaults())
        settings.setBackgroundTask(false, "watch", module: manifest.id)
        settings.setBackgroundTask(false, "free", module: manifest.id)
        let options = settings.optionStore(for: manifest)
        XCTAssertTrue(options.isBackgroundTaskEnabled("watch"))
        XCTAssertFalse(options.isBackgroundTaskEnabled("free"), "a task with a switch keeps the user's choice")
    }
}
