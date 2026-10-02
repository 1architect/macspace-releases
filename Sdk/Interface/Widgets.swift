import Foundation

/// How a colored element should read. The app maps tones to its palette, so modules never pick colors.
public enum Tone: Codable, Equatable, Sendable {
    case neutral
    case accent
    case positive
    case caution
    case critical
    /// One of the app's chart colors; modules number their series 0, 1, 2…
    case series(Int)
}

public struct Badge: Codable, Equatable, Sendable {
    public var text: String
    public var tone: Tone

    public init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }
}

public struct Confirmation: Codable, Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirmTitle: String

    public init(title: String, message: String, confirmTitle: String) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
    }
}

public enum ActionRole: String, Codable, Sendable {
    case normal
    case prominent
    case destructive
}

/// Something the user can trigger. The app asks for confirmation first when `confirmation` is set, and for any missing
/// `requires` permission before it calls the module.
public struct Action: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String?
    public var role: ActionRole
    public var parameters: [String: String]
    public var confirmation: Confirmation?
    public var requires: [Permission]

    public init(id: String, title: String, symbol: String? = nil, role: ActionRole = .normal, parameters: [String: String] = [:],
                confirmation: Confirmation? = nil, requires: [Permission] = []) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.role = role
        self.parameters = parameters
        self.confirmation = confirmation
        self.requires = requires
    }
}

/// A module's page. The app draws it on the module's tile, grown to fill the window: the tile's title and status stay in the corner,
/// so the page needs no header.
public struct Screen: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    /// The big bar at the top of the page, drawn without a card.
    public var hero: UsageBar?
    /// The page's one main action, pinned at the bottom (the "Clean" pill). Every other action sits next to what it acts on.
    public var primary: Action?
    public var widgets: [ScreenWidget]

    public init(title: String, subtitle: String? = nil, hero: UsageBar? = nil, primary: Action? = nil, widgets: [ScreenWidget]) {
        self.title = title
        self.subtitle = subtitle
        self.hero = hero
        self.primary = primary
        self.widgets = widgets
    }
}

/// The building blocks of a module's UI. Every widget has an `id` that stays stable between refreshes.
public enum ScreenWidget: Codable, Equatable, Sendable, Identifiable {
    case banner(Banner)
    case usage(UsageBar)
    case chart(BarChart)
    case list(ListWidget)
    case toggles(ToggleList)
    case button(ButtonWidget)
    case steps(StepsWidget)
    case text(TextWidget)
    case section(SectionWidget)

    public var id: String {
        switch self {
        case let .banner(widget): return widget.id
        case let .usage(widget): return widget.id
        case let .chart(widget): return widget.id
        case let .list(widget): return widget.id
        case let .toggles(widget): return widget.id
        case let .button(widget): return widget.id
        case let .steps(widget): return widget.id
        case let .text(widget): return widget.id
        case let .section(widget): return widget.id
        }
    }
}

public struct Banner: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case info, success, warning, critical }

    public var id: String
    public var severity: Severity
    public var title: String
    public var message: String?
    public var action: Action?

    public init(id: String, severity: Severity, title: String, message: String? = nil, action: Action? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.message = message
        self.action = action
    }
}

public struct UsageSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var bytes: UInt64
    public var tone: Tone

    public init(id: String, label: String, bytes: UInt64, tone: Tone) {
        self.id = id
        self.label = label
        self.bytes = bytes
        self.tone = tone
    }
}

/// A segmented bar with a legend: how a total splits into parts, in bytes.
public struct UsageBar: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// The whole the segments belong to (the volume size, say); the bar is sized to it when set, else to the sum.
    public var totalBytes: UInt64?
    public var segments: [UsageSegment]
    public var footnote: String?

    public init(id: String, title: String, totalBytes: UInt64? = nil, segments: [UsageSegment], footnote: String? = nil) {
        self.id = id
        self.title = title
        self.totalBytes = totalBytes
        self.segments = segments
        self.footnote = footnote
    }
}

public struct Bar: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var value: Double
    public var valueLabel: String
    public var tone: Tone

    public init(id: String, label: String, value: Double, valueLabel: String, tone: Tone = .accent) {
        self.id = id
        self.label = label
        self.value = value
        self.valueLabel = valueLabel
        self.tone = tone
    }
}

/// Horizontal bars ranked by value.
public struct BarChart: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var bars: [Bar]

    public init(id: String, title: String, bars: [Bar]) {
        self.id = id
        self.title = title
        self.bars = bars
    }
}

public struct Row: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var trailing: String?
    public var badge: Badge?
    public var symbol: String?
    /// Longer text shown when the row is expanded.
    public var detail: String?
    /// Steps shown when the row is expanded (for example a manual cleanup guide).
    public var steps: [String]
    public var actions: [Action]

    public init(id: String, title: String, subtitle: String? = nil, trailing: String? = nil, badge: Badge? = nil, symbol: String? = nil,
                detail: String? = nil, steps: [String] = [], actions: [Action] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.badge = badge
        self.symbol = symbol
        self.detail = detail
        self.steps = steps
        self.actions = actions
    }
}

public struct ListWidget: Codable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var emptyMessage: String?
    public var rows: [Row]

    public init(id: String, title: String? = nil, emptyMessage: String? = nil, rows: [Row]) {
        self.id = id
        self.title = title
        self.emptyMessage = emptyMessage
        self.rows = rows
    }
}

public struct ToggleRow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var isOn: Bool
    public var isEnabled: Bool
    public var badge: Badge?
    public var detail: String?
    /// Run when the user flips the switch. The app adds `value` = `true` or `false` to the parameters.
    public var action: Action

    public init(id: String, title: String, subtitle: String? = nil, isOn: Bool, isEnabled: Bool = true, badge: Badge? = nil,
                detail: String? = nil, action: Action) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.badge = badge
        self.detail = detail
        self.action = action
    }
}

public struct ToggleList: Codable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var footnote: String?
    public var rows: [ToggleRow]

    public init(id: String, title: String? = nil, footnote: String? = nil, rows: [ToggleRow]) {
        self.id = id
        self.title = title
        self.footnote = footnote
        self.rows = rows
    }
}

public struct ButtonWidget: Codable, Equatable, Sendable {
    public var id: String
    public var action: Action
    public var footnote: String?

    public init(id: String, action: Action, footnote: String? = nil) {
        self.id = id
        self.action = action
        self.footnote = footnote
    }
}

public struct StepsWidget: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var steps: [String]

    public init(id: String, title: String, steps: [String]) {
        self.id = id
        self.title = title
        self.steps = steps
    }
}

public struct TextWidget: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable { case title, body, caption }

    public var id: String
    public var text: String
    public var style: Style

    public init(id: String, text: String, style: Style = .body) {
        self.id = id
        self.text = text
        self.style = style
    }
}

public struct SectionWidget: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var widgets: [ScreenWidget]
    public var isCollapsible: Bool
    public var startsCollapsed: Bool

    public init(id: String, title: String, subtitle: String? = nil, widgets: [ScreenWidget], isCollapsible: Bool = false, startsCollapsed: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.widgets = widgets
        self.isCollapsible = isCollapsible
        self.startsCollapsed = startsCollapsed
    }
}
