import MacSpaceSdk
import SwiftUI

struct RowActivity {
    var rowID: String?
    var action: Action?
    var progress: ActionProgress?
    var resultID: String?
    var result: ActionResult?
    var dismiss: () -> Void = {}
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
        if !row.actions.isEmpty { return row.actions }
        if activity.rowID == row.id, let action = activity.action { return [action] }
        if activity.resultID == row.id { return retainedActions }
        return []
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions, id: \.id) { action in
                RowActionFlag(action: action,
                              progress: row.activity ?? (activity.rowID == row.id ? activity.progress ?? ActionProgress(message: action.workingTitle ?? "") : nil),
                              result: activity.resultID == row.id ? activity.result : nil,
                              dismiss: activity.dismiss) {
                    guard ConfirmationAlert.ask(action) else { return }
                    _ = await handler(action, [:], false, row.id)
                }
                .transition(PageCascade.transition(index: actions.firstIndex(where: { $0.id == action.id }) ?? 0, count: actions.count))
            }
            if actions.isEmpty, activity.resultID == row.id, let result = activity.result, !result.message.isEmpty {
                StatusFlag(text: result.message, tone: result.outcome == .succeeded ? .neutral : .caution)
                    .onTapGesture(perform: activity.dismiss)
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
    @Environment(\.design) private var design

    private var working: Bool { progress != nil }
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

    var body: some View {
        Button {
            if result != nil { dismiss() } else if !working { Task { await run() } }
        } label: {
            PillMorph {
                ReservedPillLabel(samples: reservedLabels ?? samples, reserveWidth: working || result != nil) {
                    ChangingText(text: text)
                }
            }
            .environment(\.textChangeDelay, 0)
            .foregroundStyle(working || result != nil ? AnyShapeStyle(design.actionDeep) : AnyShapeStyle(hovering ? .primary : .secondary))
            .background {
                Capsule().fill(working || result != nil ? design.action : Color.primary.opacity(hovering ? 0.1 : 0.05))
                    .animation(Theme.value, value: working)
                    .animation(Theme.hover, value: hovering)
                if working { ActionProgressFill(fraction: progress?.fraction).clipShape(Capsule()) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .help(([text] + (result?.details ?? [])).joined(separator: "\n"))
        .onAppear { if reservedLabels == nil { reservedLabels = samples } }
        .task(id: result) {
            guard result?.outcome == .succeeded else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            dismiss()
        }
    }
}

/// Shared by the page action and row flags, so both use the same wave and measured progress animation.
struct ActionProgressFill: View {
    var fraction: Double?
    var load: LoadFill?
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
                    Rectangle().fill(design.actionLight)
                        .frame(width: geometry.size.width * max(0.08, min(1, value)))
                        .opacity(0.7 + 0.3 * wave)
                        .animation(reduceMotion ? nil : Theme.layout, value: value)
                } else {
                    Rectangle().fill(design.actionLight).opacity(0.25 + 0.6 * wave)
                }
            }
        }
    }
}
