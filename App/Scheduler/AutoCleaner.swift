import Foundation
import MacSpacePlatform
import MacSpaceSdk

/// Automatic cleanup: while MacSpace runs (the window or the menu bar), every module that takes part (`ModuleManifest.autoClean`)
/// frees what is safe to free, as often as the user chose in Settings. What each run frees goes to the cleanup history.
@MainActor
public final class AutoCleaner: ObservableObject {
    public enum Frequency: String, CaseIterable, Identifiable, Sendable {
        case daily, everyThreeDays, weekly

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .daily: return "Every day"
            case .everyThreeDays: return "Every 3 days"
            case .weekly: return "Every week"
            }
        }
        public var interval: TimeInterval {
            switch self {
            case .daily: return 86_400
            case .everyThreeDays: return 3 * 86_400
            case .weekly: return 7 * 86_400
            }
        }
    }

    static let enabledKey = "autoClean.enabled"
    static let frequencyKey = "autoClean.frequency"
    static let lastRunKey = "autoClean.lastRun"
    /// How often MacSpace looks whether a run is due.
    static let checkInterval: TimeInterval = 30 * 60

    @Published public var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Self.enabledKey); if isEnabled { checkSoon() } } }
    @Published public var frequency: Frequency { didSet { defaults.set(frequency.rawValue, forKey: Self.frequencyKey) } }
    @Published public private(set) var lastRun: Date? { didSet { defaults.set(lastRun, forKey: Self.lastRunKey) } }
    @Published public private(set) var isRunning = false
    /// What the last run freed, for Settings.
    @Published public private(set) var lastFreed: UInt64?

    private let defaults: UserDefaults
    private weak var host: ModuleHost?
    private var loop: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        frequency = Frequency(rawValue: defaults.string(forKey: Self.frequencyKey) ?? "") ?? .daily
        lastRun = defaults.object(forKey: Self.lastRunKey) as? Date
    }

    /// Starts looking whether a run is due, every half hour, for as long as the app runs.
    public func start(host: ModuleHost) {
        self.host = host
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // A moment after launch, so the modules have loaded.
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.runIfDue()
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
    }

    public nonisolated static func isDue(enabled: Bool, lastRun: Date?, frequency: Frequency, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= frequency.interval
    }

    func runIfDue(now: Date = Date()) async {
        guard Self.isDue(enabled: isEnabled, lastRun: lastRun, frequency: frequency, now: now) else { return }
        await runNow()
    }

    private func checkSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.runIfDue()
        }
    }

    /// Runs every taking-part module's cleanup, one after another.
    public func runNow() async {
        guard !isRunning, let host else { return }
        isRunning = true
        defer { isRunning = false }
        var freed: UInt64 = 0
        for handle in host.activeHandles where handle.manifest.autoClean == true {
            if let report = await handle.autoClean() { freed += report.freedBytes }
        }
        lastFreed = freed
        lastRun = Date()
    }
}
