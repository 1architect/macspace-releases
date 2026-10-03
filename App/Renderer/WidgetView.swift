import MacSpaceSdk
import MacSpacePlatform
import SwiftUI

/// A module's widgets as a system grouped form, the same as Settings: a header above each group, one row per item with its control on
/// the right. The form keeps its look whatever the palette and glass settings. Descriptions (subtitles, details, footnotes) are
/// tooltips; only steps to follow stay visible, in rows that open.
///
/// Sections are built in this view's own functions, not in wrapper views: the form only lays out sections it can see directly.
struct WidgetForm<Top: View>: View {
    let widgets: [ScreenWidget]
    let handler: ActionHandler
    /// Whether `top` is drawn. It goes in the first section's header: a section of its own, with no rows, changed how the form drew the
    /// next header.
    var showsTop = true
    /// Drawn above the first group, without a group of its own (the page's hero).
    @ViewBuilder var top: Top
    /// Collapsible sections the user has flipped from how they start.
    @State private var flipped: Set<String> = []
    /// The widgets that are in. Those already there when the page opens come in with the page; those that arrive later (when the
    /// module answers after the page opened, or a refresh brings new ones) rise in one after another.
    @State private var revealed: Set<String> = []

    private func expansion(_ section: SectionWidget) -> Binding<Bool> {
        Binding(get: { section.startsCollapsed == flipped.contains(section.id) },
                set: { open in
                    let flip = open == section.startsCollapsed
                    if flip { flipped.insert(section.id) } else { flipped.remove(section.id) }
                })
    }

    var body: some View {
        // The first group keeps one identity whatever the widgets are, and is there even before there are any (while the page loads):
        // the top, in its header, then stays the same view from loading to loaded, and its blocks move into place instead of being
        // drawn anew.
        let items: [Item] = widgets.isEmpty && showsTop
            ? [Item(id: Item.leading, widget: nil)]
            : widgets.enumerated().map { Item(id: $0.offset == 0 ? Item.leading : $0.element.id, widget: $0.element) }
        Form {
            ForEach(items) { item in
                section(for: item.widget, leading: showsTop && item.id == Item.leading)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { revealed = Set(widgets.map(\.id)) }
        .onChange(of: widgets.map(\.id)) { _, ids in
            revealed.formIntersection(ids)
            for (order, id) in ids.filter({ !revealed.contains($0) }).enumerated() {
                withAnimation(Theme.layout.delay(0.05 + Double(order) * 0.07)) { _ = revealed.insert(id) }
            }
        }
    }

    private struct Item: Identifiable {
        // Computed: a type nested in a generic one cannot store a static.
        static var leading: String { "leading-section" }
        let id: String
        let widget: ScreenWidget?
    }

    /// One group per widget, all built the same way, so the first one stays the same view when its widget changes kind.
    private func section(for widget: ScreenWidget?, leading: Bool) -> some View {
        let title = widget.map(Self.title) ?? (text: nil, help: nil)
        let shown = widget.map { revealed.contains($0.id) } ?? true
        return Section {
            if let widget { content(of: widget).modifier(Rise(shown: shown)) }
        } header: {
            header(title.text, help: title.help, leading: leading, shown: shown)
        }
    }

    /// The group's title and its tooltip. A part that folds names itself in its disclosure row instead.
    private static func title(_ widget: ScreenWidget) -> (text: String?, help: String?) {
        switch widget {
        case let .section(section): return section.isCollapsible ? (nil, nil) : (section.title, section.subtitle)
        case let .list(list): return (list.title, nil)
        case let .toggles(toggles): return (toggles.title, toggles.footnote)
        case let .usage(usage): return (usage.title, usage.footnote)
        case let .chart(chart): return (chart.title, nil)
        case let .steps(steps): return (steps.title, nil)
        case .banner, .button, .text: return (nil, nil)
        }
    }

    @ViewBuilder
    private func content(of widget: ScreenWidget) -> some View {
        if case let .section(section) = widget {
            if section.isCollapsible {
                // A part that folds is one disclosure row, as macOS forms show them; its rows open under it.
                DisclosureGroup(isExpanded: expansion(section)) {
                    ForEach(section.widgets) { inner in rows(for: inner) }
                } label: {
                    Text(section.title).help(section.subtitle ?? "")
                }
            } else {
                ForEach(section.widgets) { inner in rows(for: inner) }
            }
        } else {
            rows(for: widget)
        }
    }

    /// A section's header: its title (the description as the tooltip), with the page's top above it on the first section.
    @ViewBuilder
    private func header(_ title: String?, help: String? = nil, leading: Bool, shown: Bool = true) -> some View {
        let hasTitle = !(title ?? "").isEmpty
        if leading {
            // The top stays put; only the title rises in with its rows.
            VStack(alignment: .leading, spacing: 14) {
                top
                if hasTitle, let title { Text(title).help(help ?? "").modifier(Rise(shown: shown)) }
            }
        } else if hasTitle, let title {
            Text(title).help(help ?? "").modifier(Rise(shown: shown))
        }
    }

    /// The rows a widget contributes to a group.
    @ViewBuilder
    private func rows(for widget: ScreenWidget) -> some View {
        switch widget {
        case let .banner(banner): BannerRow(banner: banner, handler: handler)
        case let .usage(usage): UsageBarView(usage: usage)
        case let .chart(chart): BarChartView(chart: chart)
        case let .list(list):
            if list.rows.isEmpty, let empty = list.emptyMessage { Text(empty).foregroundStyle(.secondary) }
            ForEach(list.rows) { row in RowView(row: row, handler: handler) }
        case let .toggles(toggles):
            ForEach(toggles.rows) { row in ToggleRowView(row: row, handler: handler) }
        case let .button(button): ButtonRow(button: button, handler: handler)
        case let .steps(steps):
            ForEach(Array(steps.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                    Text(step)
                }
            }
        case let .text(text): TextWidgetView(text: text)
        case let .section(section):
            ForEach(section.widgets) { inner in AnyView(WidgetRows(widget: inner, handler: handler)) }
        }
    }
}

/// A part of the page coming in: it rises a little as it fades in.
private struct Rise: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
    }
}

