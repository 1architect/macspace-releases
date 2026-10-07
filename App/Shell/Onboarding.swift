import AppKit
import MacSpacePlatform
import MacSpaceSdk
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

/// The first launch, in place of the dashboard: one screen per permission MacSpace still needs, then one saying how much can be
/// freed. No welcome screen: it starts with what is needed. Each screen is an animated symbol, a headline, one line and one button.
/// The symbol answers when a permission arrives (the lock opens, the switch flips on, the bell rings).
///
/// Steps already granted are left out. The step is kept, so the relaunch System Settings asks for after Full Disk Access is turned on
/// comes back to it. Someone who used MacSpace before onboarding existed never sees it; `--onboarding` shows it again.
@MainActor
public final class Onboarding: ObservableObject {
    public static let shared = Onboarding()

    enum Step: Int, CaseIterable, Comparable {
        // Numbered as when a welcome step came first, so a step kept in the defaults still means the same.
        case fullDiskAccess = 1, helper, notifications, ready

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let completedKey = "onboarding.completed"
    static let stepKey = "onboarding.step"

    @Published public private(set) var isShowing: Bool
    @Published private(set) var step: Step
    /// The steps this Mac goes through, in order.
    @Published private(set) var flow: [Step] = Step.allCases
    @Published private(set) var fullDiskAccess: PermissionStatus
    @Published private(set) var helper: SMAppService.Status
    @Published private(set) var notifications: UNAuthorizationStatus = .notDetermined
    /// System Settings was opened for the current step: the tile says what to do there.
    @Published private(set) var waitingForSettings = false
    @Published private(set) var helperError: String?

    private let defaults: UserDefaults
    private var prepared = false

    init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        if arguments.contains("--onboarding") {
            defaults.set(false, forKey: Self.completedKey)
            defaults.removeObject(forKey: Self.stepKey)
        } else if defaults.object(forKey: Self.completedKey) == nil, Self.usedBefore(defaults) {
            defaults.set(true, forKey: Self.completedKey)
        }
        isShowing = !defaults.bool(forKey: Self.completedKey)
        let access = LivePermissionChecker.probeFullDiskAccess()
        let helper = PrivilegedHelperInstaller.status
        fullDiskAccess = access
        self.helper = helper
        // The step kept from before a relaunch, else the first permission missing (notifications are read later; until then they
        // count as missing).
        step = Step(rawValue: defaults.integer(forKey: Self.stepKey))
            ?? Self.flow(fullDiskAccess: access, helper: helper, notifications: .notDetermined, current: .ready).first ?? .ready
    }

