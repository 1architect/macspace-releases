import SwiftUI

/// Settings and its pages, drawn by the page itself as a module's page is (`WidgetForm`): sections of rows on one shade per group
/// (`PageRowCell`, `PageGroupShade`), in lazy stacks, so only the rows on screen are made.
///
/// A system grouped `Form` built and kept every row of a page (Recent cleanups, 263 cleanups, took 168 MB), and it draws the AppKit
/// parts of a row itself (the switch, the menu's bezel, the row's shade and separator): when a row came or went they faded on the
/// form's own timing and never moved, while the row's text slid in with the cascade (**measured**, 2026-10-20). Drawn here, the
/// whole row, its AppKit controls included, arrives and leaves together.
struct PageForm<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.pageBottomRoom) private var bottomRoom

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(subviews: content) { section in
                    section
                        .geometryGroup()
                        .transition(section.containerValues.rowCascades ? PageCascade.transition(index: 0, count: 1) : .opacity)
                }
                Color.clear.frame(height: max(bottomRoom - 20, 0))
            }
            // The grouped form's insets, as module pages draw them (`WidgetForm`).
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        // No scroll bar, as on module pages and the dashboard.
        .scrollIndicators(.never)
        .font(.system(size: 13))
        .toggleStyle(PageSwitchStyle())
        .labeledContentStyle(PageLabeledContentStyle())
    }
}

/// A section of a `PageForm`: its title, as a module page's section titles, then its rows in one group.
struct PageSection<Content: View>: View {
    let title: Text?
    var info: String?
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, info: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.info = info
        self.content = content()
    }

    init(verbatim title: String, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: title)
        self.content = content()
    }

    init(@ViewBuilder content: () -> Content) {
        title = nil
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                // The grouped-list title of macOS's System Settings: semibold, in the text's color (`WidgetForm`).
                HStack(spacing: 6) {
                    title
                    InfoButton(text: info)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 10)
            }
            Group(subviews: content) { rows in
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        row
                            .modifier(PageRowCell(index: index, fitsControls: true))
                            // Placed once for the whole cell before the cascade, as module rows are.
                            .geometryGroup()
                            .transition(row.containerValues.rowCascades ? PageCascade.transition(index: 0, count: 1) : .opacity)
                    }
                }
                .modifier(PageGroupShade())
            }
        }
    }
}

/// A switch row as a grouped form draws it: the title on the left, the form's small switch on the right.
struct PageSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            HStack(spacing: 8) {
                configuration.label.opacity(isEnabled ? 1 : 0.5)
                Spacer(minLength: 8)
                // The grouped form's switch is the mini one (36 by 16 points, **measured**), as module rows have it (`ToggleRowView`).
                Toggle(isOn: configuration.$isOn) { configuration.label }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }
}

/// A value row as a grouped form draws it: the title on the left, the value on the right, grey.
struct PageLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Spacer(minLength: 8)
            configuration.content.foregroundStyle(.secondary)
        }
    }
}

/// A menu row as a grouped form draws a Picker: the title on the left, the menu on the right, at its own width.
struct PagePicker<Selection: Hashable, Label: View, Content: View>: View {
    let selection: Binding<Selection>
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label

    init(selection: Binding<Selection>, @ViewBuilder content: @escaping () -> Content, @ViewBuilder label: @escaping () -> Label) {
        self.selection = selection
        self.content = content
        self.label = label
    }

    var body: some View {
        HStack(spacing: 8) {
            label()
            Spacer(minLength: 8)
            Picker(selection: selection, content: content, label: label)
                .labelsHidden()
                .fixedSize()
        }
    }
}

extension PagePicker where Label == Text {
    init(_ title: LocalizedStringKey, selection: Binding<Selection>, @ViewBuilder content: @escaping () -> Content) {
        self.init(selection: selection, content: content) { Text(title) }
    }

    init(verbatim title: String, selection: Binding<Selection>, @ViewBuilder content: @escaping () -> Content) {
        self.init(selection: selection, content: content) { Text(verbatim: title) }
    }
}
