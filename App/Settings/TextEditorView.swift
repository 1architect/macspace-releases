// Development builds only (`MACSPACE_DEV`, set by Scripts/Assemble.sh for a -dev build): a release has no design tools.
#if MACSPACE_DEV
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One text of the app, from `TextCatalog.json` (written by `Scripts/TextCatalog.swift`): its English (the key in its table), its
/// translations, the kind of element it is shown in and where the code uses it.
struct CatalogText: Codable, Identifiable, Hashable {
    let id: String
    let table: String
    let key: String
    let kind: String
    let places: [String]
    let translations: [String: String]
}

/// What the user proposes for a text: a new English, a new translation in each language, and a note for whoever applies it.
struct TextProposal: Codable, Equatable {
    var english = ""
    var translations: [String: String] = [:]
    var note = ""

    var isEmpty: Bool { english.isEmpty && translations.values.allSatisfy(\.isEmpty) && note.isEmpty }
}

/// The catalog and the proposals, kept in the defaults until they are cleared.
@MainActor
final class TextEditorStore: ObservableObject {
    static let shared = TextEditorStore()
    static let languages = ["en", "pt-BR", "fr", "es", "de", "zh-Hans", "ja", "ko"]
    private static let key = "design.textProposals"

    let texts: [CatalogText]
    @Published var proposals: [String: TextProposal] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(proposals), forKey: Self.key) }
    }

    private init() {
        texts = Self.loadCatalog()
        proposals = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: TextProposal].self, from: $0) } ?? [:]
    }

    /// The app's copy, or the repository's when MacSpace runs from the build folder without one.
    private static func loadCatalog() -> [CatalogText] {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/TextCatalog.json")
        for url in [Bundle.main.url(forResource: "TextCatalog", withExtension: "json"), source].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let texts = try? JSONDecoder().decode([CatalogText].self, from: data) { return texts }
        }
        return []
    }

    /// The kinds, the most common first.
    var kinds: [(kind: String, count: Int)] {
        Dictionary(grouping: texts, by: \.kind).map { ($0.key, $0.value.count) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.kind < $1.kind }
    }

    var edited: [CatalogText] { texts.filter { !(proposals[$0.id]?.isEmpty ?? true) } }

    func binding(_ text: CatalogText, _ path: WritableKeyPath<TextProposal, String>) -> Binding<String> {
        Binding(get: { self.proposals[text.id]?[keyPath: path] ?? "" }, set: { value in
            var proposal = self.proposals[text.id] ?? TextProposal()
            proposal[keyPath: path] = value
            self.proposals[text.id] = proposal.isEmpty ? nil : proposal
        })
    }

    func translationBinding(_ text: CatalogText, _ language: String) -> Binding<String> {
        Binding(get: { self.proposals[text.id]?.translations[language] ?? "" }, set: { value in
            var proposal = self.proposals[text.id] ?? TextProposal()
            proposal.translations[language] = value.isEmpty ? nil : value
            self.proposals[text.id] = proposal.isEmpty ? nil : proposal
        })
    }

    /// Markdown for an AI (or a person) to apply: what to change, where, and how, grouped by kind. `all` lists every text given, for
    /// a review of the wording; otherwise only the ones with a proposal.
    func markdown(_ texts: [CatalogText], all: Bool) -> String {
        var lines: [String] = []
        if all {
            lines += ["# MacSpace texts for review", "",
                      "Every text of the app shown below, grouped by the kind of interface element it is in. Suggest better wording where it "
                      + "helps, keeping the app's voice (short, plain, no jargon) and the placeholders (%@, %lld) of each text.", ""]
        } else {
            lines += ["# MacSpace text changes", "",
                      "Apply each change below in the MacSpace repository:", "",
                      "- The English of each text is its key in `Localization/<Table>.json` and a literal in the code at the places listed "
                      + "(`loc(\"…\")`, `String(localized: \"…\")`, `Text(\"…\")`; interpolations stand for the placeholders %@ and %lld).",
                      "- A new English: change the literal at every place and the key in the table, keeping its placeholders.",
                      "- Translations (pt-BR, fr, es, de, zh-Hans, ja, ko, in that order in the table): use the proposed ones; for a language with none, "
                      + "translate the new English in the same voice as the table's other texts.",
                      "- A note says what is wrong or what is wanted; follow it.",
                      "- Then run `swift Scripts/Localize.swift`, build, and run the tests.", ""]
        }
        for (kind, group) in Dictionary(grouping: texts, by: \.kind).sorted(by: { $0.key < $1.key }) {
            lines += ["## \(kind)", ""]
            for text in group.sorted(by: { $0.key < $1.key }) {
                lines.append("### \"\(text.key)\"")
                lines.append("- Table: \(text.table)")
                if !text.places.isEmpty { lines.append("- Places: " + text.places.joined(separator: ", ")) }
                let proposal = proposals[text.id] ?? TextProposal()
                if !proposal.english.isEmpty { lines.append("- **New English:** \"\(proposal.english)\"") }
                for language in Self.languages.dropFirst() {
                    let current = text.translations[language] ?? ""
                    if let new = proposal.translations[language], !new.isEmpty {
                        lines.append("- **New \(language):** \"\(new)\" (was \"\(current)\")")
                    } else {
                        lines.append("- \(language): \"\(current)\"")
                    }
                }
                if !proposal.note.isEmpty { lines.append("- **Note:** \(proposal.note)") }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Temporary: the Text Editor window (Design menu, ⌥⌘E). Every text of the app, by the kind of element it is in, in English and each
/// language, with a field to propose a better one and a note. The proposals are kept until cleared and exported as Markdown for
/// applying them (Export Changes) or for a review of all the texts of a kind (Export All).
public struct TextEditorView: View {
    @ObservedObject private var store = TextEditorStore.shared
    @State private var kind: String? = TextEditorView.allKinds
    @State private var search = ""
    @State private var language = TextEditorView.appLanguage

    public static let windowID = "textEditor"
    static let allKinds = "All texts"
    static let editedKinds = "Changed"

    public init() {}

    /// The language the app is shown in, when it is one of the catalog's.
    static var appLanguage: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return TextEditorStore.languages.first { preferred.hasPrefix($0) || $0.hasPrefix(preferred) } ?? "en"
    }

    private var shown: [CatalogText] {
        let base: [CatalogText]
        switch kind {
        case Self.allKinds?, nil: base = store.texts
        case Self.editedKinds?: base = store.edited
        case let kind?: base = store.texts.filter { $0.kind == kind }
        }
        guard !search.isEmpty else { return base }
        return base.filter { text in
            text.key.localizedCaseInsensitiveContains(search) || text.translations.values.contains { $0.localizedCaseInsensitiveContains(search) }
                || text.places.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $kind) {
                Label("\(Self.allKinds) (\(store.texts.count))", systemImage: "text.alignleft").tag(Self.allKinds)
                Label("\(Self.editedKinds) (\(store.edited.count))", systemImage: "pencil").tag(Self.editedKinds)
                Section("Kinds") {
                    ForEach(store.kinds, id: \.kind) { entry in
                        Text("\(entry.kind) (\(entry.count))").tag(entry.kind)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                if store.texts.isEmpty {
                    ContentUnavailableView("No text catalog", systemImage: "text.badge.xmark",
                                           description: Text("Run swift Scripts/TextCatalog.swift, or build with Scripts/Assemble.sh."))
                } else {
                    List(shown) { text in TextRow(text: text, language: language, store: store) }
                        .listStyle(.inset)
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Search texts, translations or files")
            .toolbar {
                ToolbarItem {
                    Picker("Language", selection: $language) {
                        ForEach(TextEditorStore.languages, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem {
                    Menu {
                        Button("Export Changes…") { export(store.markdown(store.edited, all: false), name: "MacSpace text changes.md") }
                            .disabled(store.edited.isEmpty)
                        Button("Copy Changes") { copy(store.markdown(store.edited, all: false)) }
                            .disabled(store.edited.isEmpty)
                        Divider()
                        Button("Export Shown Texts for Review…") { export(store.markdown(shown, all: true), name: "MacSpace texts.md") }
                        Button("Copy Shown Texts for Review") { copy(store.markdown(shown, all: true)) }
                        Divider()
                        Button("Clear All Changes", role: .destructive) { store.proposals = [:] }
                            .disabled(store.proposals.isEmpty)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// One text: its English and its text in the language chosen, where it is used, and the fields for a better one.
private struct TextRow: View {
    let text: CatalogText
    let language: String
    @ObservedObject var store: TextEditorStore

    private var changed: Bool { !(store.proposals[text.id]?.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(text.key).font(.body.weight(.medium)).textSelection(.enabled)
                Spacer()
                Text(text.kind).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                Text(text.table).font(.caption).foregroundStyle(.secondary)
            }
            if language != "en", let translation = text.translations[language] {
                Text(translation).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !text.places.isEmpty {
                Text(text.places.joined(separator: "  ·  ")).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                TextField("New English", text: store.binding(text, \.english), axis: .vertical)
                if language != "en" {
                    TextField("New \(language)", text: store.translationBinding(text, language), axis: .vertical)
                }
                TextField("Note", text: store.binding(text, \.note), axis: .vertical)
            }
            .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 4)
        .padding(.leading, 6)
        .overlay(alignment: .leading) {
            if changed { RoundedRectangle(cornerRadius: 1.5).fill(.orange).frame(width: 3) }
        }
    }
}
#endif
