import CoreText
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

/// A fact about an item now, as a pill: its state, its kind. What the state means right now (why it is not verified, what is
/// waiting) goes in `help`, the pill's hover tag, never in the item's (i), which holds only what the item is (`InfoText`).
///
/// Every pill says whether it asks something of the user (`Kind`): the app draws only those in the action color, so orange always
/// means "you have something to do". "Kept by macOS" and "Cannot be undone" were orange and said nothing to do (2026-10-19).
public struct Badge: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        /// Describes the item; nothing for the user to do. Grey.
        case info
        /// The user has something to do (restart, approve, switch it off elsewhere); `help` says what. In the action color.
        case action
    }

    /// The pills every module shares, which the app recognizes whatever their text (`freeingInBackground`).
    public enum Role: String, Codable, Equatable, Sendable {
        case freeingInBackground
    }

    public var text: String
    public var kind: Kind
    public var help: String?
    public var role: Role?

    /// `kind` has no default: each pill decides whether it asks something of the user.
    public init(_ text: String, _ kind: Kind, help: String? = nil) {
        self.text = text
        self.kind = kind
        self.help = help
    }
    private enum CodingKeys: String, CodingKey { case text, kind, help, role }

    /// A pill saved before pills had a kind (with a `tone` instead) reads as a description.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .info
        help = try container.decodeIfPresent(String.self, forKey: .help)
        role = try container.decodeIfPresent(Role.self, forKey: .role)
    }
}

extension Badge {
    /// The one pill of an item that only a restart of the Mac completes (a setting macOS reads at startup, models a running service
    /// holds): "Restart required", in the action color, with `help` saying why when there is more to say. Every module uses this
    /// one, never a pill in its own words: Debloat said "After restart" and Siri "Restart required", in different colors
    /// (2026-10-20). Pair it with `Action.restart` as the page's main action.
    public static func restartRequired(help: String? = nil) -> Badge {
        Badge(String(localized: "Restart required"), .action, help: help ?? String(localized: "Restart your Mac to apply this change."))
    }

    /// The one pill of space MacSpace is freeing by itself while the row stays (asking macOS again, deleting models as soon as macOS
    /// lets go): "Freeing in the background", grey like every pill that asks nothing, with `help` saying what holds it up when
    /// something does. Every module uses this one, in a row's or a switch's pills, never a pill or a working flag of its own: Siri
    /// said "Freeing space" in a grey pill before the (i) while System Data and Other System Files said "Freeing in the background"
    /// in a darker working flag after it (2026-10-20). A row with it offers no button meanwhile (the app hides its flags), and a
    /// Free that ends handing its work to it continues in the row rather than saying All done.
    public static func freeingInBackground(help: String? = nil) -> Badge {
        var badge = Badge(String(localized: "Freeing in the background"), .info, help: help)
        badge.role = .freeingInBackground
        return badge
    }
}

extension Row {
    /// MacSpace is freeing the row's space by itself (`Badge.freeingInBackground`).
    public var isFreeingInBackground: Bool { badges.contains { $0.role == .freeingInBackground } }
}

/// Titles of lists and sections (`ListWidget.title`, `ToggleList.title`, `SectionWidget.title`, `UsageBar.title`): every page draws
/// them as macOS's System Settings draws its grouped lists, semibold in the text's color, the same in Settings and in every module.
/// A title names the group in a few words ("Models", "Free now"); it is not a sentence and carries no count or state.
///
/// The rule for every text the app shows behind an (i): `Row.detail`, `ToggleRow.detail`, `SectionWidget.subtitle`, `UsageBar.footnote`,
/// `ToggleList.footnote` and `ButtonWidget.footnote`. It says what the item is and what acting on it does, the same whatever its state:
/// no sizes, counts, dates, file lists or current state (those are the row's figure, subtitle and badges, and a badge's `help`). At most
/// `maximumLines` lines in the balloon, ideally `idealLines`; the app shows no more than `maximumLines`. `steps` are kept apart.
/// Never a list: no line, and no step, starts with a bullet, a dash or a number ("1.", "2)"). Sentences say it; the app numbers
/// nothing either (2026-10-20).
public enum InfoText {
    public static let maximumLines = 5
    public static let idealLines = 3
    /// The balloon's text width in points and the callout size it is set in, for measuring.
    public static let balloonWidth: Double = 290
    public static let fontSize: Double = 13

    /// How many lines `text` takes in the balloon, measured with the system font as the app sets it.
    public static func lineCount(_ text: String) -> Int {
        let font = CTFontCreateUIFontForLanguage(.system, CGFloat(fontSize), nil)!
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: balloonWidth, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        return (CTFrameGetLines(frame) as? [CTLine])?.count ?? 0
    }

