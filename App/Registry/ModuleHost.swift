import Foundation
import MacSpaceSdk
import MacSpacePlatform
import SwiftUI

/// Finds the installed modules and keeps them in step with the user's settings.
@MainActor
public final class ModuleHost: ObservableObject {
    @Published public private(set) var handles: [ModuleHandle] = []
    @Published public private(set) var problems: [ModuleProblem] = []

    public let settings: SettingsStore
    public let permissions: any PermissionChecker
    public let modulesDirectory: URL?
    private let loader: ModuleHandle.Loader
    private let privileged: (any PrivilegedChannel)?
    public let scheduler = BackgroundScheduler()

    /// `MACSPACE_MODULES_DIR` points a development build at another folder of modules.
    public static func defaultModulesDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = environment["MACSPACE_MODULES_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return Bundle.main.builtInPlugInsURL
    }

    /// The folder of a built app next to the command-line tool, for `macspace modules`.
    public nonisolated static func defaultModulesDirectoryForCli() -> URL {
        if let override = ProcessInfo.processInfo.environment["MACSPACE_MODULES_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return URL(fileURLWithPath: "/Applications/MACSPACE.app/Contents/PlugIns", isDirectory: true)
    }

    public init(modulesDirectory: URL? = ModuleHost.defaultModulesDirectory(), settings: SettingsStore = SettingsStore(),
                permissions: any PermissionChecker = LivePermissionChecker(), privileged: (any PrivilegedChannel)? = nil,
                loader: @escaping ModuleHandle.Loader = ModuleLoader.load) {
        self.modulesDirectory = modulesDirectory
        self.settings = settings
        self.permissions = permissions
        self.privileged = privileged
        self.loader = loader
    }

    /// Scans the modules folder and activates every enabled module.
    public func reload() async {
        guard let modulesDirectory else { handles = []; problems = []; return }
        let found = ModuleScanner.scan(directory: modulesDirectory)
        problems = found.problems
        let existing = Dictionary(uniqueKeysWithValues: handles.map { ($0.id, $0) })
        handles = found.modules.map { descriptor in
            if let known = existing[descriptor.id], known.descriptor == descriptor { return known }
            return ModuleHandle(descriptor: descriptor, settings: settings, permissions: permissions, privileged: privileged, loader: loader)
        }
        for handle in handles { await handle.activate() }
        applySchedule()
    }

    public func setEnabled(_ enabled: Bool, module id: String) async {
        settings.setEnabled(enabled, module: id)
        if let handle = handles.first(where: { $0.id == id }) { await handle.activate() }
        applySchedule()
    }

    public func setBackgroundTask(_ enabled: Bool, _ taskID: String, module id: String) {
        settings.setBackgroundTask(enabled, taskID, module: id)
        applySchedule()
    }

    public func handle(for id: String) -> ModuleHandle? { handles.first { $0.id == id } }

    public var activeHandles: [ModuleHandle] { handles.filter { $0.state == .ready } }

    func applySchedule() { scheduler.apply(handles: handles) }
}
