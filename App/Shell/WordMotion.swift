import SwiftUI

/// A frozen drawing keeps its own font while a progress label becomes an ordinary status phrase.
struct TextMotionSnapshot: Equatable {
    let text: String
    let font: Font
    var size: CGSize?

    init(_ text: String, font: Font = .body, size: CGSize? = nil) {
        self.text = text
        self.size = size
        let fields = TextFields.split(text)
        let percentage = fields.count >= 2 && fields[fields.count - 2].numeric
            && (fields.last?.text == "%" || fields.last?.text == "٪")
        self.font = percentage ? font.monospacedDigit() : font
    }

    var phrase: [String] { TextFields.split(text).filter { !$0.numeric }.map(\.text) }
}

/// Word changes own two static snapshots. They never keep a native, unfinished numeric transition alive underneath them.
struct TextMotionState {
    private(set) var current: TextMotionSnapshot?
    private(set) var change: WordChange?
    private var generation: UInt64 = 0

    func updating(to next: TextMotionSnapshot) -> Self {
        var result = self
        result.current = next
        guard let current else { return result }
        if current.text == next.text {
            if let change { result.change = WordChange(id: change.id, outgoing: change.outgoing, incoming: next) }
            return result
        }
        if current.phrase != next.phrase {
            result.generation += 1
            result.change = WordChange(id: result.generation, outgoing: current, incoming: next)
        } else if let change {
            // New numbers during a word entrance update the incoming snapshot without replaying its cascade.
            result.change = WordChange(id: change.id, outgoing: change.outgoing, incoming: next)
        }
        return result
    }

    mutating func complete(_ id: UInt64) {
        guard change?.id == id else { return }
        change = nil
    }
}

struct WordChange: Identifiable {
    let id: UInt64
    let outgoing: TextMotionSnapshot
    let incoming: TextMotionSnapshot

    struct Piece: Equatable {
        let text: String
        let ordinal: Int
        let whitespace: Bool
    }

    static func pieces(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var run = ""
        var whitespace = false
        var ordinal = 0
        func flush() {
            guard !run.isEmpty else { return }
            pieces.append(Piece(text: run, ordinal: ordinal, whitespace: whitespace))
            if !whitespace { ordinal += 1 }
            run = ""
        }
        for character in text {
            if !run.isEmpty, character.isWhitespace != whitespace { flush() }
            whitespace = character.isWhitespace
            run.append(character)
        }
        flush()
        return pieces
    }

    /// The words that stay where they are, drawn still while the others roll: the start both phrases share when the text is drawn
    /// from the leading edge, the end they share when drawn from the trailing edge, nothing when centered. A word shared further
    /// in moves sideways as the words before it change width: matched as unchanged, it jumped to its new place while the rest rolled
    /// ("MB" in a chart legend as the pointer went from block to block).
    func unchanged(alignment: HorizontalAlignment = .leading) -> (outgoing: Set<Int>, incoming: Set<Int>) {
        let old = Self.pieces(outgoing.text), new = Self.pieces(incoming.text)
        var shared = 0
        let fromEnd = alignment == .trailing
        guard fromEnd || alignment == .leading else { return ([], []) }
        while shared < min(old.count, new.count) {
            let a = old[fromEnd ? old.count - 1 - shared : shared], b = new[fromEnd ? new.count - 1 - shared : shared]
            guard a.text == b.text else { break }
            shared += 1
        }
        func words(_ pieces: [Piece]) -> Set<Int> {
            let kept = fromEnd ? pieces.suffix(shared) : pieces.prefix(shared)
            return Set(kept.filter { !$0.whitespace }.map(\.ordinal))
        }
        return (words(old), words(new))
    }

    var wordCount: Int {
        max(Self.pieces(outgoing.text).filter { !$0.whitespace }.count, Self.pieces(incoming.text).filter { !$0.whitespace }.count)
    }
}

struct WordMotionSample {
    var y: Double
    var blur: Double
    var opacity: Double

    /// Original word roll/blur timings, sampled explicitly so interrupted and intermediate frames are testable.
    static func at(_ elapsed: Double, ordinal: Int, outgoing: Bool, reduceMotion: Bool, delay: Double) -> Self {
        if reduceMotion {
            let amount = UnitCurve.easeInOut.value(at: min(1, max(0, elapsed / 0.2)))
            return Self(y: 0, blur: 0, opacity: outgoing ? 1 - amount : amount)
        }
        let time = max(0, elapsed - delay - Double(ordinal) * 0.025)
        if outgoing {
            let amount = UnitCurve.easeIn.value(at: min(1, time / 0.22))
            return Self(y: -0.9 * amount, blur: 3 * amount, opacity: 1 - amount)
        }
        let amount = time >= 0.45 ? 1 : Spring(duration: 0.45, bounce: 0.22).value(target: 1.0, time: time)
        let visible = min(1, max(0, amount))
        return Self(y: 0.9 * (1 - amount), blur: 3 * (1 - visible), opacity: visible)
    }
}

