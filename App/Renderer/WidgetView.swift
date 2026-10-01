import MacSpaceSdk
import MacSpacePlatform
import SwiftUI

/// Draws one widget. All widgets share the same card look, so modules cannot break the app's design.
struct WidgetView: View {
    let widget: ScreenWidget
    let handler: ActionHandler

    var body: some View {
        switch widget {
        case let .banner(banner): BannerView(banner: banner, handler: handler)
        case let .usage(usage): Card { UsageBarView(usage: usage) }
        case let .chart(chart): Card { BarChartView(chart: chart) }
        case let .list(list): Card { ListWidgetView(list: list, handler: handler) }
        case let .toggles(toggles): Card { ToggleListView(list: toggles, handler: handler) }
        case let .button(button): ButtonWidgetView(button: button, handler: handler)
        case let .steps(steps): Card { StepsView(steps: steps) }
        case let .text(text): TextWidgetView(text: text)
        case let .section(section): SectionView(section: section, handler: handler)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct BadgeView: View {
    let badge: Badge

    var body: some View {
        Text(badge.text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Palette.color(badge.tone))
            .background(Palette.color(badge.tone).opacity(0.15), in: Capsule())
    }
}

struct BannerView: View {
    let banner: Banner
    let handler: ActionHandler

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Palette.symbol(banner.severity)).foregroundStyle(Palette.color(banner.severity))
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.headline)
                if let message = banner.message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let action = banner.action { ActionButton(action: action, compact: true, handler: handler) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.color(banner.severity).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct UsageBarView: View {
    let usage: UsageBar

    private var total: Double {
        Double(usage.totalBytes ?? usage.segments.reduce(0) { $0 + $1.bytes })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(usage.title).font(.headline)
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
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 12)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(usage.segments) { segment in
                    HStack(spacing: 6) {
                        Circle().fill(Palette.color(segment.tone)).frame(width: 8, height: 8)
                        Text(segment.label).font(.caption)
                        Text(ByteFormat.string(segment.bytes)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let footnote = usage.footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct BarChartView: View {
    let chart: BarChart

    var body: some View {
        let maximum = max(chart.bars.map(\.value).max() ?? 0, .leastNonzeroMagnitude)
        VStack(alignment: .leading, spacing: 8) {
            Text(chart.title).font(.headline)
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
        VStack(alignment: .leading, spacing: 0) {
            if let title = list.title { Text(title).font(.headline).padding(.bottom, 8) }
            if list.rows.isEmpty, let empty = list.emptyMessage {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.vertical, 6) }
                RowView(row: row, handler: handler)
            }
        }
    }
}

struct RowView: View {
    let row: Row
    let handler: ActionHandler
    @State private var expanded = false

    private var expandable: Bool { row.detail != nil || !row.steps.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let symbol = row.symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.body)
                    if let subtitle = row.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if let badge = row.badge { BadgeView(badge: badge) }
                if let trailing = row.trailing { Text(trailing).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                ForEach(Array(row.actions.enumerated()), id: \.offset) { _, action in
                    ActionButton(action: action, compact: true, handler: handler)
                }
                if expandable {
                    Button { withAnimation { expanded.toggle() } } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = row.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                    ForEach(Array(row.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Text(step).font(.callout)
                        }
                    }
                }
                .padding(.leading, row.symbol == nil ? 0 : 30)
            }
        }
    }
}

struct ToggleListView: View {
    let list: ToggleList
    let handler: ActionHandler
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = list.title { Text(title).font(.headline).padding(.bottom, 8) }
            ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.vertical, 6) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                            if let subtitle = row.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 8)
                        if let badge = row.badge { BadgeView(badge: badge) }
                        if row.detail != nil {
                            Button { withAnimation { toggleExpanded(row.id) } } label: {
                                Image(systemName: expanded.contains(row.id) ? "chevron.up" : "chevron.down")
                            }
                            .buttonStyle(.borderless)
                        }
                        Toggle("", isOn: Binding(get: { row.isOn }, set: { handler(row.action, ["value": $0 ? "true" : "false"]) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(!row.isEnabled)
                    }
                    if expanded.contains(row.id), let detail = row.detail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if let footnote = list.footnote { Text(footnote).font(.caption).foregroundStyle(.secondary).padding(.top, 8) }
        }
    }

    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

struct ButtonWidgetView: View {
    let button: ButtonWidget
    let handler: ActionHandler

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ActionButton(action: button.action, handler: handler)
            if let footnote = button.footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StepsView: View {
    let steps: StepsWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(steps.title).font(.headline)
            ForEach(Array(steps.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(step).font(.callout)
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
        case .caption: Text(text.text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title).font(.title3.weight(.semibold))
                    if let subtitle = section.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if section.isCollapsible {
                    Button { withAnimation { collapsed.toggle() } } label: { Image(systemName: collapsed ? "chevron.down" : "chevron.up") }
                        .buttonStyle(.borderless)
                }
            }
            if !collapsed {
                ForEach(section.widgets) { WidgetView(widget: $0, handler: handler) }
            }
        }
    }
}
