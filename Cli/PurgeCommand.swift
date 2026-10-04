import Foundation
import MacSpacePlatform

/// `MacSpaceCli purge-assets [--execute] [--self-test] [--json]`
/// `MacSpaceCli purge-assets --all-services [--urgency 1-4] [--raw]`
/// `MacSpaceCli purge-assets --service <id> --experiment [--urgency 1-4] [--execute]` for a service still being measured
///
/// The only place the private CacheDelete calls run in a normal flow, so that a changed interface crashes this
/// throwaway process and not the app. The app starts it as a child (`CacheDeleteClient.…InSubprocess`).
enum PurgeCommand {
    static func run(_ arguments: [String]) -> Never {
        let json = arguments.contains("--json")
        let client = CacheDeleteClient()

        if arguments.contains("--self-test") {
            let result = client.runSelfTest()
            if json { emit(result, status: result.passed ? 0 : 1) }
            print("CacheDelete self-test on \(result.build ?? "?"): \(result.passed ? "passed" : "failed") — \(result.detail)")
            exit(result.passed ? 0 : 1)
        }

        if let refusal = client.refusal {
            if json { emit(CacheDeletePurgeResult(services: [CacheDeleteService.mobileAsset], purgedBytes: nil, freeBytesBefore: nil,
                                                  freeBytesAfter: nil, elapsedSeconds: nil, error: refusal), status: 1) }
            print(refusal)
            exit(1)
        }

        // Urgency 1 (default) is what a service gives up most readily; higher asks for more.
        let urgency = arguments.firstIndex(of: "--urgency").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }.map { min(max($0, 1), 4) } ?? 1

        if arguments.contains("--all-services"), arguments.contains("--raw") {
            // Read-only: the query's whole answer, to see what a service reports beyond its total.
            let raw = client.rawPurgeable(urgency: urgency) ?? [:]
            if JSONSerialization.isValidJSONObject(raw),
               let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
                FileHandle.standardOutput.write(data)
                print()
            } else {
                print(raw as NSDictionary)
            }
            exit(0)
        }
        if arguments.contains("--all-services") {
            // Read-only: what every CacheDelete service says it could purge at that urgency.
            let all = client.purgeableByService(urgency: urgency) ?? [:]
            if json { emit(all) }
            for (service, bytes) in all.sorted(by: { $0.value > $1.value }) { print("\(ByteFormat.string(bytes))  \(service)") }
            exit(0)
        }
        var service = CacheDeleteService.mobileAsset
        if let index = arguments.firstIndex(of: "--service"), arguments.indices.contains(index + 1) {
            service = arguments[index + 1]
            let allowed = CacheDeleteService.purgeable.contains(service)
                || (CacheDeleteService.experimental.contains(service) && arguments.contains("--experiment"))
            guard allowed else {
                print(CacheDeleteService.experimental.contains(service)
                      ? "error: \(service) is still being measured; pass --experiment to purge it from the CLI."
                      : "error: \(service) is not a service MacSpace purges.")
                exit(64)
            }
        }
        let purgeable = client.purgeableByService(urgency: urgency)?[service]
        guard arguments.contains("--execute") else {
            if json { emit(["purgeableBytes": purgeable]) }
            print("What macOS would delete when space runs low (\(service)): \(ByteFormat.string(purgeable ?? 0))")
            print("Dry run; pass --execute to ask macOS (CacheDelete, this service only) to delete it now.")
            exit(0)
        }
        let result = client.purge(services: [service], urgency: urgency)
        if json { emit(result, status: result.error == nil ? 0 : 1) }
        if let error = result.error { print("error: \(error)") }
        for (key, value) in (result.answer ?? [:]).sorted(by: { $0.key < $1.key }) { print("  \(key) = \(value)") }
        print("\(service) reported \(ByteFormat.string(result.purgedBytes ?? 0)) removed in \(result.elapsedSeconds.map { String(format: "%.1f s", $0) } ?? "?").")
        print("Data volume free: \(ByteFormat.string(result.freeBytesBefore ?? 0)) -> \(ByteFormat.string(result.freeBytesAfter ?? 0)) (+\(ByteFormat.string(result.freedBytes ?? 0)))")
        exit(result.error == nil ? 0 : 1)
    }

    /// Writes `value` as JSON and exits with `status`: a refusal or a failed purge no longer exited 0.
    static func emit<T: Encodable>(_ value: T, status: Int32 = 0) -> Never {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) { FileHandle.standardOutput.write(data); print() }
        exit(status)
    }
}
