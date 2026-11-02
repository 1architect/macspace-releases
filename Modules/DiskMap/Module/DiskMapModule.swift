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
    private let loader: @Sendable (DiskIndex, DiskApplications?) -> DiskApplications
    init(loader: @escaping @Sendable (DiskIndex, DiskApplications?) -> DiskApplications = DiskApplications.read) { self.loader = loader }
    private var revision: UInt64?
    private var apps: DiskApplications?
    private struct Reading { var id: UInt64; var revision: UInt64; var task: Task<DiskApplications, Never> }
    private var flight: Reading?
    private var generation: UInt64 = 0
    private var background: Task<Void, Never>?
    func browsing(_ index: DiskIndex, ready: @escaping @Sendable (DiskApplications) async -> Void) -> DiskApplications {
        let needsRead = revision != index.revision || apps.map { Date().timeIntervalSince($0.catalogReadAt) >= DiskApplications.metadataRefreshInterval } != false
        if needsRead && background == nil {
            background = Task {
                let result = await read(index)
                await ready(result)
                background = nil
            }
        }
        return apps ?? DiskApplications()
    }
    func navigation(_ index: DiskIndex) async -> DiskApplications {
        if let apps { return apps }
        return await read(index)
    }
    func read(_ index: DiskIndex) async -> DiskApplications {
        if revision == index.revision, let apps, Date().timeIntervalSince(apps.catalogReadAt) < DiskApplications.metadataRefreshInterval { return apps }
        let pending: Reading
        if let flight { pending = flight }
        else {
            let previous = apps, loader = self.loader
            generation += 1
            pending = Reading(id: generation, revision: index.revision,
                task: Task.detached(priority: .utility) { loader(index, previous) })
            flight = pending
        }
        let result = await pending.task.value
        if flight?.id == pending.id {
            apps = result; revision = pending.revision; flight = nil
        }
        if pending.revision != index.revision { return await read(index) }
        return result
    }
}
public struct DiskMapModule: MacSpaceModule {
    private let store = DiskStore()
    private let inventory = DiskInventory()
    public init() {}
    private func browsing(_ index: DiskIndex) async -> DiskApplications {
        await inventory.browsing(index) { [store] apps in await store.recordOwnership(apps) }
    }
    public func invalidate() async { await store.invalidate() }
    public func tile(context: ModuleContext) async -> Tile {
        let snapshot = await store.view(); return DiskMapScreenBuilder.tile(snapshot.index, files: snapshot.files)
    }
    public func tile(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Tile {
        let snapshot = await store.view(progress: progress); return DiskMapScreenBuilder.tile(snapshot.index, files: snapshot.files)
    }
    public func screen(context: ModuleContext) async -> Screen {
        let snapshot = await store.view()
        let apps = await browsing(snapshot.index)
        return DiskMapScreenBuilder.screen(snapshot.index, apps: apps, files: snapshot.files)
    }
    public func screen(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen {
        let snapshot = await store.view(progress: progress)
        let apps = await browsing(snapshot.index)
        return DiskMapScreenBuilder.screen(snapshot.index, apps: apps, files: snapshot.files)
    }
    public func status(context: ModuleContext) async -> (tile: Tile, screen: Screen)? {
        guard let snapshot = await store.statusView() else { return nil }
        let apps = await browsing(snapshot.index)
        return (DiskMapScreenBuilder.tile(snapshot.index, files: snapshot.files),
                DiskMapScreenBuilder.screen(snapshot.index, apps: apps, files: snapshot.files))
    }
    public func page(id: String, context: ModuleContext) async -> Screen? {
        // Navigation uses the latest completed view; reconciliation and cache writes run independently.
        let snapshot = await store.navigation(), index = snapshot.index
        if id == "other-apps" { return DiskMapScreenBuilder.otherAppsPage(await browsing(index)) }
        if id.hasPrefix("app:"), let data = Data(base64Encoded: String(id.dropFirst(4))), let path = String(data: data, encoding: .utf8),
           let app = await browsing(index).apps.first(where: { $0.owner.path == path }) { return DiskMapScreenBuilder.appDataPage(app) }
        if id == "app-data-review" { return DiskMapScreenBuilder.leftoversPage(await browsing(index)) }
        if id == "apps" { return DiskMapScreenBuilder.appsPage(index, apps: await browsing(index)) }
        if id.hasPrefix("folder:") {
            let path = String(id.dropFirst(7))
            guard index.contains(path, below: index.root), index.directories[path] != nil else { return nil }
            return DiskMapScreenBuilder.screen(index, apps: DiskApplications(), folder: path, files: snapshot.files)
        }
        if id.hasPrefix("large:") {
            let path = String(id.dropFirst(6))
            guard index.contains(path, below: index.root), index.directories[path] != nil else { return nil }
            return DiskMapScreenBuilder.allLargePage(index, folder: path, files: snapshot.files)
        }
        return nil
    }
    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        let index = await store.snapshot()
        let before = DataVolume.freeBytes()
        var result: ActionResult
        switch request.actionID {
        case "freeFiles":
            guard let folder = request.parameters["folder"],
                  let removal = DiskFileRemoval.execute(ids: Set(Selection.ids(request.parameters["ids"])), folder: folder, index: index, progress: progress) else {
                return .failed(loc("This file cannot be deleted here."))
            }
            await store.mark(removal.targets)
            result = ActionResult(outcome: removal.failures.isEmpty ? .succeeded : .needsAttention,
                                  message: removal.failures.isEmpty ? loc("Freed selected files") : loc("Some files could not be removed"), details: removal.failures)
        case "uninstall":
            let apps = await inventory.read(index)
            guard let app = apps.apps.first(where: { $0.owner.path == request.parameters["app"] && $0.owner.identifier == request.parameters["identifier"] }), app.removable else { return .failed(loc("This app cannot be uninstalled.")) }
            guard let encoded = request.parameters["plan"], let reviewed = try? JSONDecoder().decode(AppRemovalPlan.self, from: Data(encoded.utf8)),
                  reviewed.owner == app.owner, let current = app.plan,
                  reviewed.targets == current.targets else { return .failed(loc("App ownership changed. Reopen the app list and review it again.")) }
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
        let updated = await store.view()
        let apps = await inventory.read(updated.index)
        await store.recordOwnership(apps)
        result.presentation = ModulePresentation(tile: DiskMapScreenBuilder.tile(updated.index, files: updated.files), screen: DiskMapScreenBuilder.screen(updated.index, apps: apps, files: updated.files))
        return result
    }
}
