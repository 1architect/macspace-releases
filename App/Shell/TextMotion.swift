import SwiftUI

extension EnvironmentValues {
    /// Changed values retain the page's cascade order.
    @Entry var textChangeDelay: Double = 0
}

/// Numeric fields retain their identity as their digit count changes. Decimal/group separators stay inside the field,
/// so the native transition can align the number rather than treating each digit as an independently moving view.
struct TextFields {
    struct Field: Identifiable, Equatable {
        let id: Int
        let text: String
        let numeric: Bool
    }

    static func split(_ text: String) -> [Field] {
        let characters = Array(text)
        var fields: [Field] = []
        var run = ""
        var numeric = false
        for (index, character) in characters.enumerated() {
            let separator = ".,٫٬\u{202F}\u{00A0}".contains(character)
                && index > 0 && index + 1 < characters.count
                && characters[index - 1].isNumber && characters[index + 1].isNumber
            let isNumber = character.isNumber || separator
            if !run.isEmpty, isNumber != numeric {
                fields.append(Field(id: fields.count, text: run, numeric: numeric))
                run = ""
            }
            numeric = isNumber
            run.append(character)
        }
        if !run.isEmpty { fields.append(Field(id: fields.count, text: run, numeric: numeric)) }
        return fields
    }

    /// Keep the sign beside the number; unused reservation belongs after the complete percentage, never between glyphs.
    static func combiningPercentSigns(_ fields: [Field]) -> [Field] {
        var result: [Field] = []
        for field in fields {
            if !field.numeric, let sign = field.text.first, "%٪".contains(sign),
               let previous = result.last, previous.numeric {
                result[result.count - 1] = Field(id: previous.id, text: previous.text + String(sign), numeric: true)
                let remainder = String(field.text.dropFirst())
                if !remainder.isEmpty { result.append(Field(id: field.id, text: remainder, numeric: false)) }
            } else { result.append(field) }
        }
        return result
    }

    static func reservation(for field: Field, in text: String, maximumText: String?) -> String? {
        guard field.numeric else { return nil }
        if let maximumText,
           let maximum = split(maximumText).first(where: { $0.id == field.id && $0.numeric }) {
            return maximum.text.map { $0.isNumber ? "8" : String($0) }.joined()
        }
        if let sign = field.text.last, "%٪".contains(sign) { return "888" + String(sign) }
        let following = split(text).first(where: { $0.id == field.id + 1 })?.text ?? ""
        return following == "%" || following == "٪" ? "888" : nil
    }
}

/// The original native text/number transition, shared by captions, buttons and the All done counter.
/// Parent layout animation cannot move the drawing. Percentage/counting fields reserve their numeric width only;
/// their visible digits keep the inherited proportional font and unchanged words keep their position.
struct ChangingText: View {
    let text: String
    var alignment: Alignment = .leading
    var maximumText: String? = nil
    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.textChangeDelay) private var cascadeDelay

    var body: some View {
        Group {
            if lineLimit == 1 {
                HStack(spacing: 0) {
                    ForEach(fields) { field in
                        let value = field.text.replacingOccurrences(of: " ", with: "\u{00A0}")
                        if let reservation = TextFields.reservation(for: field, in: text, maximumText: maximumText) {
                            Text(verbatim: reservation).hidden()
                                .overlay(alignment: field.text.last.map { "%٪".contains($0) } == true ? .leading : .trailing) { animated(value) }
                        } else {
                            Text(verbatim: value).hidden()
                                .overlay(alignment: alignment) { animated(value) }
                        }
                    }
                }
            } else {
                // Multiline descriptions retain Text's native wrapping and shaping.
                Text(verbatim: text).hidden()
                    .overlay(alignment: alignment) { animated(text) }
            }
        }
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var fields: [TextFields.Field] {
        let split = TextFields.split(text)
        // Keep ordinary labels shaped as one Text, including kerning across word/number boundaries.
        guard split.contains(where: { TextFields.reservation(for: $0, in: text, maximumText: maximumText) != nil }) else {
            return [TextFields.Field(id: 0, text: text, numeric: false)]
        }
        return TextFields.combiningPercentSigns(split)
    }

    private func animated(_ value: String) -> some View {
        Text(verbatim: value)
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : Theme.value.delay(cascadeDelay), value: value)
    }
}
