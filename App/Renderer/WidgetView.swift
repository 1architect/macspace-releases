import MacSpaceSdk
import MacSpacePlatform
import SwiftUI

/// Draws one widget on a page. Everything follows the grouped look of Settings: a bold header above a rounded group, one row per
/// item with its control on the right, hairlines between rows. Descriptions (subtitles, details, footnotes) are tooltips, not text
/// on the page; only steps to follow stay visible, in rows that open.
struct WidgetView: View {
    let widget: ScreenWidget
    let handler: ActionHandler

    var body: some View {
        switch widget {
        case let .banner(banner): BannerView(banner: banner, handler: handler)
        case let .usage(usage): FormBlock(title: usage.title, help: usage.footnote) { UsageBarView(usage: usage).padding(12) }
        case let .chart(chart): FormBlock(title: chart.title) { BarChartView(chart: chart).padding(12) }
        case let .list(list): ListWidgetView(list: list, handler: handler)
        case let .toggles(toggles): ToggleListView(list: toggles, handler: handler)
        case let .button(button): ButtonWidgetView(button: button, handler: handler)
        case let .steps(steps): StepsView(steps: steps)
        case let .text(text): TextWidgetView(text: text)
        case let .section(section): SectionView(section: section, handler: handler)
        }
    }
}

// MARK: Form parts

/// The rounded group rows sit in, as in Settings: a faint panel, or Liquid Glass when glass is on.
struct FormGroup<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.design) private var design

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if design.glass { Color.clear.glassEffect(.regular, in: shape) } else { shape.fill(.primary.opacity(0.055)) }
            }
    }
}

/// The bold header above a group. Its description is the tooltip.
struct FormHeader<Trailing: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}

extension FormHeader where Trailing == EmptyView {
    init(title: String, help: String? = nil) {
        self.init(title: title, help: help) { EmptyView() }
    }
}

/// A header (when there is a title) and a group holding `content`.
struct FormBlock<Content: View>: View {
    var title: String?
    var help: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title, !title.isEmpty { FormHeader(title: title, help: help) }
            FormGroup { content }
        }
    }
}

/// One row of a group: at least the height of a Settings row, its parts on one line.
struct FormRow<Content: View>: View {
    var help: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .frame(minHeight: 22)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .help(help ?? "")
    }
}

/// The one switch every page and Settings use, so they are the same size and color everywhere.
struct FormSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// A row with a title (and optional symbol) and a switch on the right. `status` lines stay visible (errors, why it is off); the
/// description is the tooltip.
struct FormToggleRow: View {
    let title: String
    var symbol: String?
    var help: String?
    var status: [(text: String, color: Color)] = []
    @Binding var isOn: Bool

    var body: some View {
        FormRow(help: help) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                ForEach(Array(status.enumerated()), id: \.offset) { _, line in
                    Text(line.text).font(.caption).foregroundStyle(line.color)
                }
            }
            Spacer(minLength: 8)
            FormSwitch(isOn: $isOn)
        }
    }
}

/// The hairline between rows, inset like Settings.
struct FormDivider: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.1)).frame(height: 0.5).padding(.leading, 10)
    }
}

/// Joins the parts of a description into one tooltip.
enum Tooltip {
    static func join(_ parts: String?...) -> String? {
        let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }
}

/// Kept for the few places that want a plain padded group (progress).
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        FormGroup { content.padding(12) }
    }
}

extension View {
    /// The group everything on a page sits in.
    func glassCard() -> some View { modifier(PageCard()) }
}

private struct PageCard: ViewModifier {
    @Environment(\.design) private var design

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if design.glass {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.primary.opacity(0.055), in: shape)
        }
    }
}

// MARK: Widgets

struct BadgeView: View {
    let badge: Badge

    var body: some View {
        Text(badge.text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(Palette.color(badge.tone).opacity(badge.tone == .neutral ? 0.3 : 0.55), in: Capsule())
    }
}

/// A notice: icon, title and action in one row. Its message is what the notice says, so it stays visible.
struct BannerView: View {
    let banner: Banner
    let handler: ActionHandler

    var body: some View {
        FormGroup {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Palette.symbol(banner.severity)).foregroundStyle(Palette.color(banner.severity))
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).font(.system(size: 13, weight: .semibold))
                    if let message = banner.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if let action = banner.action { ActionButton(action: action, compact: true, handler: handler) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
    }
}

struct UsageBarView: View {
    let usage: UsageBar