    /// The info texts on a page longer than the rule allows; empty when the page keeps it. Modules check their pages with it.
    public static func violations(in screen: Screen) -> [String] {
        all(in: screen).filter { lineCount($0) > maximumLines } + (all(in: screen) + steps(in: screen)).filter(isList)
    }

    /// A text with a line that starts as a list item: a bullet, a dash, an asterisk, or a number followed by "." or ")".
    public static func isList(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let first = trimmed.first, "•‣◦▪︎-–—*·".contains(first) { return true }
            let digits = trimmed.prefix { $0.isNumber }
            guard !digits.isEmpty, let mark = trimmed.dropFirst(digits.count).first else { return false }
            return mark == "." || mark == ")"
        }
    }

    /// Every row's steps on a page, which its (i) shows after the text.
    static func steps(in screen: Screen) -> [String] {
        var steps: [String] = []
        func visitRow(_ row: Row) { steps += row.steps; row.children.forEach(visitRow) }
        func visit(_ widget: ScreenWidget) {
            switch widget {
            case let .list(list): list.rows.forEach(visitRow)
            case let .section(section): section.widgets.forEach(visit)
            case let .usage(bar): bar.segments.flatMap(\.items).forEach(visitRow)
            default: break
            }
        }
        if let hero = screen.hero { visit(.usage(hero)) }
        screen.widgets.forEach(visit)
        return steps
    }

    /// Every info text on a page, for checking it against the rule.
    public static func all(in screen: Screen) -> [String] {
        var texts: [String] = []
        func visit(_ widget: ScreenWidget) {
            switch widget {
            case let .list(list): list.rows.forEach(visitRow)
            case let .toggles(list): texts += [list.footnote].compactMap { $0 } + list.rows.compactMap(\.detail)
            case let .section(section): texts += [section.subtitle].compactMap { $0 }; section.widgets.forEach(visit)
            case let .button(button): texts += [button.footnote].compactMap { $0 }
            case let .usage(bar): texts += [bar.footnote].compactMap { $0 }; bar.segments.flatMap(\.items).forEach(visitRow)
            default: break
            }
        }
        func visitRow(_ row: Row) {
            if let detail = row.detail { texts.append(detail) }
            row.children.forEach(visitRow)
        }
        if let hero = screen.hero { visit(.usage(hero)) }
        screen.widgets.forEach(visit)
        return texts.filter { !$0.isEmpty }
    }
}

/// Asked before an action runs. Keep it short: the title asks the question ("Free 250 MB?"), and the message, when there is one, says
/// in one line what the user would not expect (an app that will quit). Never how MacSpace works inside. The host must align
/// the app icon, heading and message to a shared leading edge in every confirmation, including cache selection.
public struct Confirmation: Codable, Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirmTitle: String

    public init(title: String, message: String = "", confirmTitle: String) {
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

/// Something the user can trigger. An action that frees space is titled Free ("Free", "Free 120 MB"), never Delete or Clean.
/// The app asks for confirmation first when `confirmation` is set, and for any missing
/// `requires` permission before it calls the module.
public struct Action: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String?
    public var role: ActionRole
    public var parameters: [String: String]
    public var confirmation: Confirmation?
    public var requires: [Permission]
    /// What the button says while the action runs, and nothing else: "Freeing space" for every action that frees space.
    /// The button fills from the left as the action advances (`ActionProgress.fraction`); the module's progress messages are not
    /// shown. nil: "Working".
    public var workingTitle: String?
    /// Representative future labels for the inline flag. The host reserves the widest label before work starts,
    /// so progress changes cannot resize the flag or push neighbouring controls. Unknown longer results truncate with help text.
    public var labelSamples: [String]?

    public init(id: String, title: String, symbol: String? = nil, role: ActionRole = .normal, parameters: [String: String] = [:],
                confirmation: Confirmation? = nil, requires: [Permission] = [], workingTitle: String? = nil, labelSamples: [String]? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.role = role
        self.parameters = parameters
        self.confirmation = confirmation
        self.requires = requires
        self.workingTitle = workingTitle
        self.labelSamples = labelSamples
    }
}

extension Action {
    /// The id of the app's own Full Disk Access action (`allowFullDiskAccess`).
    public static let fullDiskAccessID = "macspace.allowFullDiskAccess"

