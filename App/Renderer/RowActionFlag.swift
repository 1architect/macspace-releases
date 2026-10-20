import MacSpacePlatform
import MacSpaceSdk
import SwiftUI

struct RowActivity {
    /// The row whose action is running, with its progress.
    var rowID: String?
    var action: Action?
    var progress: ActionProgress?
    /// Rows whose Free was clicked while another action ran: they wait their turn, already working (`ModuleHandle.queuedRows`).
    var queued: [String: Action] = [:]
    /// Each row's own result: a row starting its action no longer clears the one another row is still showing.
    var results: [String: ActionResult] = [:]
    var dismiss: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var rowActivity = RowActivity()
}

/// The existing row capsule, with text. It keeps its identity as the action becomes progress and then its result.
struct RowActionFlags: View {
    let row: Row
    let handler: ActionHandler
    @Environment(\.rowActivity) private var activity
    @State private var retainedActions: [Action] = []

    private var actions: [Action] {
        // Already freeing by itself: its pill says so (`Badge.freeingInBackground`), and no button would hurry it.
        if row.isFreeingInBackground { return [] }
        if !row.actions.isEmpty { return row.actions }
        if activity.rowID == row.id, let action = activity.action { return [action] }
        if let action = activity.queued[row.id] { return [action] }
        if row.activity != nil || activity.results[row.id] != nil { return retainedActions }
        return []
    }

    private var result: ActionResult? {
        guard let result = activity.results[row.id] else { return nil }
        if row.activity != nil || row.isFreeingInBackground, result.outcome == .succeeded, !result.restartRequired { return nil }
        return result
    }

    private var needsAttention: Bool {
        result.map { $0.outcome != .succeeded || $0.restartRequired } ?? false
    }

    /// Running: its progress. Waiting behind another row's action: working already, without a figure, so a second Free shows at
    /// once that it was taken. It said Free until its turn, and the finished row's result vanished when it started (2026-10-19).
    private func progress(_ action: Action) -> ActionProgress? {
        if activity.rowID == row.id { return activity.progress ?? ActionProgress(message: action.workingTitle ?? "") }
        if activity.queued[row.id] != nil { return ActionProgress(message: action.workingTitle ?? "") }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions, id: \.id) { action in
                RowActionFlag(action: action,
                              progress: needsAttention ? nil : row.activity ?? progress(action),
                              result: result,
                              dismiss: { activity.dismiss(row.id) }) {
                    guard ConfirmationAlert.ask(action) else { return }
                    _ = await handler(action, [:], false, row.id)
                }
                .transition(PageCascade.transition(index: actions.firstIndex(where: { $0.id == action.id }) ?? 0, count: actions.count))
            }
            if actions.isEmpty, let result, !result.message.isEmpty {
                StatusFlag(text: result.message, tone: result.outcome == .succeeded && !result.restartRequired ? .neutral : .caution)
                    .onTapGesture {
                        if result.restartRequired { SystemRestart.showDialog() }
                        activity.dismiss(row.id)
                    }
                    .transition(PageCascade.transition(index: 0, count: 1))
            }
        }
        .animation(Theme.layout, value: actions.map(\.id))
        .onChange(of: row.actions, initial: true) { _, actions in
            if !actions.isEmpty { retainedActions = actions }
        }
    }
}

private struct RowActionFlag: View {
    let action: Action
    let progress: ActionProgress?
    let result: ActionResult?
    let dismiss: () -> Void
    let run: @MainActor () async -> Void
    @State private var hovering = false
    @State private var reservedLabels: [String]?
    /// The messages this cleanup has shown so far: the flag never narrows while it works, so a shorter step does not pull the pill
    /// in and the next one push it out again (it jumped at every progress message, 2026-10-18).
    @State private var shownWhileWorking: [String] = []
    @Environment(\.design) private var design

    private var working: Bool { progress != nil }
    /// Only a result that asks something of the user is in the action color: a failure, or a change only a restart completes. Its
    /// work and its other results are grey, as every element that asks nothing (`Badge.Kind`): "Freeing in the background" was
    /// orange on System Data's rows (2026-10-20).
    private var asksUser: Bool { result.map { $0.outcome != .succeeded || $0.restartRequired } ?? false }
    private var text: String {
        if let progress {
            return progress.message.isEmpty ? action.workingTitle ?? String(localized: "Working") : progress.message
        }
        if let result, !result.message.isEmpty { return result.message }
        return action.title
    }

    private var samples: [String] {
        [action.title, action.workingTitle ?? String(localized: "Working")] + (action.labelSamples ?? [])
    }

    /// While working: the widest of what it has shown so far, so it grows only for a longer message and never narrows until the
    /// cleanup ends. Not the labels it might show: reserved up front, "Freeing in the background" left "Freeing space" in a pill with
    /// an empty tail (2026-10-18). Idle and with its result, the flag fits its text.
    private var reserved: [String] {
        let phase = PillLabelSamples.matching(text, samples: reservedLabels ?? samples)
        return working ? phase + shownWhileWorking : phase
    }

