import Darwin
import MacSpaceSdk
import XCTest
@testable import MacSpaceApp

private struct BenchmarkModule: MacSpaceModule {
    init() {}
    func tile(context: ModuleContext) async -> Tile { Tile(title: "Fixture", status: "Ready") }
    func screen(context: ModuleContext) async -> Screen { Screen(title: "Fixture", widgets: []) }
    func screen(context: ModuleContext, progress: @escaping LoadProgressSink) async -> Screen {
        await Task.detached(priority: .utility) {
            // An intentionally bursty producer exercises delivery independently of disk speed.
            for step in 0..<10_000 { progress(Double(step) / 10_000) }
            progress(1)
        }.value
        return await screen(context: context)
    }
    func perform(_ request: ActionRequest, context: ModuleContext, progress: @escaping ProgressSink) async -> ActionResult { .failed("Read-only fixture") }
}

/// Headless, opt-in release measurement; no production cache, helper, window or rendering is used.
@MainActor
final class ResponsivenessBenchmarkTests: XCTestCase {
    func testReadDeliveryAndNavigation() async throws {
        guard ProcessInfo.processInfo.environment["MACSPACE_RESPONSIVENESS_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in responsiveness benchmark") }
        let loaded = ProcessInfo.processInfo.environment["MACSPACE_BENCH_LOAD"] == "1"
        let workers = (0..<(loaded ? 2 : 0)).map { _ in Task.detached(priority: .utility) {
            var value: UInt64 = 1
            while !Task.isCancelled {
                for _ in 0..<10_000 { value = value &* 6364136223846793005 &+ 1 }
                withExtendedLifetime(value) {}
            }
        } }
        defer { workers.forEach { $0.cancel() } }
        let directory = try Fixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Fixtures.writeBundle(Fixtures.manifest(), name: "Fixture", into: directory)
        let descriptor = try XCTUnwrap(ModuleScanner.scan(directory: directory).modules.first)
        let handle = ModuleHandle(confirm: { _ in true }, descriptor: descriptor, settings: SettingsStore(defaults: Fixtures.defaults()), permissions: FakePermissions(), loader: { _ in BenchmarkModule() })
        defer { handle.deactivate() }
        var samples: [Double] = []
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                let started = ContinuousClock.now
                try? await Task.sleep(for: .milliseconds(2))
                samples.append(Self.seconds(started.duration(to: .now)) - 0.002)
            }
        }
        let cpuBefore = Self.usage(), start = ContinuousClock.now
        await handle.activate()
        let cold = Self.seconds(start.duration(to: .now))
        let revisits = ContinuousClock.now
        for _ in 0..<20 {
            handle.setWatched(true, screenVisible: false)
            handle.setWatched(true, screenVisible: true)
            await handle.refresh(quiet: true)
        }
        let warm = Self.seconds(revisits.duration(to: .now))
        heartbeat.cancel(); await heartbeat.value
        let after = Self.usage(), sorted = samples.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print("RESPONSIVENESS_BENCH load=\(loaded) coldSeconds=\(cold) revisits20Seconds=\(warm) mainActorP95Seconds=\(p95) cpuSeconds=\(after.cpu - cpuBefore.cpu) peakMiB=\(Double(after.peak) / 1_048_576) samples=\(samples.count)")
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private static func usage() -> (cpu: Double, peak: UInt64) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return (Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6, UInt64(usage.ru_maxrss))
    }
}