    private var total: Double {
        Double(usage.totalBytes ?? usage.segments.reduce(0) { $0 + $1.bytes })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(usage.segments) { segment in
                        Rectangle()
                            .fill(Palette.color(segment.tone))
                            .frame(width: total > 0 ? max(2, proxy.size.width * Double(segment.bytes) / total) : 0)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .background(.primary.opacity(0.14))
                .clipShape(Capsule())
            }
            .frame(height: 14)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(usage.segments) { segment in
                    HStack(spacing: 6) {
                        Circle().fill(Palette.color(segment.tone)).frame(width: 8, height: 8)
                        Text(segment.label).font(.caption)
                        Text(ByteFormat.string(segment.bytes)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct BarChartView: View {
    let chart: BarChart

    var body: some View {
        let maximum = max(chart.bars.map(\.value).max() ?? 0, .leastNonzeroMagnitude)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chart.bars) { bar in
                HStack(spacing: 10) {
                    Text(bar.label).font(.callout).frame(width: 150, alignment: .leading).lineLimit(1)
                    GeometryReader { proxy in
                        Capsule().fill(Palette.color(bar.tone))
                            .frame(width: max(3, proxy.size.width * bar.value / maximum))
                    }
                    .frame(height: 8)
                    Text(bar.valueLabel).font(.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
                }
            }
        }
    }
}

struct ListWidgetView: View {
    let list: ListWidget
    let handler: ActionHandler

    var body: some View {
        FormBlock(title: list.title) {
            if list.rows.isEmpty, let empty = list.emptyMessage {
                FormRow { Text(empty).foregroundStyle(.secondary) }
            }
            ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { FormDivider() }
                RowView(row: row, handler: handler)
            }
        }
    }
}

/// A list row: symbol, title, badge, value and actions. Its subtitle and detail are the tooltip; when it has steps, it opens to show
/// them.
struct RowView: View {
    let row: Row
    let handler: ActionHandler
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormRow(help: Tooltip.join(row.subtitle, row.detail)) {
                if let symbol = row.symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18) }
                Text(row.title).lineLimit(1)
                if let badge = row.badge { BadgeView(badge: badge) }
                Spacer(minLength: 8)
                if let trailing = row.trailing { Text(trailing).monospacedDigit().foregroundStyle(.secondary) }
                ForEach(Array(row.actions.enumerated()), id: \.offset) { _, action in
                    ActionButton(action: action, compact: true, handler: handler)
                }
                if !row.steps.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .onTapGesture { if !row.steps.isEmpty { withAnimation(Theme.hover) { expanded.toggle() } } }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(row.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step)
                        }
                        .font(.callout)
                    }
                }
                .padding(.leading, row.symbol == nil ? 10 : 38)
                .padding(.trailing, 10)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct ToggleListView: View {
    let list: ToggleList
    let handler: ActionHandler
    @State private var pending: PendingToggle?

    /// A flip waiting for the user to confirm it.
    struct PendingToggle: Identifiable {
        let id = UUID()
        let action: Action
        let value: Bool
    }

    private func flip(_ row: ToggleRow, to value: Bool) {
        if row.action.confirmation != nil { pending = PendingToggle(action: row.action, value: value) }
        else { handler(row.action, ["value": value ? "true" : "false"]) }
    }

    var body: some View {
        FormBlock(title: list.title, help: list.footnote) {
            ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { FormDivider() }
                FormRow(help: Tooltip.join(row.subtitle, row.detail)) {
                    Text(row.title).lineLimit(1)
                    if let badge = row.badge { BadgeView(badge: badge) }
                    Spacer(minLength: 8)
                    FormSwitch(isOn: Binding(get: { row.isOn }, set: { flip(row, to: $0) }))
                        .disabled(!row.isEnabled)
                }
            }
        }
        .confirmationDialog(pending?.action.confirmation?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { toggle in
            Button(toggle.action.confirmation?.confirmTitle ?? "OK") { handler(toggle.action, ["value": toggle.value ? "true" : "false"]) }
            Button("Cancel", role: .cancel) {}
        } message: { toggle in
            Text(toggle.action.confirmation?.message ?? "")
        }
    }
}

/// A button on its own: a row with the button on the right; its footnote is the tooltip.
struct ButtonWidgetView: View {
    let button: ButtonWidget
    let handler: ActionHandler

    var body: some View {
        FormGroup {
            FormRow(help: button.footnote) {
                if let symbol = button.action.symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18) }
                Text(button.action.title).lineLimit(1)
                Spacer(minLength: 8)
                ActionButton(action: Action(id: button.action.id, title: actionTitle, role: button.action.role, parameters: button.action.parameters,
                                            confirmation: button.action.confirmation, requires: button.action.requires),
                             compact: true, handler: handler)
            }
        }
    }

    /// The row names the action; the button says the verb.
    private var actionTitle: String {
        button.action.title.split(separator: " ").first.map(String.init) ?? button.action.title
    }
}

struct StepsView: View {
    let steps: StepsWidget

    var body: some View {
        FormBlock(title: steps.title) {
            ForEach(Array(steps.steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { FormDivider() }
                FormRow {
                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                    Text(step)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct TextWidgetView: View {
    let text: TextWidget

    var body: some View {
        switch text.style {
        case .title: Text(text.text).font(.title2.weight(.semibold))
        case .body: Text(text.text).font(.body)
        case .caption: Text(text.text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
        }
    }
}

/// A titled part of a page: the header (its subtitle the tooltip, a chevron when it folds), then its widgets.
struct SectionView: View {
    let section: SectionWidget
    let handler: ActionHandler
    @State private var collapsed: Bool

    init(section: SectionWidget, handler: @escaping ActionHandler) {
        self.section = section
        self.handler = handler
        _collapsed = State(initialValue: section.isCollapsible && section.startsCollapsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormHeader(title: section.title, help: section.subtitle) {
                if section.isCollapsible {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }
            }
            .onTapGesture { if section.isCollapsible { withAnimation(Theme.hover) { collapsed.toggle() } } }
            if !collapsed {
                ForEach(section.widgets) { WidgetView(widget: $0, handler: handler) }
            }
        }
    }
}