    var body: some View {
        Button {
            if let result {
                // A row whose change needs a restart says so in the action color: clicked, macOS's Restart dialog asks.
                if result.restartRequired { SystemRestart.showDialog() }
                dismiss()
            } else if !working { Task { await run() } }
        } label: {
            PillMorph {
                ReservedPillLabel(samples: reserved, reserveWidth: working || result != nil) {
                    ChangingText(text: text)
                }
            }
            .environment(\.textChangeDelay, 0)
            // Working and with its result, the flag keeps its resting look: only the pointer lights it, and only a result that asks
            // something is orange. Darker while it worked, it stood out from every grey pill beside it (2026-10-20).
            .foregroundStyle(asksUser ? design.actionDeep : Color.primary)
            .opacity(asksUser ? 1 : PillInk.opacity(lit: hovering))
            .animation(Theme.hover, value: hovering)
            .background {
                Capsule().fill(asksUser ? design.action : Color.primary.opacity(hovering ? 0.1 : 0.05))
                    .animation(Theme.value, value: working)
                    .animation(Theme.value, value: asksUser)
                    .animation(Theme.hover, value: hovering)
                if working { ActionProgressFill(fraction: progress?.fraction, neutral: true).clipShape(Capsule()) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .help(([text] + (result?.details ?? [])).joined(separator: "\n"))
        .onAppear { if reservedLabels == nil { reservedLabels = samples } }
        .onChange(of: text, initial: true) { _, now in if working, !shownWhileWorking.contains(now) { shownWhileWorking.append(now) } }
        .onChange(of: working) { _, now in if !now { shownWhileWorking = [] } }
        .task(id: result) {
            guard result?.outcome == .succeeded else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            dismiss()
        }
    }
}

/// A row's button: the row action flag's own look at rest (`RowActionFlag`), text on a faint capsule that darkens under the pointer.
/// Every button in a row uses it, in Settings and on module pages (`ButtonRow`, Check Now, the permission buttons), so a row has
/// one kind of button. Where it goes in the row is `RowFlagPlacement`.
/// The text and glyphs of the grey pill buttons: one color whose strength follows the pointer, so they fade with the capsule. Switched
/// between the `.primary` and `.secondary` styles, which do not blend, the text changed at once while the capsule faded (2026-10-19).
/// An opacity outside the label also reaches text that turns its own animations off (`ChangingText`).
enum PillInk {
    static func opacity(lit: Bool) -> Double { lit ? 1 : 0.6 }
}

struct RowFlagStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let lit = hovering || configuration.isPressed
        configuration.label
            .font(Theme.pillFont)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 18)
            .foregroundStyle(Color.primary)
            .opacity(PillInk.opacity(lit: lit))
            .background(Color.primary.opacity(lit ? 0.1 : 0.05), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .fixedSize()
            .pointerStyle(.link)
            .onHover { hovering = $0 && isEnabled }
            .animation(Theme.hover, value: hovering)
    }
}

/// Where a row's button goes (Interface rules, "Buttons"). With a figure on the right of the row (a size, a version) the button
/// stands right after the row's title, its (i), its folder and its pills, as a module row's Free does, and the figure keeps the right edge.
/// Without one, the button takes the right edge itself.
enum RowFlagPlacement: Equatable {
    case afterTitle, trailing

    static func `for`(hasTrailingFigure: Bool) -> RowFlagPlacement { hasTrailingFigure ? .afterTitle : .trailing }
}

/// Shared by the page action and row flags, so both use the same wave and measured progress animation.
struct ActionProgressFill: View {
    var fraction: Double?
    var load: LoadFill?
    /// In a grey row flag: the fill in the text's color, faint, as the flag asks nothing of the user. The page's main button keeps
    /// the action color's light form.
    var neutral = false
    @Environment(\.design) private var design
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !appearsActive)) { context in
            let wave = LoadingWave.opacity(context.date, index: 0, count: 1, loading: true, reduceMotion: reduceMotion)
            let raw = fraction ?? load?.fraction(at: context.date)
            let value = raw.flatMap { $0.isFinite ? $0 : nil }
            GeometryReader { geometry in
                if let value {
                    Rectangle().fill(neutral ? AnyShapeStyle(Color.primary.opacity(0.12)) : AnyShapeStyle(design.actionLight))
                        .frame(width: geometry.size.width * max(0.08, min(1, value)))
                        .opacity(0.7 + 0.3 * wave)
                        .animation(reduceMotion ? nil : Theme.layout, value: value)
                } else {
                    Rectangle().fill(neutral ? AnyShapeStyle(Color.primary.opacity(0.12)) : AnyShapeStyle(design.actionLight)).opacity(0.25 + 0.6 * wave)
                }
            }
        }
    }
}