/// Each word moves by its share of a line: the first subview is a one-line probe in the phrase's font, measured for that height,
/// and the others are the phrase's layers, laid over each other and moved by their `WordRollOffset`. Measured in the layout, the
/// line is known on the first frame, also when a single frame is rendered.
private struct WordRollLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.dropFirst().reduce(CGSize.zero) { size, layer in
            let fit = layer.sizeThatFits(proposal)
            return CGSize(width: max(size.width, fit.width), height: max(size.height, fit.height))
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let probe = subviews.first else { return }
        probe.place(at: bounds.origin, proposal: .unspecified)
        let line = probe.sizeThatFits(.unspecified).height
        for layer in subviews.dropFirst() {
            layer.place(at: CGPoint(x: bounds.minX, y: bounds.minY + layer[WordRollOffset.self] * line), proposal: ProposedViewSize(bounds.size))
        }
    }
}

private struct WordRollOffset: LayoutValueKey {
    static let defaultValue: Double = 0
}

/// A pure frame used by playback and by offscreen tests at arbitrary intermediate times.
///
/// Each moving word is the whole phrase with every other word clear, so it keeps its place in one shaped paragraph, and it fades,
/// blurs and rolls with ordinary modifiers. A custom `TextRenderer` drew the same motion, but every caption it drew was painted by
/// the app into layers of its own while it moved: 13 captions changing together held over 80 MB of graphics memory (Issue 11).
/// At rest, the plain text is drawn, exactly as it is without the motion.
struct WordChangeFrame: View, @preconcurrency Animatable {
    let change: WordChange
    var elapsed: Double
    var alignment: Alignment = .leading
    var singleLine = true
    var reduceMotion = false
    var delay: Double = 0

    var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    var body: some View {
        let matched = change.unchanged(alignment: alignment.horizontal)
        ZStack(alignment: alignment) {
            layer(change.outgoing, unchanged: matched.outgoing, outgoing: true)
            layer(change.incoming, unchanged: matched.incoming, outgoing: false)
        }
        .accessibilityHidden(true)
    }

    private struct Word: Identifiable {
        let id: Int
        let sample: WordMotionSample
    }

    private func layer(_ snapshot: TextMotionSnapshot, unchanged: Set<Int>, outgoing: Bool) -> some View {
        let pieces = WordChange.pieces(snapshot.text)
        let words = pieces.filter { !$0.whitespace && !unchanged.contains($0.ordinal) }.map { piece in
            Word(id: piece.ordinal, sample: .at(elapsed, ordinal: piece.ordinal, outgoing: outgoing, reduceMotion: reduceMotion, delay: delay))
        }
        // Unchanged words are drawn once, by the incoming phrase.
        let atRest = (!outgoing || unchanged.isEmpty) && words.allSatisfy { $0.sample.opacity == 1 && $0.sample.y == 0 && $0.sample.blur == 0 }
        return Group {
            if atRest {
                Text(verbatim: snapshot.text)
            } else {
                WordRollLayout {
                    Text(verbatim: "Ag").lineLimit(1).fixedSize().hidden()
                    if !outgoing, !unchanged.isEmpty { Self.paragraph(pieces, showing: unchanged) }
                    ForEach(words.filter { $0.sample.opacity > 0 }) { word in
                        Self.paragraph(pieces, showing: [word.id])
                            .opacity(word.sample.opacity)
                            .blur(radius: word.sample.blur)
                            .layoutValue(key: WordRollOffset.self, value: word.sample.y)
                    }
                }
                // Vertical roll/blur may draw outside the line; no glyph or blur can escape its own trailing edge.
                .padding(EdgeInsets(top: 32, leading: 32, bottom: 32, trailing: 0))
                .clipped()
                .padding(EdgeInsets(top: -32, leading: -32, bottom: -32, trailing: 0))
            }
        }
        .font(snapshot.font)
        .frame(width: snapshot.size?.width, height: snapshot.size?.height, alignment: alignment)
        .fixedSize(horizontal: singleLine, vertical: true)
    }

    /// The phrase with only `visible` words showing; the others keep their place, clear.
    private static func paragraph(_ pieces: [WordChange.Piece], showing visible: Set<Int>) -> Text {
        pieces.reduce(Text(verbatim: "")) { text, piece in
            let word = Text(verbatim: piece.text)
            var interpolation = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: 2)
            interpolation.appendInterpolation(text)
            interpolation.appendInterpolation(!piece.whitespace && visible.contains(piece.ordinal) ? word : word.foregroundStyle(.clear))
            return Text(LocalizedStringKey(stringInterpolation: interpolation))
        }
    }
}

struct WordChangePlayback: View {
    let change: WordChange
    let alignment: Alignment
    let singleLine: Bool
    let reduceMotion: Bool
    let delay: Double
    let complete: @MainActor (UInt64) -> Void
    @State private var elapsed: Double = 0

    private var duration: Double { reduceMotion ? 0.2 : delay + 0.45 + Double(max(0, change.wordCount - 1)) * 0.025 }

    var body: some View {
        WordChangeFrame(change: change, elapsed: elapsed, alignment: alignment, singleLine: singleLine, reduceMotion: reduceMotion, delay: delay)
            .animation(.linear(duration: duration), value: elapsed)
            .task {
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: duration)) { elapsed = duration }
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                guard !Task.isCancelled else { return }
                complete(change.id)
            }
    }
}
