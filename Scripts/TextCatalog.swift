// Writes App/Resources/TextCatalog.json: every text in Localization/<Table>.json with its translations, the kind of interface element
// it is shown in (button, pill, row title, confirmation, …) and where the code uses it. The design tools' Text Editor (Design menu)
// lists it by kind, so texts can be improved side by side and exported for fixing. Assemble.sh runs it before copying the resources.
//
//     swift Scripts/TextCatalog.swift
//
// The kind is read from the code around each use: the call the text is an argument of and the argument's label (`Badge(…)`,
// `Confirmation(confirmTitle: …)`, `.help(…)`, `Row(detail: …)`), else the name it is set to or returned from. A text used in several
// places takes the kind of its first use; every place is listed.

import Foundation

let languages = ["pt-BR", "fr", "es", "de", "zh-Hans", "ja", "ko"]
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

/// The kind of element for a text passed as `label` to `call` (the innermost call around the text that is not a wrapper such as
/// `loc(`), nil when the pair says nothing.
func kind(call: String, label: String?) -> String? {
    switch (call, label) {
    case ("Action", "workingTitle"?): return "Button while working"
    case ("Action", _): return "Button"
    case ("Confirmation", "message"?): return "Confirmation message"
    case ("Confirmation", "confirmTitle"?): return "Confirmation button"
    case ("Confirmation", _): return "Confirmation title"
    case ("Badge", _): return "Pill"
    case ("Banner", "message"?): return "Notice message"
    case ("Banner", _): return "Notice"
    case ("Row", "subtitle"?), ("CacheEntry", "subtitle"?): return "Row subtitle"
    case ("Row", "detail"?), ("CacheEntry", "reason"?), ("CacheEntry", "detail"?): return "Row detail"
    case ("Row", "trailing"?): return "Row value"
    case ("Row", "steps"?): return "Steps"
    case ("Row", _), ("CacheEntry", _), ("ToggleRow", _): return "Row title"
    case ("Tile", "status"?): return "Tile status"
    case ("Tile", "figure"?): return "Tile figure"
    case ("Tile", _): return "Tile title"
    case ("UsageSegment", _): return "Chart part"
    case ("Section", _), ("Group", _): return "Section header"
    case ("OptionDefinition", "detail"?), ("OptionChoice", "detail"?): return "Setting description"
    case ("OptionDefinition", _), ("OptionChoice", _): return "Setting"
    case ("Selection", "note"?): return "Confirmation message"
    case ("Selection", _): return "Button"
    case ("ActionResult", _), ("succeeded", _), ("failed", _), ("CleanupReport", _), ("ActionProgress", _): return "Result message"
    case ("help", _), ("accessibilityLabel", _), (_, "help"?): return "Tooltip"
    case ("Button", _), ("GlassCircleButton", _): return "Button"
    case ("Toggle", _): return "Switch"
    case ("Picker", _), ("Menu", _), ("CommandMenu", _): return "Menu"
    case ("Text", _), ("Label", _), ("LabeledContent", _): return "Label"
    case ("add", nil), ("measured", nil): return "Item name"
    case (_, "title"?), (_, "name"?): return "Title"
    case (_, "detail"?), (_, "reason"?), (_, "explanation"?): return "Row detail"
    case (_, "message"?), (_, "summary"?): return "Message"
    case (_, "status"?): return "Tile status"
    default: return nil
    }
}

/// The kind of a text the code sets through a variable or returns from a function, by that name.
func kind(name: String) -> String? {
    let name = name.lowercased()
    if name.contains("help") || name.contains("tooltip") { return "Tooltip" }
    if name.contains("badge") || name.contains("pill") { return "Pill" }
    if name.contains("status") { return "Tile status" }
    if name.contains("detail") || name.contains("reason") || name.contains("description") || name.contains("explanation") { return "Row detail" }
    if name.contains("message") || name.contains("summary") || name.contains("body") || name.contains("informativetext") { return "Message" }
    if name.contains("title") || name.contains("name") || name.contains("label") || name.contains("messagetext") { return "Title" }
    return nil
}

/// Calls that only turn a text into the user's language: the element is the call around them.
let wrappers: Set<String> = ["loc", "locKey", "String", "LocalizedStringKey", "NSLocalizedString", "LocalizedStringResource", "format", "append", "map"]
/// The literal's text with each interpolation as a placeholder, as the tables key it: `"Free \(size)"` is "Free %@".
func normalized(_ literal: String) -> String {
    var result = ""
    var index = literal.startIndex
    while index < literal.endIndex {
        if literal[index] == "\\", literal.index(after: index) < literal.endIndex, literal[literal.index(after: index)] == "(" {
            var depth = 0
            var cursor = literal.index(after: index)
            while cursor < literal.endIndex {
                if literal[cursor] == "(" { depth += 1 }
                if literal[cursor] == ")" { depth -= 1; if depth == 0 { break } }
                cursor = literal.index(after: cursor)
            }
            result += "%@"
            index = cursor < literal.endIndex ? literal.index(after: cursor) : cursor
        } else if literal[index] == "\\", literal.index(after: index) < literal.endIndex {
            let next = literal[literal.index(after: index)]
            result.append(next == "n" ? "\n" : next)
            index = literal.index(index, offsetBy: 2)
        } else {
            result.append(literal[index])
            index = literal.index(after: index)
        }
    }
    return result
}

