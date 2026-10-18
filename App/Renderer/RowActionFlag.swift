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

    private var actions: [Action] {
        if !row.actions.isEmpty { return row.actions }
        if activity.rowID == row.id, let action = activity.action { return [action] }
        return []
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions, id: \.id) { action in
                RowActionFlag(action: action,
                              usesActivityText: row.activity != nil,
                              progress: row.activity ?? (activity.rowID == row.id ? activity.progress ?? ActionProgress(message: action.workingTitle ?? "") : nil),
                              result: activity.resultID == row.id ? activity.result : nil,
                              dismiss: activity.dismiss) {
                    guard ConfirmationAlert.ask(action) else { return }
                    _ = await handler(action, [:], false, row.id)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if actions.isEmpty, activity.resultID == row.id, let result = activity.result, !result.message.isEmpty {
                StatusFlag(text: result.message, tone: result.outcome == .succeeded ? .neutral : .caution)
                    .onTapGesture(perform: activity.dismiss)
                    .transition(.opacity)
            }
        }
        .animation(Theme.layout, value: actions.map(\.id))
    }
}

private struct RowActionFlag: View {
    let action: Action
    var usesActivityText = false
    let progress: ActionProgress?
    let result: ActionResult?
    let dismiss: () -> Void
    let run: @MainActor () async -> Void
    @State private var hovering = false
    @Environment(\.design) private var design

    private var working: Bool { progress != nil }
    private var text: String {
        if let progress {
            let title = progress.message.isEmpty ? action.workingTitle ?? String(localized: "Working") : progress.message
            if usesActivityText { return title }
            return progress.fraction.map { title + " \(Int((min(max($0, 0), 1) * 100).rounded()))%" } ?? title
        }
        if let result, !result.message.isEmpty { return result.message }
        return action.title
    }

    var body: some View {
        Button {
            if result != nil { dismiss() } else if !working { Task { await run() } }
        } label: {
            ChangingText(text: text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 18)
                .foregroundStyle(working || result != nil ? AnyShapeStyle(design.actionDeep) : AnyShapeStyle(hovering ? .primary : .secondary))
                .background {
                    Capsule().fill(working || result != nil ? design.action : Color.primary.opacity(hovering ? 0.1 : 0.05))
                    if working { ActionProgressFill(fraction: progress?.fraction).clipShape(Capsule()) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
        .animation(Theme.value, value: working)
        .help(result?.details.joined(separator: "\n") ?? "")
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
            let value = fraction ?? load?.fraction(at: context.date)
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