/// The rows of a widget nested two sections deep (rare): drawn as plain rows.
private struct WidgetRows: View {
    let widget: ScreenWidget
    let handler: ActionHandler

    var body: some View {
        switch widget {
        case let .list(list): ForEach(list.rows) { RowView(row: $0, handler: handler) }
        case let .toggles(toggles): ForEach(toggles.rows) { ToggleRowView(row: $0, handler: handler) }
        case let .button(button): ButtonRow(button: button, handler: handler)
        case let .banner(banner): BannerRow(banner: banner, handler: handler)
        case let .text(text): TextWidgetView(text: text)
        default: EmptyView()
        }
    }
}

/// Joins the parts of a description into one tooltip.
enum Tooltip {
    static func join(_ parts: String?...) -> String? {
        let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }
}

// MARK: Rows

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

/// A notice: icon, title and action. Its message is what the notice says, so it stays visible.
struct BannerRow: View {
    let banner: Banner
    let handler: ActionHandler

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Palette.symbol(banner.severity)).foregroundStyle(Palette.color(banner.severity))
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).fontWeight(.semibold)
                if let message = banner.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let action = banner.action { ActionButton(action: action, compact: true, handler: handler) }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
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
            .contentShape(Rectangle())
            .help(Tooltip.join(row.subtitle, row.detail) ?? "")
            .onTapGesture { if !row.steps.isEmpty { withAnimation(Theme.hover) { expanded.toggle() } } }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(row.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step)
                        }
                        .font(.callout)
                    }
                }
                .padding(.leading, row.symbol == nil ? 0 : 28)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// A switch row, as in Settings. It asks first when the module wants a confirmation.
struct ToggleRowView: View {
    let row: ToggleRow
    let handler: ActionHandler
    @State private var pending: Bool?

    var body: some View {
        Toggle(isOn: Binding(get: { row.isOn }, set: { flip(to: $0) })) {
            HStack(spacing: 8) {
                Text(row.title)
                if let badge = row.badge { BadgeView(badge: badge) }
            }
        }
        .disabled(!row.isEnabled)
        .help(Tooltip.join(row.subtitle, row.detail) ?? "")
        .confirmationDialog(row.action.confirmation?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button(row.action.confirmation?.confirmTitle ?? "OK") {
                if let value = pending { handler(row.action, ["value": value ? "true" : "false"]) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(row.action.confirmation?.message ?? "")
        }
    }

    private func flip(to value: Bool) {
        if row.action.confirmation != nil { pending = value } else { handler(row.action, ["value": value ? "true" : "false"]) }
    }
}

/// A button on its own: the row names the action, the button on the right says the verb; its footnote is the tooltip.
struct ButtonRow: View {
    let button: ButtonWidget
    let handler: ActionHandler

    var body: some View {
        HStack(spacing: 10) {
            if let symbol = button.action.symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18) }
            Text(button.action.title).lineLimit(1)
            Spacer(minLength: 8)
            ActionButton(action: Action(id: button.action.id, title: verb, role: button.action.role, parameters: button.action.parameters,
                                        confirmation: button.action.confirmation, requires: button.action.requires),
                         compact: true, handler: handler)
        }
        .help(button.footnote ?? "")
    }

    private var verb: String {
        button.action.title.split(separator: " ").first.map(String.init) ?? button.action.title
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

struct TextWidgetView: View {
    let text: TextWidget

    var body: some View {
        switch text.style {
        case .title: Text(text.text).font(.title2.weight(.semibold))
        case .body: Text(text.text)
        case .caption: Text(text.text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