    /// Opens Privacy & Security > Full Disk Access in System Settings, where the user allows MacSpace: the app runs it, the module is
    /// never called. System Data and Siri each opened it with an action of their own (2026-10-20).
    public static func allowFullDiskAccess(title: String) -> Action {
        Action(id: fullDiskAccessID, title: title, role: .prominent)
    }

    /// The id of the app's own restart action (`restart`).
    public static let restartID = "macspace.restart"

    /// Restarts the Mac through macOS's own Restart dialog, where the user confirms or cancels: the app runs it and the module is
    /// never called. The main action of a page whose items need a restart (`Badge.restartRequired`); an action whose result has
    /// `ActionResult.restartRequired` ends on the same button by itself.
    public static func restart(title: String? = nil) -> Action {
        Action(id: restartID, title: title ?? String(localized: "Restart to finish"), symbol: "arrow.clockwise", role: .prominent)
    }

    /// The id of the app's own System Settings action (`openSettings`).
    public static let openSettingsID = "macspace.openSettings"

    /// Opens a pane of System Settings (`x-apple.systempreferences:` and nothing else): the app opens it, the module is never called.
    /// Debloat, System Data, Other System Files and Siri each opened their panes with an action of their own (2026-10-20).
    public static func openSettings(title: String, url: URL) -> Action {
        Action(id: openSettingsID, title: title, parameters: ["url": url.absoluteString])
    }

    /// The pane an `openSettings` action opens; nil for anything that is not a System Settings pane, which the app never opens.
    public static func settingsPane(_ parameters: [String: String]) -> URL? {
        guard let url = parameters["url"].flatMap(URL.init(string:)), isSettingsPane(url) else { return nil }
        return url
    }

    /// Only System Settings: a module cannot have the app open a web page, a file or another app through these.
    public static func isSettingsPane(_ url: URL) -> Bool { url.scheme?.lowercased() == "x-apple.systempreferences" }
}

/// A module's page. The app draws it on the module's tile, grown to fill the window: the tile's title and status stay in the corner,
/// so the page needs no header.
public struct Screen: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    /// The big bar at the top of the page, drawn without a card.
    public var hero: UsageBar?
    /// The page's one main action, pinned at the bottom (the "Free" pill). Every other action sits next to what it acts on. Whether
    /// or not a page has one, the pill is there while the module reads the Mac, saying Loading and breathing as it fills, and the
    /// page shows nothing else meanwhile but its ground breathing: no placeholder rows. While an action runs it says only the
    /// action's `workingTitle` (`ActionProgress`).
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

