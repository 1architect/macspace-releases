import Foundation
import XCTest
import MacSpacePlatform
import MacSpaceSdk
@testable import MacSpaceDiskMap
@testable import MacSpaceSystemData
@testable import MacSpaceSiri
@testable import MacSpaceDebloat
@testable import MacSpaceOtherSystemFiles

/// Opt-in, headless measurements of real readers and presentation builders. No module action, automatic cleanup,
/// profile repair, notification, app window, or live inventory cache is used. Disk metadata keys stay in memory.
/// Snapshot readers include OS services and disk scans; the helper and signed production Keychain path are excluded.
final class ModuleLoadingBenchmarks: XCTestCase {
    /// Match the foreground request made by SwiftUI's .task and the module host's explicit opening/navigation read.
    private static let requestPriority = TaskPriority.userInitiated
    private struct Measurement: Codable, Sendable {
        var module: String
        var seconds: Double
        var widgets: Int
    }
    private struct Sample: Codable {
        var root: String
        var configuration: String
        var requestPriority: UInt8
        var first: [Measurement]
        var reopen: [Measurement]
        var allReadySeconds: Double
        var cachedIndexStartup: [Measurement]
        var cachedIndexAllReadySeconds: Double
    }
    private struct Options: OptionStore {
        func bool(_ id: String) -> Bool { false }
        func string(_ id: String) -> String { "" }
        func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
    }
    private struct Permissions: PermissionChecker {
        func status(of permission: Permission) -> PermissionStatus { .granted }
    }
    private final class Keys: MetadataKeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        func read(_ account: String) throws -> Data? { lock.withLock { values[account] } }
        func create(_ account: String, value: Data) throws {
            try lock.withLock {
                guard values[account] == nil else { throw MetadataUnavailable() }
                values[account] = value
            }
        }
        func replace(_ account: String, value: Data) throws { lock.withLock { values[account] = value } }
        func delete(_ account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
    }

    private static func measure(_ module: String, read: @Sendable () async -> ModulePresentation) async -> Measurement {
        let started = Date()
        let presentation = await read()
        let value = Measurement(module: module, seconds: Date().timeIntervalSince(started), widgets: presentation.screen.widgets.count)
        XCTAssertFalse(presentation.tile.title.isEmpty)
        XCTAssertFalse(presentation.screen.widgets.isEmpty)
        print("MODULE_LOAD module=\(module) seconds=\(value.seconds) widgets=\(value.widgets)")
        return value
    }

