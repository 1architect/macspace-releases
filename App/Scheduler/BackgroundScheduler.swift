import Foundation
import MacSpaceSdk

/// Runs the background tasks modules declare, only for enabled modules whose task the user switched on.
/// Tasks run while the app is open; a module that must watch with the app closed will need a login item, added when
/// the first such module is built.
@MainActor
public final class BackgroundScheduler {
    private var running: [String: Task<Void, Never>] = [:]

    public init() {}

    var runningTaskKeys: Set<String> { Set(running.keys) }

    public func apply(handles: [ModuleHandle]) {
        var wanted: [String: (handle: ModuleHandle, task: BackgroundTaskDefinition)] = [:]
        for handle in handles {
            for task in handle.enabledBackgroundTasks() { wanted["\(handle.id)/\(task.id)"] = (handle, task) }
        }
        for key in running.keys where wanted[key] == nil {
            running[key]?.cancel()
            running[key] = nil
        }
        for (key, entry) in wanted where running[key] == nil {
            let interval = UInt64(max(entry.task.intervalSeconds, 1)) * 1_000_000_000
            running[key] = Task { [weak handle = entry.handle, taskID = entry.task.id] in
                while !Task.isCancelled {
                    await handle?.runBackgroundTask(taskID)
                    try? await Task.sleep(nanoseconds: interval)
                }
            }
        }
    }

    public func stopAll() {
        running.values.forEach { $0.cancel() }
        running.removeAll()
    }
}