/// A notice at the top of a page. Like every element (`Badge.Kind`), it is in the action color only when it asks something of the
/// user: `warning` or `critical` (something to do, said in its message), or an `action` to press; `info` and `success` are facts.
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
    /// What this part is made of, item by item. On a page's hero, clicking its block opens a page listing them, as a group row does
    /// (`Row.children`): the same page change, a "Page › Block" title and Back. The rows keep their actions, (i) and `paths`; size
    /// each by what it adds to this block, so the page adds up to it. Empty: the block opens nothing, which is right when its only
    /// row would repeat its name and size. Leave it empty on a tile's chart, which is saved between launches.
    public var items: [Row]

    public init(id: String, label: String, bytes: UInt64, tone: Tone, items: [Row] = []) {
        self.id = id
        self.label = label
        self.bytes = bytes
        self.tone = tone
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case id, label, bytes, tone, items }

    /// `items` may be missing (a tile saved by an earlier version).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        bytes = try container.decode(UInt64.self, forKey: .bytes)
        tone = try container.decode(Tone.self, forKey: .tone)
        items = try container.decodeIfPresent([Row].self, forKey: .items) ?? []
    }

    /// The page its block opens: a group of its items, named and sized as the block. nil when it has none.
    public var group: Row? {
        guard !items.isEmpty else { return nil }
        return Row.group(id: "segment:\(id)", title: label, totalBytes: bytes, rows: items)
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

/// A list row. The interface rules (CONTRIBUTING.md) apply: each item is listed on one page only, short facts go in `badges`, not
/// `subtitle`, and `detail` never repeats a badge.
public struct Row: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// A count the title needs ("12 items"). A fact about the row (its state, its kind, why it is checked) is a badge.
    public var subtitle: String?
    /// The row's figure on the right edge (a size, a version). With one, the row's action flags stand right after its title, pills
    /// and (i); without one, they take the right edge themselves. The app places them; a module only fills the two fields.
    public var trailing: String?
    /// Short facts about the row, drawn as pills right after its title, in this order.
    public var badges: [Badge]
    /// The first badge.
    public var badge: Badge? {
        get { badges.first }
        set { badges = newValue.map { [$0] } ?? [] }
    }
    public var symbol: String?
    /// What the row is, behind its (i): static, at most `InfoText.maximumLines` lines (`InfoText`).
    public var detail: String?
    /// What the user can do about the row, shown after `detail` in its (i), each step a sentence of its own (for example a manual
    /// cleanup guide). Plain sentences: the app draws them as paragraphs, never as a numbered or bulleted list, and a step must not
    /// start with a number, a bullet or a dash (`InfoText.violations`).
    public var steps: [String]
    /// Background row work with progress of its own ("Removing 9 GB") uses the same inline flag as a user-started row action. Keep
    /// its action metadata with stable id and parameters so the flag retains identity, and the host can recognize a foreground result
    /// handed to background work. Space MacSpace frees by itself with nothing to measure is the shared pill instead
    /// (`Badge.freeingInBackground`).
    public var activity: ActionProgress?
    /// The row's buttons, drawn as its action flags: after the title when the row has a `trailing` figure, else on the right edge.
    public var actions: [Action]
    /// A group: the row stands for these rows, says how many there are, and opens a page of its own that lists them all (each with
    /// its size and actions). Put the group's total in `trailing`.
    public var children: [Row]
    /// Where the row's files are on disk: absolute paths to files or folders. The app draws a folder button beside the row's (i) that
    /// shows them in the Finder, selected in one window, or opens the deepest folder holding them all when they lie in many folders.
    /// Those that no longer exist are left out, and no button is drawn when none is left. Only list places the user can open: not a
    /// folder macOS keeps closed even with Full Disk Access, nor a row with no files of its own (a setting, an account).
    public var paths: [String]
    /// On a group: its page lets the user choose among its rows and act on the chosen ones (`Selection`).
    public var selection: Selection?

    public init(id: String, title: String, subtitle: String? = nil, trailing: String? = nil, badge: Badge? = nil, badges: [Badge] = [],
                symbol: String? = nil, detail: String? = nil, steps: [String] = [], actions: [Action] = [], children: [Row] = [],
                paths: [String] = [], selection: Selection? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.badges = (badge.map { [$0] } ?? []) + badges
        self.symbol = symbol
        self.detail = detail
        self.steps = steps
        self.actions = actions
        self.children = children
        self.paths = paths
        self.selection = selection
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, trailing, badge, badges, symbol, detail, steps, actions, activity, children, paths, selection
    }

    /// `children`, `paths`, `selection` and `badges` may be missing (a screen written before they existed), and a screen
    /// written before `badges` has `badge`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        trailing = try container.decodeIfPresent(String.self, forKey: .trailing)
        badges = try container.decodeIfPresent([Badge].self, forKey: .badges)
            ?? (try container.decodeIfPresent(Badge.self, forKey: .badge)).map { [$0] } ?? []
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        steps = try container.decodeIfPresent([String].self, forKey: .steps) ?? []
        actions = try container.decodeIfPresent([Action].self, forKey: .actions) ?? []
        activity = try container.decodeIfPresent(ActionProgress.self, forKey: .activity)
        children = try container.decodeIfPresent([Row].self, forKey: .children) ?? []
        paths = try container.decodeIfPresent([String].self, forKey: .paths) ?? []
        selection = try container.decodeIfPresent(Selection.self, forKey: .selection)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(trailing, forKey: .trailing)
        try container.encode(badges, forKey: .badges)
        try container.encodeIfPresent(symbol, forKey: .symbol)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encode(steps, forKey: .steps)
        try container.encode(actions, forKey: .actions)
        try container.encodeIfPresent(activity, forKey: .activity)
        try container.encode(children, forKey: .children)
        try container.encode(paths, forKey: .paths)
        try container.encodeIfPresent(selection, forKey: .selection)
    }

    /// A group of `rows` as one row: its count under the title and its total on the right.
    public static func group(id: String, title: String, symbol: String? = nil, totalBytes: UInt64, rows: [Row], detail: String? = nil) -> Row {
        Row(id: id, title: title, subtitle: rows.count == 1 ? String(localized: "1 item") : String(localized: "\(rows.count) items"),
            trailing: ByteCountFormatter.string(fromByteCount: Int64(clamping: totalBytes), countStyle: .file), symbol: symbol, detail: detail,
            children: rows)
    }
}

