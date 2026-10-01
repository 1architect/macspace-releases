import Foundation
import MacSpaceSdk
import SwiftUI

/// One module as the app sees it: its manifest, whether it is running, and the latest screen it produced.
@MainActor
public final class ModuleHandle: ObservableObject, Identifiable {
    public enum State: Equatable {
        case off
        case incompatible(String)
        case failed(String)
        case ready
    }

    public typealias Loader = (ModuleDescriptor) throws -> any MacSpaceModule

    public let descriptor: ModuleDescriptor
    public nonisolated var id: String { descriptor.id }
    public var manifest: ModuleManifest { descriptor.manifest }

    @Published public private(set) var state: State
    @Published public private(set) var screen: Screen?
    @Published public private(set) var summary: ScreenWidget?
    @Published public private(set) var isBusy = false
    @Published public private(set) var progress: ActionProgress?
    @Published public private(set) var lastResult: ActionResult?

    private var module: (any MacSpaceModule)?
    private let settings: SettingsStore
    private let permissions: any PermissionChecker
    private let privileged: (any PrivilegedChannel)?
    private let loader: Loader

    public init(descriptor: ModuleDescriptor, settings: SettingsStore, permissions: any PermissionChecker,
                privileged: (any PrivilegedChannel)? = nil, loader: @escaping Loader = ModuleLoader.load) {
        self.descriptor = descriptor
        self.settings = settings
        self.permissions = permissions
        self.privileged = privileged
        self.loader = loader
        if case let .incompatible(reason) = descriptor.compatibility {
            state = .incompatible(reason)
        } else {
            state = .off
        }
    }

    public var isEnabled: Bool { settings.isEnabled(module: id) }

    public func context() -> ModuleContext {
        ModuleContext(manifest: manifest, options: settings.optionStore(for: manifest), permissions: permissions, privileged: privileged)
    }

    public func missingPermissions() -> [Permission] {
        manifest.permissions.filter { permissions.status(of: $0) == .missing }
    }

    /// Loads the module (once) when it is enabled and compatible, then fetches its summary and screen.
    public func activate() async {
        if case .incompatible = state { return }
        guard isEnabled else { deactivate(); return }
        if module == nil {
            do { module = try loader(descriptor) } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }
        state = .ready
        await refresh()
    }

    /// Drops the module's UI state. The loaded code stays in memory (bundles cannot be unloaded safely); it is simply not called.
    public func deactivate() {
        if case .incompatible = state { return }
        state = .off
        screen = nil
        summary = nil
        lastResult = nil
    }

    public func refresh() async {
        guard state == .ready, let module else { return }
        let context = context()
        isBusy = true
        async let nextSummary = module.summary(context: context)
        async let nextScreen = module.screen(context: context)
        let (newSummary, newScreen) = await (nextSummary, nextScreen)
        summary = newSummary
        screen = newScreen
        isBusy = false
    }

    /// Runs an action. Missing permissions stop it before the module is called.
    public func perform(_ action: Action, extraParameters: [String: String] = [:]) async {
        guard state == .ready, let module else { return }
        let missing = action.requires.filter { permissions.status(of: $0) == .missing }
        if !missing.isEmpty {
            lastResult = ActionResult(outcome: .needsAttention,
                                      message: "Needs \(missing.map(\.title).joined(separator: ", ")). Grant it in Settings, then try again.",
                                      refresh: false)
            return
        }
        isBusy = true
        progress = nil
        lastResult = nil
        let request = ActionRequest(actionID: action.id, parameters: action.parameters.merging(extraParameters) { _, new in new })
        let result = await module.perform(request, context: context()) { [weak self] update in
            Task { @MainActor in self?.progress = update }
        }
        progress = nil
        lastResult = result
        isBusy = false
        if result.refresh { await refresh() }
    }

    public func dismissResult() { lastResult = nil }

    /// Background tasks the user switched on, for the scheduler.
    public func enabledBackgroundTasks() -> [BackgroundTaskDefinition] {
        guard state == .ready else { return [] }
        let options = settings.optionStore(for: manifest)
        return manifest.backgroundTasks.filter { options.isBackgroundTaskEnabled($0.id) }
    }

    func runBackgroundTask(_ taskID: String) async {
        guard state == .ready, let module else { return }
        await module.runBackgroundTask(taskID, context: context())
    }
}