/// A table key with every placeholder as %@, to match the code's interpolations whatever their type.
func matchable(_ key: String) -> String {
    key.replacingOccurrences(of: "%(lld|llu|ld|d|lf|f)", with: "%@", options: .regularExpression)
}

/// The kind of the literal whose code before it is `context` (its line and those above it): the innermost call around it that is not
/// a wrapper, with the label of the argument it is in; or the variable it is set to, or the function or property it is returned from.
func kind(context: String, file: String) -> String {
    if file.hasSuffix("Notifications.swift") { return "Notification" }
    let characters = Array(context)
    var depth = 0
    var label: String?
    var index = characters.count - 1
    var labelSeen = false
    while index >= 0 {
        let character = characters[index]
        if character == ")" || character == "]" || character == "}" { depth += 1 }
        else if character == "{" && depth == 0 { break }
        else if character == "(" || character == "[" || character == "{" {
            if depth > 0 { depth -= 1 } else if character == "(" {
                // The call this argument list belongs to: the name before the parenthesis (`.help(`, `Row(`, `Badge(`).
                var end = index - 1
                while end >= 0, characters[end] == " " { end -= 1 }
                var start = end
                while start >= 0, characters[start].isLetter || characters[start].isNumber || characters[start] == "_" { start -= 1 }
                let call = start < end ? String(characters[(start + 1)...end]) : ""
                if !wrappers.contains(call), let kind = kind(call: call, label: label) { return kind }
                if !wrappers.contains(call), !call.isEmpty { label = nil }
                labelSeen = false
            }
        } else if character == ":" && depth == 0 && !labelSeen {
            // The argument's label: the word before the colon, the nearest at this level.
            var end = index - 1
            while end >= 0, characters[end] == " " { end -= 1 }
            var start = end
            while start >= 0, characters[start].isLetter || characters[start].isNumber || characters[start] == "_" { start -= 1 }
            if start < end { label = String(characters[(start + 1)...end]); labelSeen = true }
        } else if character == "," && depth == 0 {
            labelSeen = true
        }
        index -= 1
    }
    // Not in a call that says: the name it is set to (`detail = loc(`), or the function or property it comes from.
    let line = context.components(separatedBy: "\n").last ?? ""
    if let match = line.range(of: #"(\w+)\s*=\s*[^=]*$"#, options: .regularExpression),
       let name = line[match].split(separator: "=").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
       let kind = kind(name: name.components(separatedBy: ".").last ?? name) { return kind }
    let declaration = try! NSRegularExpression(pattern: #"(?:func|var|let)\s+(\w+)"#)
    let range = NSRange(context.startIndex..., in: context)
    if let last = declaration.matches(in: context, range: range).last, let name = Range(last.range(at: 1), in: context),
       let kind = kind(name: String(context[name])) { return kind }
    return "Text"
}

struct Use { var file: String; var line: Int; var kind: String }

let sources = ["App", "Modules", "Sdk"]
let skipped = ["App/Debug/", "App/Shell/ColorLab.swift", "App/Settings/ColorLabView.swift", "App/Shell/Shading.swift", "App/Shell/Design.swift",
               "App/Settings/TextEditorView.swift", "App/Settings/WidgetTypeView.swift", "/Privileged/"]
let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
var uses: [String: [String: [Use]]] = [:] // table → matchable key → uses
for source in sources {
    let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(source), includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
        guard !skipped.contains(where: path.contains) else { continue }
        let table = path.hasPrefix("Modules/") ? String(path.split(separator: "/")[1]) : "App"
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        // The code without comments, so a parenthesis or a colon in a comment does not count.
        let code = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//") ? "" : line
        }
        for (number, line) in code.enumerated() {
            for match in literal.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let whole = Range(match.range, in: line), let inner = Range(match.range(at: 1), in: line) else { continue }
                let key = matchable(normalized(String(line[inner])))
                // The literal's line up to it, with up to 30 lines above: enough for the call it is an argument of.
                let above = code[max(0, number - 30)..<number].joined(separator: "\n")
                let context = above + "\n" + String(line[..<whole.lowerBound])
                let use = Use(file: path, line: number + 1, kind: kind(context: context, file: path))
                uses[table, default: [:]][key, default: []].append(use)
            }
        }
    }
}

var catalog: [[String: Any]] = []
let tables = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Localization"), includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
var unplaced = 0
for file in tables {
    let table = file.deletingPathExtension().lastPathComponent
    let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: [String]]
    for key in entries.keys.sorted() {
        // A module's text may be shown by the app's code too (a shared helper), so the app's uses count for every table.
        let found = (uses[table]?[matchable(key)] ?? []) + (table == "App" ? [] : uses["App"]?[matchable(key)] ?? [])
        if found.isEmpty { unplaced += 1 }
        var translations = ["en": key]
        for (language, text) in zip(languages, entries[key]!) { translations[language] = text }
        catalog.append([
            "id": "\(table)|\(key)",
            "table": table,
            "key": key,
            "kind": found.first?.kind ?? "Other",
            "places": found.prefix(6).map { "\($0.file):\($0.line)" },
            "translations": translations,
        ])
    }
}
let output = root.appendingPathComponent("App/Resources/TextCatalog.json")
let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
try data.write(to: output)
print("TextCatalog: \(catalog.count) texts (\(unplaced) not found in the code) in \(output.path.replacingOccurrences(of: root.path + "/", with: ""))")