/// A group whose page lets the user choose rows and act on the chosen ones (`Row.selection`). Each of the group's rows named in
/// `choices` gets a checkbox, checked when the page opens if its id is in `checked`; rows not named have none. While at least one is
/// checked, the page's bottom button is `action`, titled with its title and the checked rows' total ("Free selected 120 MB"), and runs
/// with the checked ids, one per line, in the parameter `ids` (ids can hold commas, a folder's name for one). While the boxes are
/// exactly `suggested`, the button is titled `suggestedTitle` instead ("Free recommended 1.2 GB").
///
/// With `sections`, the page lists the rows in those parts, in that order, each under its title ("Recommended 3 items 1.2 GB")
/// and, when it has rows to choose, a box that checks or clears them all. With `save`, every change is sent to the module at once (`save` with the
/// parameters `ids`, the checked rows, and `all`, the sections whose header box is on, one per line), so the module can keep the
/// choice: it then decides what its other buttons and automatic cleaning free, and sends it back in `checked` and `SelectionSection.all`.
/// Without `save`, a choice is the user's until the group's page closes.
public struct Selection: Codable, Equatable, Sendable {
    public var action: Action
    /// The rows that can be chosen, by id, with the size each adds to the button's total. 0 is a row with no size of its own (a backup
    /// on a backup disk, whose blocks other backups share): while no checked row has a size, the button carries its title alone.
    public var choices: [String: UInt64]
    /// The rows checked when the page opens: the saved choice, or what the module suggests.
    public var checked: [String]
    /// What the module suggests, for the button's title.
    public var suggested: [String]
    public var suggestedTitle: String?
    public var sections: [SelectionSection]
    public var save: Action?
    /// Rows that add a name to the confirmation while they are checked, by id: an open app's cache adds the app, which the action
    /// quits. The names of the checked ones, joined as a list ("Enscape and WhatsApp"), fill `note`, which becomes the confirmation's
    /// message.
    public var noteNames: [String: String]
    /// The confirmation's message while one of `noteNames` is checked, with `%@` for their names: "Quits %@.".
    public var note: String?

    public init(action: Action, choices: [String: UInt64], checked: [String] = [], suggested: [String]? = nil, suggestedTitle: String? = nil,
                sections: [SelectionSection] = [], save: Action? = nil, noteNames: [String: String] = [:], note: String? = nil) {
        self.action = action
        self.choices = choices
        self.checked = checked
        self.suggested = suggested ?? checked
        self.suggestedTitle = suggestedTitle
        self.sections = sections
        self.save = save
        self.noteNames = noteNames
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case action, choices, checked, suggested, suggestedTitle, sections, save, noteNames, note }

    /// The fields after `checked` may be missing (a screen written before they existed).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(Action.self, forKey: .action)
        choices = try container.decode([String: UInt64].self, forKey: .choices)
        checked = try container.decodeIfPresent([String].self, forKey: .checked) ?? []
        suggested = try container.decodeIfPresent([String].self, forKey: .suggested) ?? checked
        suggestedTitle = try container.decodeIfPresent(String.self, forKey: .suggestedTitle)
        sections = try container.decodeIfPresent([SelectionSection].self, forKey: .sections) ?? []
        save = try container.decodeIfPresent(Action.self, forKey: .save)
        noteNames = try container.decodeIfPresent([String: String].self, forKey: .noteNames) ?? [:]
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    /// The `ids` parameter for these ids, and back.
    public static func parameter(_ ids: [String]) -> String { ids.joined(separator: "\n") }
    public static func ids(_ parameter: String?) -> [String] {
        (parameter ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

/// A part of a choosing page (`Selection.sections`): its title, its rows by id in the order drawn, and whether its header box is on,
/// which keeps rows that join the part later checked too.
public struct SelectionSection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var rows: [String]
    public var all: Bool

    public init(id: String, title: String, rows: [String], all: Bool = false) {
        self.id = id
        self.title = title
        self.rows = rows
        self.all = all
    }
}

/// Rows are drawn in the order given: sort them by size, largest first, or alphabetically when they have no size. Any other order
/// needs a comment where the list is built.
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
    /// Shown after the title, as a list row's subtitle.
    public var subtitle: String?
    public var isOn: Bool
    public var isEnabled: Bool
    public var badge: Badge?
    /// What the switch does, behind its (i): static, at most `InfoText.maximumLines` lines (`InfoText`).
    public var detail: String?
    /// Shown right before the switch, as a list row's `trailing`: what the switch acts on, e.g. the size of a feature's models.
    public var trailing: String?
    /// Run when the user flips the switch. The app adds `value` = `true` or `false` to the parameters.
    public var action: Action

    public init(id: String, title: String, subtitle: String? = nil, isOn: Bool, isEnabled: Bool = true, badge: Badge? = nil,
                detail: String? = nil, trailing: String? = nil, action: Action) {
        self.trailing = trailing
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
