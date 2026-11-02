import AppKit
import Foundation
import MacSpaceDiskMapPrivileged
import MacSpacePlatform
import MacSpaceSdk

@objc(MacSpaceDiskMapEntry)
public final class DiskMapEntry: MacSpaceModuleEntry, @unchecked Sendable {
    public override func makeModule() -> any MacSpaceModule { DiskMapModule() }
}
private var moduleBundle: Bundle { Bundle(for: DiskMapEntry.self) }
func loc(_ value: String.LocalizationValue) -> String { String(localized: value, bundle: moduleBundle) }

actor DiskInventory {
    private var revision: UInt64?
    private var apps: DiskApplications?
    func read(_ index: DiskIndex) -> DiskApplications {
        if revision != index.revision || apps == nil { apps = DiskApplications.read(index, previous: apps); revision = index.revision }
        return apps ?? DiskApplications()
    }
}
public struct DiskMapModule: MacSpaceModule {
    private let store = DiskStore()
    private let inventory = DiskInventory()
    public init() {}
    public func invalidate() async { await store.invalidate() }
    public func tile(context: ModuleContext) async -> Tile { DiskMapScreenBuilder.tile(await store.snapshot()) }
    public func tile(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Tile { DiskMapScreenBuilder.tile(await store.snapshot(progress: progress)) }
    public func screen(context: ModuleContext) async -> Screen {
        let index = await store.snapshot()
        return DiskMapScreenBuilder.screen(index, apps: await inventory.read(index))
    }
    public func screen(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen {
        let index = await store.snapshot(progress: progress)
        return DiskMapScreenBuilder.screen(index, apps: await inventory.read(index))
    }
    public func status(context: ModuleContext) async -> (tile: Tile, screen: Screen)? {
        guard let index = await store.status() else { return nil }
        return (DiskMapScreenBuilder.tile(index), DiskMapScreenBuilder.screen(index, apps: await inventory.read(index)))
    }
    public func page(id: String, context: ModuleContext) async -> Screen? {
        let index = await store.snapshot()
        if id == "apps" { return DiskMapScreenBuilder.appsPage(index, apps: await inventory.read(index)) }
        if id.hasPrefix("folder:") {
            let path = String(id.dropFirst(7))
            guard index.contains(path, below: index.root), index.directories[path] != nil else { return nil }
            return DiskMapScreenBuilder.screen(index, apps: DiskApplications(), folder: path)
        }
        if id.hasPrefix("large:") {
            let path = String(id.dropFirst(6))
            guard index.contains(path, below: index.root), index.directories[path] != nil else { return nil }
            return DiskMapScreenBuilder.allLargePage(index, folder: path)
        }
        return nil
    }
    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        let index = await store.snapshot()
        let before = DataVolume.freeBytes()
        var result: ActionResult
        switch request.actionID {
        case "deleteFile":
            guard let path = request.parameters["path"], index.largeFiles.contains(where: { $0.path == path }), DiskMapScreenBuilder.canDelete(path) else { return .failed(loc("This file cannot be deleted here.")) }
            do { try FileManager.default.removeItem(atPath: path); await store.mark([path]); result = .succeeded(loc("Deleted")) }
            catch { return .failed(loc("Couldn’t delete the file"), details: [error.localizedDescription]) }
        case "freeLeftovers":
            let apps = await inventory.read(index)
            var failures: [String] = []
            for path in apps.leftovers.flatMap(\.paths) where AppOwnership.safeExisting(path) {
                do { try FileManager.default.removeItem(atPath: path); await store.mark([DiskApplications.measuredPath(path, index: index)], recursive: true) }
                catch { failures.append(path + ": " + error.localizedDescription) }
            }
            result = ActionResult(outcome: failures.isEmpty ? .succeeded : .needsAttention, message: failures.isEmpty ? loc("Freed app leftovers") : loc("Some app data could not be removed"), details: failures)
        case "uninstall":
            let apps = await inventory.read(index)
            guard let app = apps.apps.first(where: { $0.owner.path == request.parameters["app"] && $0.owner.identifier == request.parameters["identifier"] }), app.removable else { return .failed(loc("This app cannot be uninstalled.")) }
            guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == app.owner.identifier }) else { return .failed(loc("Quit the app before uninstalling it.")) }
            guard let helper = context.privileged else { return .failed(loc("Install the helper in Settings")) }
            do {
                progress(ActionProgress(message: loc("Uninstalling")))
                let removal = try await helper.perform(AppRemovalResult.self, operation: DiskMapPrivilegedOperations.uninstall, arguments: request.parameters)
                await store.mark((removal.removed + Array(removal.failures.keys)).map { DiskApplications.measuredPath($0, index: index) }, recursive: true)
                result = ActionResult(outcome: removal.failures.isEmpty ? .succeeded : .needsAttention, message: removal.failures.isEmpty ? loc("Uninstalled") : loc("Some app data could not be removed"), details: removal.failures.sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value })
            } catch { return .failed(loc("Couldn’t uninstall the app"), details: [error.localizedDescription]) }
        default: return .failed(loc("Unknown action"))
        }
        if let before, let after = DataVolume.settledFreeBytes() { result.freedBytes = after > before ? after - before : 0 }
        let updated = await store.snapshot()
        result.presentation = ModulePresentation(tile: DiskMapScreenBuilder.tile(updated), screen: DiskMapScreenBuilder.screen(updated, apps: await inventory.read(updated)))
        return result
    }
}