    /// MacSpace ran here before onboarding existed: a module left its tile, or automatic cleanup ran.
    nonisolated static func usedBefore(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "autoClean.lastRun") != nil
            || defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("module.") && $0.hasSuffix(".lastTile") }
    }

    /// The steps to go through: each permission only while it is missing, then the end. The step the user was on stays, granted or
    /// not, so the screen that was waiting for it can show it arrive.
    nonisolated static func flow(fullDiskAccess: PermissionStatus, helper: SMAppService.Status, notifications: UNAuthorizationStatus,
                                 current: Step) -> [Step] {
        Step.allCases.filter { step in
            switch step {
            case .ready: return true
            case .fullDiskAccess: return fullDiskAccess != .granted || step == current
            case .helper: return helper != .enabled || step == current
            case .notifications: return notifications == .notDetermined || step == current
            }
        }
    }

    // MARK: Following the Mac

    /// Reads the permissions every second while onboarding shows, and System Data again as soon as Full Disk Access arrives.
    func watch(_ host: ModuleHost) async {
        while isShowing, !Task.isCancelled {
            await read(host)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func read(_ host: ModuleHost) async {
        let access = LivePermissionChecker.probeFullDiskAccess()
        let helper = PrivilegedHelperInstaller.status
        // Only the app can ask: the tests have no bundle to notify from.
        let notifications = AppNotifications.canNotify ? await UNUserNotificationCenter.current().notificationSettings().authorizationStatus : self.notifications
        if !prepared {
            prepared = true
            flow = Self.flow(fullDiskAccess: access, helper: helper, notifications: notifications, current: step)
            // Nothing to ask: straight to the dashboard.
            if flow == [.ready] { return finish() }
            if !flow.contains(step) { go(to: flow.first { $0 > step } ?? .ready) }
        }
        if access == .granted, fullDiskAccess != .granted {
            // What was hidden is measured now: the blocks break into their parts while the tile watches.
            for handle in host.activeHandles where handle.manifest.permissions.contains(.fullDiskAccess) {
                Task { await handle.refresh(reload: true) }
            }
        }
        withAnimation(Theme.toggle) {
            if fullDiskAccess != access { fullDiskAccess = access }
            if self.helper != helper { self.helper = helper }
            if self.notifications != notifications { self.notifications = notifications }
        }
        if waitingForSettings, isGranted(step) { waitingForSettings = false }
    }

    func isGranted(_ step: Step) -> Bool {
        switch step {
        case .fullDiskAccess: return fullDiskAccess == .granted
        case .helper: return helper == .enabled
        case .notifications: return notifications != .notDetermined
        case .ready: return true
        }
    }

    // MARK: Moving on

    func next() {
        guard let index = flow.firstIndex(of: step), index + 1 < flow.count else { return finish() }
        go(to: flow[index + 1])
    }

    func go(to step: Step) {
        waitingForSettings = false
        withAnimation(Theme.push) { self.step = step }
        defaults.set(step.rawValue, forKey: Self.stepKey)
    }

    func finish() {
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.stepKey)
        withAnimation(Theme.layout) { isShowing = false }
    }

    /// For development captures (`DebugRemote`): shows onboarding again from its first step.
    func restart() {
        defaults.set(false, forKey: Self.completedKey)
        prepared = false
        go(to: .fullDiskAccess)
        withAnimation(Theme.layout) { isShowing = true }
    }

    // MARK: Asking

    func openFullDiskAccess() {
        waitingForSettings = true
        NSWorkspace.shared.open(LivePermissionChecker.fullDiskAccessSettingsURL)
    }

    func approveHelper() {
        helperError = nil
        if PrivilegedHelperInstaller.status == .notRegistered {
            // Registering reports an error while it waits for approval; that is not a failure.
            do { try PrivilegedHelperInstaller.register() } catch {
                if PrivilegedHelperInstaller.status != .requiresApproval { helperError = error.localizedDescription; return }
            }
        }
        waitingForSettings = true
        PrivilegedHelperInstaller.openLoginItemsSettings()
    }

    func allowNotifications() {
        Task { await askForNotifications() }
    }

    func askForNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

// MARK: The screens

/// One step at a time, on the window's ground, which takes the step's color.
struct OnboardingView: View {
    @ObservedObject var onboarding: Onboarding
    @ObservedObject var host: ModuleHost
    @Environment(\.design) private var design

    private var tint: TileTint {
        switch onboarding.step {
        case .fullDiskAccess: return .blue
        case .helper: return .teal
        case .notifications: return .violet
        case .ready: return .slate
        }
    }

    var body: some View {
        ZStack {
            TileBackdrop(tint: tint)
                .animation(.smooth(duration: 0.6), value: tint)
            screen
                .id(onboarding.step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            StepDots(onboarding: onboarding)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
        }
        .foregroundStyle(design.ink)
        .task { await onboarding.watch(host) }
    }

    @ViewBuilder
    private var screen: some View {
        switch onboarding.step {
        case .fullDiskAccess: fullDiskAccess
        case .helper: helper
        case .notifications: notifications
        case .ready: ready
        }
    }

    private var waiting: Bool { onboarding.waitingForSettings && !onboarding.isGranted(onboarding.step) }

    private var fullDiskAccess: some View {
        let granted = onboarding.fullDiskAccess == .granted
        let line: String
        if granted { line = "MacSpace can now see everything in System Data." }
        else if waiting { line = "Turn on MacSpace in the list. Not there? Drag this icon into it." }
        else { line = "MacSpace needs it to see everything in System Data." }
        let action: () -> Void = granted ? { onboarding.next() } : { onboarding.openFullDiskAccess() }
        let later: (() -> Void)? = granted ? nil : { onboarding.next() }
        return StepScreen(title: granted ? "Full Disk Access is on" : "Allow Full Disk Access", line: line,
                          button: granted ? "Continue" : "Open System Settings", action: action, later: later) {
            AppIconLock(open: granted)
        }
    }

    private var helper: some View {
        let granted = onboarding.helper == .enabled
        let notFound = onboarding.helper == .notFound
        let done = granted || notFound
        let line: String
        if granted { line = "MacSpace can now do the tasks that need an administrator." }
        else if notFound { line = "Move MacSpace to your Applications folder first." }
        else if onboarding.helperError != nil { line = "The helper couldn't be installed. Try again in Settings > Permissions." }
        else if waiting { line = "Turn on MacSpace under Allow in the Background." }
        else { line = "It does the few tasks that need an administrator." }
        let action: () -> Void = done ? { onboarding.next() } : { onboarding.approveHelper() }
        let later: (() -> Void)? = done ? nil : { onboarding.next() }
        return StepScreen(title: granted ? "Helper approved" : "Approve the helper", line: line,
                          button: done ? "Continue" : "Open Login Items", action: action, later: later) {
            BigSwitch(on: granted)
        }
    }

    private var notifications: some View {
        let answered = onboarding.notifications != .notDetermined
        let action: () -> Void = answered ? { onboarding.next() } : { onboarding.allowNotifications() }
        let later: (() -> Void)? = answered ? nil : { onboarding.next() }
        return StepScreen(title: "Get notified", line: "When MacSpace frees space, or your disk is almost full.",
                          button: answered ? "Continue" : "Allow Notifications", action: action, later: later) {
            SymbolCircle(symbol: onboarding.notifications == .authorized ? "bell.badge.fill" : "bell.fill", ringing: !answered)
        }
    }

    private var ready: some View {
        let freeable = host.reclaimable.values.reduce(0, +)
        let line = freeable >= 100_000_000 ? "You can free up to \(ByteFormat.string(freeable)) right now." : "MacSpace keeps an eye on your disk."
        return StepScreen(title: "You're all set", line: line, button: "Open MacSpace", action: { onboarding.finish() }) {
            SymbolCircle(symbol: "checkmark", ringing: false, celebrates: true)
        }
    }
}

/// A screen: the visual, the headline, one line, the button and, for a permission, Later.
private struct StepScreen<Visual: View>: View {
    let title: String
    let line: String
    let button: String
    let action: () -> Void
    var later: (() -> Void)?
    @ViewBuilder let visual: Visual
    @Environment(\.design) private var design
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            visual
                .frame(height: 150)
                .padding(.bottom, 30)
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .contentTransition(.interpolate)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 12)
            Text(line)
                .font(.system(size: 15, weight: .light))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.interpolate)
                .padding(.top, 8)
                .opacity(shown ? 0.85 : 0)
                .offset(y: shown ? 0 : 12)
            Button(button, action: action)
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 26)
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown ? 1 : 0.9)
            Button("Later") { later?() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .opacity(later == nil ? 0 : 0.6)
                .disabled(later == nil)
                .padding(.top, 12)
        }
        .animation(Theme.layout, value: title)
        .animation(Theme.layout, value: line)
        .animation(Theme.layout, value: button)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 10)
        .onAppear { withAnimation(Theme.layout.delay(0.15)) { shown = true } }
    }
}

