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

private final class DiskRemovalBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var finished: Set<String> = []
    func record(_ ids: [String]) { lock.withLock { finished.formUnion(ids) } }
    var ids: Set<String> { lock.withLock { finished } }
}

actor DiskInventory {
    private let loader: @Sendable (DiskIndex, DiskApplications?) -> DiskApplications
    private let receiptCacheURL: URL?
    private var receiptCacheLoaded = false
    private var savedReceipts: AppReceiptCatalog?
    init(receiptCache: URL? = nil, loader: @escaping @Sendable (DiskIndex, DiskApplications?) -> DiskApplications = DiskApplications.read) {
        self.loader = loader; receiptCacheURL = receiptCache
    }
    private var revision: UInt64?
    private var apps: DiskApplications?
    private struct Reading { var id: UInt64; var revision: UInt64; var task: Task<DiskApplications, Never> }
    private var flight: Reading?
    private var generation: UInt64 = 0
    func browsing(_ index: DiskIndex, ready: @escaping @Sendable (DiskApplications) async -> Void) async -> DiskApplications {
        let result = await read(index)
        if active { await ready(result) }
        return result
    }
    private var active = true
    func setActive(_ value: Bool) { active = value; if !value { flight?.task.cancel(); flight = nil } }
    func invalidate() { revision = nil; apps?.catalogRevision = nil }
    func passive() -> DiskApplications { apps ?? DiskApplications() }
    func navigation(_ index: DiskIndex) async -> DiskApplications { await read(index) }
    func measurements(_ value: DiskApplications, index: DiskIndex) -> DiskApplications {
        let measured = value.remeasured(index)
        if revision == index.revision, apps?.catalogReadAt == value.catalogReadAt { apps = measured }
        return measured
    }
    func read(_ index: DiskIndex, force: Bool = false) async -> DiskApplications {
        guard active else { return apps ?? DiskApplications() }
        if force, let pending = flight {
            let result = await pending.task.value
            if flight?.id == pending.id { apps = result; revision = pending.revision; flight = nil }
        }
        if !force, revision == index.revision, let apps { return apps }
        let pending: Reading
        if let flight { pending = flight }
        else {
            var previous = force ? nil : apps
            if !receiptCacheLoaded {
                savedReceipts = receiptCacheURL.flatMap { DiskReceiptCache.read($0) }
                receiptCacheLoaded = true
            }
            if !force, previous == nil, index.catalogRevision != nil, let savedReceipts {
                var seed = DiskApplications()
                // Historical manifests are reused only after the adapter validates current plist/BOM stamps.
                // No app signatures, classifications, ownership decisions or removal plans are cached here.
                seed.receipts = savedReceipts
                previous = seed
            }
            let loader = self.loader, previousForRead = previous
            generation += 1
            pending = Reading(id: generation, revision: index.revision,
                task: Task.detached(priority: .utility) { autoreleasepool { loader(index, previousForRead) } })
            flight = pending
        }
        let result = await pending.task.value
        guard active, !pending.task.isCancelled else { return apps ?? result }
        if flight?.id == pending.id {
            apps = result; revision = pending.revision; flight = nil
            if result.receipts != savedReceipts, let receiptCacheURL {
                DiskReceiptCache.save(result.receipts, to: receiptCacheURL)
                savedReceipts = result.receipts
            }
        }
        if pending.revision != index.revision { return await read(index) }
        return result
    }
}
public struct DiskMapModule: MacSpaceModule {
    private let store: DiskStore
    private let inventory: DiskInventory
    public init() {
        let store = DiskStore()
        self.store = store; inventory = DiskInventory(receiptCache: store.receiptCacheURL)
    }
    init(store: DiskStore, inventory: DiskInventory? = nil) {
        self.store = store
        self.inventory = inventory ?? DiskInventory(receiptCache: store.receiptCacheURL)
    }
    private func browsing(_ index: DiskIndex) async -> DiskApplications {
        let start = Date()
        let apps = await inventory.browsing(index) { [store] apps in await store.recordOwnership(apps) }
        DiskScanMetrics.phase("application-inventory-and-ownership", since: start)
        let accountingStarted = Date()
        let measured = await inventory.measurements(apps, index: store.navigation().index)
        DiskScanMetrics.phase("application-allocation-reconciliation", since: accountingStarted)
        return measured
    }
    public func setActive(_ active: Bool) async { await store.setActive(active); await inventory.setActive(active) }
    public func invalidate() async { await inventory.invalidate(); await store.invalidate() }
    public func invalidate(pageID: String?, context: ModuleContext) async {
        if let id = pageID, let request = DiskBrowseRequest(id: id.hasPrefix("focus:") ? String(id.dropFirst(6)) : id) {
            await store.mark([request.folder], recursive: true)
        } else if let id = pageID, id.hasPrefix("folder:") {
            await store.mark([String(id.dropFirst(7))], recursive: true)
        } else { await invalidate() }
    }
    public func tile(context: ModuleContext) async -> Tile {
        let snapshot = await store.view(); return DiskMapScreenBuilder.tile(snapshot.index, files: snapshot.files)
    }
    public func tile(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Tile {
        let snapshot = await store.view(progress: { progress(0.85 * $0) }); return DiskMapScreenBuilder.tile(snapshot.index, files: snapshot.files)
    }
    public func screen(context: ModuleContext) async -> Screen {
        let snapshot = await store.view()
        let apps = await browsing(snapshot.index)
        let completed = await store.navigation()
        return DiskMapScreenBuilder.screen(completed.index, apps: apps, files: completed.files)
    }
    public func screen(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen {
        let snapshot = await store.view(progress: { progress(0.85 * $0) })
        progress(0.85)
        let apps = await browsing(snapshot.index)
        progress(1)
        let completed = await store.navigation()
        return DiskMapScreenBuilder.screen(completed.index, apps: apps, files: completed.files)
    }
    public func status(context: ModuleContext) async -> (tile: Tile, screen: Screen)? {
        guard let snapshot = await store.statusView() else { return nil }
        let apps = await inventory.passive()
        guard apps.catalogReadAt != .distantPast else { return nil }
        return (DiskMapScreenBuilder.tile(snapshot.index, files: snapshot.files),
                DiskMapScreenBuilder.screen(snapshot.index, apps: apps, files: snapshot.files))
    }
    public func page(id: String, context: ModuleContext) async -> Screen? { await page(id: id, context: context, progress: { _ in }) }
    public func page(id: String, context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen? {
        if let request = SelectionBulkRequest(pageID: id) {
            let bulk: SelectionBulk
            do { bulk = try await store.selection(request) }
            catch {
                var selection = DiskMapScreenBuilder.fileSelection([])
                if let token = request.token { selection.bulk = try? await store.selectionSummary(token: token) }
                if selection.bulk == nil { selection.bulk = .init(token: "", count: 0, bytes: 0, checked: []) }
                selection.bulk?.unavailableReason = error.localizedDescription
                return Screen(title: loc("Files"), widgets: [], selection: selection)
            }
            var selection = DiskMapScreenBuilder.fileSelection([])
            selection.bulk = bulk
            return Screen(title: loc("Files"), widgets: [], selection: selection)
        }
        if id.hasPrefix("focus:"), let request = DiskBrowseRequest(id: String(id.dropFirst(6))) {
            let snapshot = await store.navigation(folder: request.folder)
            guard snapshot.index.contains(request.folder, below: snapshot.index.root), snapshot.index.directories[request.folder] != nil else { return nil }
            let direct = await store.folderFiles(request.folder, includeSmaller: request.focusPath == nil || request.includeSmaller, focusPath: request.focusPath)
            let apps = await inventory.passive()
            var screen = DiskMapScreenBuilder.screen(snapshot.index, apps: apps, folder: request.folder, files: snapshot.files, direct: direct)
            if request.folder == snapshot.index.root, let direct { screen.widgets += DiskMapScreenBuilder.browsePage(direct).widgets }
            return screen
        }
        if let request = DiskBrowseRequest(id: id) {
            let snapshot = await store.navigation()
            guard snapshot.index.contains(request.folder, below: snapshot.index.root) else { return nil }
            guard let files = await store.browse(request, progress: progress) else { return nil }
            if request.inFolder {
                let folder = await store.navigation(folder: request.folder)
                return DiskMapScreenBuilder.screen(folder.index, apps: await inventory.passive(), folder: request.folder, files: folder.files, direct: files)
            }
            return DiskMapScreenBuilder.browsePage(files)
        }
        if id.hasPrefix("folder:") || id.hasPrefix("large:") {
            let path = String(id.dropFirst(id.hasPrefix("folder:") ? 7 : 6))
            let snapshot = await store.navigation(folder: path)
            guard snapshot.index.contains(path, below: snapshot.index.root), snapshot.index.directories[path] != nil else { return nil }
            let files = await store.folderFiles(path)
            return DiskMapScreenBuilder.screen(snapshot.index, apps: await inventory.passive(), folder: path, files: snapshot.files, direct: files)
        }
        let snapshot = await store.navigation(), index = snapshot.index
        if id == "apps" || id == "other-apps" || id.hasPrefix("apps:") || id.hasPrefix("other-apps:") {
            let other = id.hasPrefix("other-apps"), prefix = other ? "other-apps:" : "apps:"
            var folder: String?
            if id.hasPrefix(prefix) {
                guard let data = Data(base64Encoded: String(id.dropFirst(prefix.count))), let path = String(data: data, encoding: .utf8),
                      FileReviewPolicy.applicationsFolder(path) else { return nil }
                folder = path
            }
            let apps = await inventory.navigation(index)
            return other ? DiskMapScreenBuilder.otherAppsPage(apps, folder: folder) : DiskMapScreenBuilder.appsPage(index, apps: apps, folder: folder)
        }
        if id.hasPrefix("app:"), let data = Data(base64Encoded: String(id.dropFirst(4))), let path = String(data: data, encoding: .utf8),
           let app = await browsing(index).apps.first(where: { $0.owner.path == path }) { return DiskMapScreenBuilder.appDataPage(app) }
        if id == "app-data-review" { return DiskMapScreenBuilder.leftoversPage(await inventory.navigation(index)) }
        return nil
    }
    /// Fresh metadata establishes eligibility; every removal keeps the frozen selection's original identity and proof.
    static func reviewedSelection(_ current: [DiskFile], original: [DiskFile]) -> [DiskFile]? {
        guard !original.isEmpty, current.count == original.count else { return nil }
        let live = Dictionary(current.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let paths = Set(original.map(\.path))
        guard live.count == original.count, paths.count == original.count else { return nil }
        for file in original {
            guard let now = live[file.path], DiskMapScreenBuilder.selectable(now),
                  let identity = file.identity, now.identity == identity else { return nil }
            if let proof = file.duplicateVerification {
                guard proof.path == file.path, proof.identity == identity else { return nil }
            }
        }
        return original
    }

    private func removeSelection(token: String, index: DiskIndex, moveToTrash: Bool,
                                 progress: @escaping ProgressSink) async -> (ActionResult, SelectionBulk?) {
        var remaining: SelectionBulk?
        var removed: UInt64 = 0, removedBytes: UInt64 = 0, failures: UInt64 = 0
        var details: [String] = []
        var pendingRemoved: [String] = []
        var result: ActionResult
        do {
            try await store.pinSelection(token: token)
            let snapshot = try await store.selectionSummary(token: token)
            remaining = snapshot
            guard snapshot.count > 0 else { throw DiskDatabase.Failure(message: loc("No files are selected.")) }
            var after = "", reviewed: UInt64 = 0
            // Validate the complete immutable inventory before the first mutation, without retaining it in memory.
            while true {
                try Task.checkCancellation()
                let files = try await store.selectionFiles(token: token, after: after)
                guard let last = files.last else { break }
                let ids = Set(files.map { DiskFileRemoval.id($0.path) })
                guard last.path > after, let current = await store.selectedFiles(ids, folder: index.root),
                      let original = Self.reviewedSelection(current, original: files) else {
                    throw DiskDatabase.Failure(message: loc("Files changed. Reopen the list and review your selection again."))
                }
                let verified = try await store.resolveSelection(original, token: token)
                guard try await Task.detached(priority: .utility, operation: {
                    guard original.allSatisfy({ DiskFileRemoval.canDelete($0.path) }),
                          OpenFileUse.inspect(Set(original.map(\.path))).isEmpty else { return false }
                    for proof in verified.compactMap(\.duplicateVerification) { if try !proof.verify() { return false } }
                    return true
                }).value else { throw DiskDatabase.Failure(message: loc("Selected files changed or are open. Review them again.")) }
                try await store.recordPreflight(verified, token: token)
                reviewed += UInt64(files.count); after = last.path
                progress(.init(fraction: 0.5 * Double(reviewed) / Double(snapshot.count), message: loc("Reviewing selected files")))
            }
            guard reviewed == snapshot.count else { throw DiskDatabase.Failure(message: loc("The selection changed. Review the files again.")) }
            after = ""
            var processed: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let files = try await store.selectionFiles(token: token, after: after)
                guard let last = files.last else { break }
                let completed = DiskRemovalBatch(), offset = processed
                let ids = Set(files.map { DiskFileRemoval.id($0.path) })
                guard let current = await store.selectedFiles(ids, folder: index.root),
                      let original = Self.reviewedSelection(current, original: files) else { throw DiskDatabase.Failure(message: loc("Selected files changed or are unavailable. Review your selection again.")) }
                let resolved = try await store.executionFiles(original, token: token)
                guard let removal = DiskFileRemoval.execute(ids: ids, folder: index.root,
                    index: index, files: resolved, confirmedMoveToTrash: moveToTrash, progress: { update in
                        completed.record(update.finished)
                        progress(.init(fraction: 0.5 + 0.5 * (Double(offset) + (update.fraction ?? 0) * Double(files.count)) / Double(snapshot.count),
                            message: update.message, finished: update.finished))
                    }) else { throw DiskDatabase.Failure(message: loc("This file cannot be deleted here.")) }
                let finished = completed.ids
                let paths = files.filter { finished.contains(DiskFileRemoval.id($0.path)) }.map(\.path)
                removed += UInt64(paths.count); removedBytes += removal.removedBytes; failures += UInt64(files.count - paths.count)
                details += removal.failures.prefix(max(0, 20 - details.count))
                await store.mark(removal.targets)
                if !paths.isEmpty {
                    pendingRemoved = paths
                    try await store.recordSelectionRemoved(token: token, paths: paths)
                    pendingRemoved = []
                }
                processed += UInt64(files.count); after = last.path
            }
            if failures > UInt64(details.count) { details.append(loc("\(Int(clamping: failures)) files could not be removed.")) }
            result = ActionResult(outcome: failures == 0 ? .succeeded : .needsAttention,
                message: failures == 0 ? loc("Freed selected files") : loc("Some files could not be removed"), details: details)
        } catch {
            result = ActionResult(outcome: removed == 0 ? .failed : .needsAttention,
                message: removed == 0 ? loc("Couldn’t remove the selected files") : loc("Some files could not be removed"),
                details: details + [error.localizedDescription])
        }
        // Record batches cheaply; derive the remaining immutable snapshot once, including on cancellation or partial failure.
        if removed > 0 {
            do { remaining = try await store.selectionAfterRemoving(token: token, paths: pendingRemoved) }
            catch {
                remaining = nil
                result.outcome = .needsAttention
                result.details.append(error.localizedDescription)
            }
        }
        result.removedBytes = removedBytes
        await store.unpinSelection(token: token)
        return (result, remaining)
    }

    public func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult {
        let moveToTrash = request.parameters["trash"] == "1"
        if ["freeFiles", "freeDuplicates", "deleteGraphFile", "deleteFolder"].contains(request.actionID),
           (!["0", "1"].contains(request.parameters["trash"] ?? "") || moveToTrash != FileRemovalSettings.movesToTrash()) {
            return .failed(loc("File removal settings changed. Reopen the list and confirm again."))
        }
        let index = await store.snapshot()
        let before = DataVolume.freeBytes()
        var result: ActionResult
        var remainingSelection: SelectionBulk?
        switch request.actionID {
        case "deleteFolder":
            guard let path = request.parameters["path"], index.contains(path, below: index.root),
                  let encoded = request.parameters["reviewed"],
                  let expected = try? JSONDecoder().decode(ReviewedDirectoryRemoval.Identity.self, from: Data(encoded.utf8)) else {
                return .failed(loc("Reopen the list and review your selection again."))
            }
            let apps = await inventory.read(index, force: true)
            await store.recordOwnership(apps)
            guard await store.canRemoveDirectory(path) else { return .failed(loc("This folder cannot be deleted here.")) }
            do {
                progress(.init(message: loc("Freeing space")))
                let removed = try DiskDirectoryRemoval.remove(path, expected: expected, moveToTrash: moveToTrash)
                await store.mark([path], recursive: true)
                progress(.init(fraction: 1, message: loc("Freeing space"), finished: [DiskMapScreenBuilder.folderID(path), path]))
                result = ActionResult(outcome: .succeeded, message: loc("Deleted folder"), removedBytes: removed)
            } catch {
                await store.mark([path], recursive: true)
                result = ActionResult(outcome: .needsAttention, message: loc("Couldn’t delete the folder"), details: [error.localizedDescription])
            }
        case "deleteGraphFile":
            guard let id = request.parameters["id"], let reviewed = request.parameters["reviewed"] else {
                return .failed(loc("Reopen the list and review your selection again."))
            }
            // A graph deletes one reviewed target, independently of the page's retained batch selection.
            guard let files = await store.selectedFiles([id], folder: index.root, reviewed: [id: reviewed],
                origins: request.parameters["origin"].map { [id: $0] } ?? [:]), files.count == 1 else {
                return .failed(loc("Selected files changed or are unavailable. Review your selection again."))
            }
            do {
                if let proof = files.first?.duplicateVerification, try !proof.verify() {
                    return .failed(loc("Selected files changed or are unavailable. Review your selection again."))
                }
            } catch { return .failed(error.localizedDescription) }
            guard let removal = DiskFileRemoval.execute(ids: [id], folder: index.root, index: index, files: files,
                confirmedMoveToTrash: moveToTrash, progress: progress) else {
                return .failed(loc("This file cannot be deleted here."))
            }
            await store.mark(removal.targets)
            result = ActionResult(outcome: removal.failures.isEmpty ? .succeeded : .needsAttention,
                message: removal.failures.isEmpty ? loc("Freed selected files") : loc("Some files could not be removed"),
                details: removal.failures, removedBytes: removal.removedBytes)
        case "freeFiles", "freeDuplicates":
            guard let token = request.parameters["selectionToken"] else { return .failed(loc("Reopen the list and review your selection again.")) }
            (result, remainingSelection) = await removeSelection(token: token, index: index, moveToTrash: moveToTrash, progress: progress)
        case "freeUnmatchedData":
            guard request.parameters["trash"] == "0" else { return .failed(loc("Reopen the list and confirm deletion again.")) }
            let apps = await inventory.read(index, force: true)
            let ids = Set(Selection.ids(request.parameters["ids"]))
            guard let removal = DiskUnmatchedRemoval.execute(ids: ids, candidates: apps.reviewableLeftovers, progress: progress) else {
                return .failed(loc("App data changed. Reopen the list and review your selection again."))
            }
            await store.mark(removal.targets.map { DiskApplications.measuredPath($0, index: index) }, recursive: true)
            result = ActionResult(outcome: removal.failures.isEmpty ? .succeeded : .needsAttention,
                                  message: removal.failures.isEmpty ? loc("Freed selected files") : loc("Some files could not be removed"), details: removal.failures)
        case "uninstall":
            let apps = await inventory.read(index, force: true)
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
        if let before, let after = DataVolume.freeBytes() { result.freedBytes = after > before ? after - before : 0 }
        let updated = await store.view()
        let apps = await inventory.read(updated.index)
        await store.recordOwnership(apps)
        var screen = DiskMapScreenBuilder.screen(updated.index, apps: apps, files: updated.files)
        screen.selection?.bulk = remainingSelection
        result.presentation = ModulePresentation(tile: DiskMapScreenBuilder.tile(updated.index, files: updated.files), screen: screen)
        return result
    }
}
