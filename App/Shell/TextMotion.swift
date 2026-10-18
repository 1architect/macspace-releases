import SwiftUI

/// Text whose changes roll in like an odometer: each digit that changes rolls up out of view and the new one rolls in from below, a
/// little after the one to its left, with a short blur; words that change cross over the same way, as one piece, so they keep their
/// kerning. Used for what All done counts up; SwiftUI's numeric transition moved the whole line at once and blurred it.
struct RollingText: View {
    let text: String
    /// Its own font, or the one around it.
    var font: Font? = nil
    @Environment(\.font) private var inherited

    /// Runs of the text: each digit on its own, everything between digits as one piece.
    struct Piece: Identifiable, Equatable {
        let id: String
        let text: String
        let isDigit: Bool
    }

    static func pieces(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            pieces.append(Piece(id: "\(pieces.count):\(run)", text: run, isDigit: false))
            run = ""
        }
        for character in text {
            if character.isNumber {
                flush()
                pieces.append(Piece(id: "\(pieces.count):\(character)", text: String(character), isDigit: true))
            } else {
                run.append(character)
            }
        }
        flush()
        return pieces
    }

    var body: some View {
        ChangingText(text: text, alignment: .center)
            .font(font ?? inherited)
            .frame(maxWidth: .infinity)
            .transaction { $0.animation = nil }
    }
}

/// Identify changed digits/word runs without treating an unchanged suffix as new when a number gains a digit.
struct TextRollChange {
    let old: [RollingText.Piece]
    let new: [RollingText.Piece]
    let removed: Set<Int>
    let inserted: Set<Int>

    init(from oldText: String, to newText: String) {
        old = RollingText.pieces(oldText)
        new = RollingText.pieces(newText)
        let difference = new.map(\.text).difference(from: old.map(\.text))
        removed = Set(difference.removals.map { change in
            if case let .remove(offset, _, _) = change { return offset }
            preconditionFailure("Expected removal")
        })
        inserted = Set(difference.insertions.map { change in
            if case let .insert(offset, _, _) = change { return offset }
            preconditionFailure("Expected insertion")
        })
    }

    func label(outgoing: Bool) -> Text {
        let pieces = outgoing ? old : new
        let changes = outgoing ? removed : inserted
        var content = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: pieces.count)
        for (index, piece) in pieces.enumerated() {
            // A custom attribute affects drawing only: Text still owns shaping, kerning, wrapping and truncation.
            content.appendInterpolation(Text(verbatim: piece.text).customAttribute(RollAttribute(changed: changes.contains(index), rank: index)))
        }
        return Text(LocalizedStringKey(stringInterpolation: content))
    }
}

private struct RollAttribute: TextAttribute {
    let changed: Bool
    let rank: Int
}

/// The established roll's line-height travel, blur and stagger. There is deliberately no horizontal displacement.
struct TextRollMotion {
    let translation: CGSize
    let opacity: Double
    let blur: Double

    init(progress: Double, rank: Int, outgoing: Bool, reduceMotion: Bool = false, lineHeight: CGFloat) {
        let delay = reduceMotion ? 0 : min(Double(rank) * 0.025 / 0.45, 0.25)
        let position = max(0, (progress - delay) / (1 - delay))
        let fraction = min(position, 1)
        translation = CGSize(width: 0, height: reduceMotion ? 0 : lineHeight * 0.9 * (outgoing ? -position : 1 - position))
        opacity = outgoing ? max(0, 1 - fraction * (reduceMotion ? 1 : 2)) : fraction
        blur = reduceMotion ? 0 : 3 * (outgoing ? fraction : 1 - fraction)
    }
}

private struct VerticalRollRenderer: TextRenderer {
    var progress: Double
    let outgoing: Bool
    let reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let attribute = run[RollAttribute.self], attribute.changed else {
                    if !outgoing { context.draw(run) }
                    continue
                }
                let motion = TextRollMotion(progress: progress, rank: attribute.rank, outgoing: outgoing,
                                            reduceMotion: reduceMotion, lineHeight: run.typographicBounds.rect.height)
                guard motion.opacity > 0 else { continue }
                var drawing = context
                drawing.opacity *= motion.opacity
                drawing.translateBy(x: motion.translation.width, y: motion.translation.height)
                drawing.addFilter(.blur(radius: motion.blur))
                drawing.draw(run)
            }
        }
    }
}

/// The current Text alone determines layout. Changed runs roll/blur vertically in overlays; outgoing text never takes room,
/// and no native content transition is allowed to interpolate glyph x positions or the width of the whole line.
struct ChangingText: View {
    let text: String
    var alignment: Alignment = .leading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previous: String?
    @State private var progress = 1.0
    @State private var completion: Task<Void, Never>?

    var body: some View {
        let change = TextRollChange(from: previous ?? text, to: text)
        Text(verbatim: text).monospacedDigit().hidden()
            .overlay(alignment: alignment) {
                ZStack(alignment: alignment) {
                    if previous != nil {
                        change.label(outgoing: true)
                            .textRenderer(VerticalRollRenderer(progress: progress, outgoing: true, reduceMotion: reduceMotion))
                            .accessibilityHidden(true)
                    }
                    change.label(outgoing: false)
                        .textRenderer(VerticalRollRenderer(progress: progress, outgoing: false, reduceMotion: reduceMotion))
                }
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: alignment)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.22), value: progress)
            }
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .onChange(of: text) { old, _ in
                completion?.cancel()
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { previous = old; progress = 0 }
                completion = Task { @MainActor in
                    // Commit the old/new layers at their starting positions before starting the roll.
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    progress = 1
                    do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                    previous = nil
                }
            }
            .onDisappear { completion?.cancel() }
    }
}
