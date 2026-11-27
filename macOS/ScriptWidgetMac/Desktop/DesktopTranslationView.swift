import SwiftUI
import Translation

struct DesktopTranslationView: View {
    private struct Language: Identifiable {
        let id: String
        let name: String

        static let supported = [
            Self(id: "en", name: "English"),
            Self(id: "zh-Hans", name: "Chinese (Simplified)"),
            Self(id: "zh-Hant", name: "Chinese (Traditional)"),
            Self(id: "fr", name: "French"),
            Self(id: "de", name: "German"),
            Self(id: "it", name: "Italian"),
            Self(id: "ja", name: "Japanese"),
            Self(id: "ko", name: "Korean"),
            Self(id: "pt-BR", name: "Portuguese (Brazil)"),
            Self(id: "es", name: "Spanish")
        ]

        static func locale(for id: String) -> Locale.Language {
            Locale.Language(identifier: id)
        }
    }

    @State private var source = "en"
    @State private var target = "zh-Hans"
    @State private var input = ""
    @State private var output = ""
    @State private var error: String?
    @State private var request: Request?
    @State private var configuration: TranslationSession.Configuration?

    private struct Request: Equatable {
        let id = UUID()
        let input: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("From", selection: $source) { languageChoices }
                Button("Swap languages", systemImage: "arrow.left.arrow.right") {
                    let previous = source
                    source = target
                    target = previous
                    if !output.isEmpty { input = output }
                }
                .labelStyle(.iconOnly)
                .help("Swap languages")
                Picker("To", selection: $target) { languageChoices }
            }
            TextEditor(text: $input)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("Type or paste text to translate.")
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Text to translate")
                .frame(minHeight: 80)
            HStack {
                Button("Translate", systemImage: "translate", action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || input.utf8.count > 8_000 || source == target || request != nil)
                if request != nil { ProgressView().controlSize(.small).accessibilityLabel("Translating") }
                Spacer()
                if input.utf8.count > 8_000 {
                    Text("The text exceeds the 8 KB limit.").foregroundStyle(.red)
                } else if source == target {
                    Text("Choose different languages.").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(output.isEmpty ? "Translation appears here." : output)
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .accessibilityLabel(output.isEmpty ? "Translation output" : output)
            }
            .frame(minHeight: 64)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
            if let error { Text(error).foregroundStyle(.red) }
        }
        .onChange(of: input) { _, _ in clearResult() }
        .onChange(of: source) { _, _ in clearResult() }
        .onChange(of: target) { _, _ in clearResult() }
        .translationTask(configuration) { [request] session in
            guard let expected = request, self.request == expected else { return }
            do {
                let result = try await session.translate(expected.input)
                guard self.request == expected, !Task.isCancelled else { return }
                output = result.targetText
            } catch {
                guard self.request == expected, !Task.isCancelled else { return }
                self.error = "Translation couldn’t finish. Check that this language pair is supported and the language downloads are available."
            }
            if self.request == expected { self.request = nil }
        }
    }

    private var languageChoices: some View {
        ForEach(Language.supported) { language in Text(language.name).tag(language.id) }
    }

    private func start() {
        output = ""
        error = nil
        request = Request(input: input.trimmingCharacters(in: .whitespacesAndNewlines))
        if configuration == nil {
            configuration = .init(source: Language.locale(for: source), target: Language.locale(for: target))
        } else {
            configuration?.invalidate()
        }
    }

    private func clearResult() {
        configuration = nil
        request = nil
        output = ""
        error = nil
    }
}
