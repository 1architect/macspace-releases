import Foundation
import MacSpaceSdk
@testable import MacSpaceApp

struct FakePermissions: PermissionChecker {
    var states: [Permission: PermissionStatus] = [:]
    func status(of permission: Permission) -> PermissionStatus { states[permission] ?? .granted }
}

final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ call: String) { lock.lock(); stored.append(call); lock.unlock() }
}

struct FakeModule: MacSpaceModule {
    var calls = Calls()

    init() {}
    init(calls: Calls) { self.calls = calls }

    func summary(context: ModuleContext) async -> ScreenWidget {
        .text(TextWidget(id: "summary", text: "summary"))
    }

    func screen(context: ModuleContext) async -> Screen {
        Screen(title: "Fake", widgets: [.text(TextWidget(id: "t", text: "flag=\(context.options.bool("flag"))"))])
    }

    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        calls.add("perform:\(request.actionID):\(request.parameters["value"] ?? "-")")
        progress(ActionProgress(fraction: 0.5, message: "half"))
        return request.actionID == "fail" ? .failed("nope") : .succeeded("done")
    }

    func runBackgroundTask(_ id: String, context: ModuleContext) async { calls.add("task:\(id)") }
}

enum Fixtures {
    static func defaults() -> UserDefaults {
        let name = "macspace-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func manifest(id: String = "com.test.fake", order: Int = 10, minimumMacOS: String? = nil, sdkVersion: Int = SdkVersion.current,
                         tasks: [BackgroundTaskDefinition] = []) -> ModuleManifest {
        ModuleManifest(id: id, name: id, summary: "s", version: "1", sdkVersion: sdkVersion, symbol: "star", minimumMacOS: minimumMacOS, order: order,
                       permissions: [.fullDiskAccess],
                       options: [OptionDefinition(id: "flag", title: "Flag", kind: .toggle(defaultValue: true))], backgroundTasks: tasks)
    }

    /// Writes a module bundle folder (manifest only) into `directory`.
    @discardableResult
    static func writeBundle(_ manifest: ModuleManifest, name: String, into directory: URL, raw: Data? = nil) throws -> URL {
        let bundle = directory.appendingPathComponent("\(name).macspacemodule")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try (raw ?? JSONEncoder().encode(manifest)).write(to: resources.appendingPathComponent("Manifest.json"))
        return bundle
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