    private static func measureAll(_ readers: [(String, @Sendable () async -> ModulePresentation)]) async -> ([Measurement], Double) {
        let started = Date()
        let values = await withTaskGroup(of: Measurement.self) { group in
            for (name, read) in readers { group.addTask(priority: requestPriority) { await Self.measure(name, read: read) } }
            var values: [Measurement] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.module < $1.module }
        }
        return (values, Date().timeIntervalSince(started))
    }

    private static func readers(disk: DiskMapModule) -> [(String, @Sendable () async -> ModulePresentation)] {
        let system = SystemDataStore(), siri = SiriStore(), debloat = DebloatStore()
        // Avoid PurgeableStore's legacy UserDefaults migration during a read-only diagnostic.
        let other = SharedReading<PurgeableSnapshot> { await PurgeableStore.liveSnapshot(progress: $0) }
        let context = ModuleContext(manifest: ModuleManifest(id: "com.macspace.disk-map", name: "Disk", summary: "", version: "benchmark", symbol: "internaldrive"), options: Options(), permissions: Permissions())
        return [
            ("system-data", {
                let snapshot = await system.snapshot()
                return ModulePresentation(tile: SystemDataScreenBuilder.tile(snapshot), screen: SystemDataScreenBuilder.screen(snapshot))
            }),
            ("siri", {
                let snapshot = await siri.snapshot()
                return ModulePresentation(tile: SiriScreenBuilder.tile(snapshot), screen: SiriScreenBuilder.screen(snapshot))
            }),
            ("debloat", {
                let snapshot = await debloat.snapshot()
                return ModulePresentation(tile: DebloatScreenBuilder.tile(snapshot), screen: DebloatScreenBuilder.screen(snapshot))
            }),
            ("other-system-files", {
                let snapshot = await other.value(maxAge: 60)
                return ModulePresentation(tile: OtherSystemFilesScreenBuilder.tile(snapshot), screen: OtherSystemFilesScreenBuilder.screen(snapshot))
            }),
            ("disk-map", {
                async let tile = disk.tile(context: context)
                async let screen = disk.screen(context: context)
                return await ModulePresentation(tile: tile, screen: screen)
            })
        ]
    }

    private static func validate(_ store: DiskStore) async throws {
        let index = await store.navigation().index
        _ = try XCTUnwrap(index.loadError != true && index.summaryVersion == DiskIndex.summarySchemaVersion
                          && index.personalInventoryVersion == DiskIndex.personalInventorySchemaVersion
                          && index.inventoryAuthoritative == true ? true : nil,
                          "A failed, partial or unmigrated inventory cannot count as a fast completed load")
    }

    func testRealReadersFirstLoadAndCachedReopen() async throws {
        let environment = ProcessInfo.processInfo.environment
        print("MODULE_LOAD_CONTEXT testPriority=\(Task.currentPriority.rawValue) requestedPriority=\(Self.requestPriority.rawValue)")
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        guard environment["MACSPACE_LOADING_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in headless live readers: MACSPACE_LOADING_BENCHMARK=1")
        }
        guard LivePermissionChecker.probeFullDiskAccess() == .granted else {
            throw XCTSkip("Full Disk Access is required for comparable native measurements without permission prompts")
        }
        MetadataKeys.useStore(Keys())
        let directory = URL(fileURLWithPath: "/private/tmp/macspace-loading-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var samples: [Sample] = []
        let count = max(1, Int(environment["MACSPACE_LOADING_SAMPLES"] ?? "3") ?? 3)
        for sample in 0..<count {
            PurgeableDocuments.forget()
            let cache = directory.appendingPathComponent("index-\(sample)")
            let root = environment["MACSPACE_LOADING_ROOT"] ?? "/"
            let diskStore = DiskStore(root: root, cache: cache)
            let disk = DiskMapModule(store: diskStore)
            let readers = Self.readers(disk: disk)
            let (first, elapsed) = await Self.measureAll(readers)
            try await Self.validate(diskStore)
            var reopen: [Measurement] = []
            for (name, read) in readers {
                let task = Task(priority: Self.requestPriority) { await Self.measure(name, read: read) }
                reopen.append(await task.value)
            }
            XCTAssertEqual(first.count, 5)
            print("MODULE_LOAD_ALL sample=\(sample) seconds=\(elapsed) root=\(environment["MACSPACE_LOADING_ROOT"] ?? "/")")
            await disk.setActive(false)
            await diskStore.flushPersistence()
            PurgeableDocuments.forget()
            let restoredStore = DiskStore(root: root, cache: cache)
            let restored = DiskMapModule(store: restoredStore)
            let (cachedIndex, cachedElapsed) = await Self.measureAll(Self.readers(disk: restored))
            try await Self.validate(restoredStore)
            print("MODULE_LOAD_CACHED_INDEX sample=\(sample) seconds=\(cachedElapsed)")
            samples.append(Sample(root: root, configuration: configuration, requestPriority: Self.requestPriority.rawValue,
                                  first: first, reopen: reopen, allReadySeconds: elapsed, cachedIndexStartup: cachedIndex, cachedIndexAllReadySeconds: cachedElapsed))
            await restored.setActive(false)
        }
        if let destination = environment["MACSPACE_LOADING_REPORT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(samples).write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
    }
}