/// A dot per step, the current one wider.
private struct StepDots: View {
    @ObservedObject var onboarding: Onboarding
    @Environment(\.design) private var design

    var body: some View {
        HStack(spacing: 6) {
            ForEach(onboarding.flow, id: \.self) { step in
                Capsule()
                    .fill(design.ink.opacity(step == onboarding.step ? 0.9 : 0.3))
                    .frame(width: step == onboarding.step ? 18 : 6, height: 6)
            }
        }
        .animation(Theme.layout, value: onboarding.step)
        .accessibilityHidden(true)
    }
}

// MARK: The visuals

/// Full Disk Access: MacSpace's icon with a lock that springs open once access is given. The icon can be dragged into System
/// Settings' list when MacSpace is not in it.
private struct AppIconLock: View {
    let open: Bool
    @Environment(\.design) private var design

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 128, height: 128)
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                .help("Drag into the Full Disk Access list")
            Image(systemName: open ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(open ? design.actionDeep : design.ink)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: open)
                .frame(width: 46, height: 46)
                .background(Circle().fill(open ? design.action : Color.black.opacity(0.35)))
                .offset(x: 6, y: 6)
                .animation(Theme.toggle, value: open)
        }
    }
}

/// The helper: a large switch that flips on by itself once MacSpace is approved in Login Items.
private struct BigSwitch: View {
    let on: Bool
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudge = false

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? design.action : Color.black.opacity(0.3))
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .padding(6)
                // While off, the knob leans toward on, as if asking.
                .offset(x: on || reduceMotion ? 0 : (nudge ? 10 : 0))
        }
        .frame(width: 128, height: 72)
        .animation(.spring(duration: 0.45, bounce: 0.3), value: on)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { nudge = true }
        }
    }
}

/// A symbol in a round ground: the bell rings while notifications are not answered; the last screen's check pops in.
private struct SymbolCircle: View {
    let symbol: String
    var ringing: Bool
    var celebrates = false
    @Environment(\.design) private var design
    @State private var popped = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 56, weight: .semibold))
            .foregroundStyle(celebrates ? design.actionDeep : design.ink)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 1.2)), isActive: ringing)
            .frame(width: 128, height: 128)
            .background(Circle().fill(celebrates ? design.action : Color.black.opacity(0.3)))
            .scaleEffect(celebrates && !popped ? 0.4 : 1)
            .opacity(celebrates && !popped ? 0 : 1)
            .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.45).delay(0.1)) { popped = true } }
    }
}
