import Foundation

/// The language the model writes in: the board's texts and the session notes. Prompts and the digest stay
/// English whatever it is; the prompts name it in English, the way a model reads it best.
public enum PlanLanguage {
    /// The system's preferred language; "English" when it names none.
    public static var system: String {
        Locale.preferredLanguages.first.flatMap(known) ?? "English"
    }

    /// The app's Language setting (UserDefaults `language`: system | english | russian) as the language the
    /// model writes in: English or Russian when picked, the system's otherwise (it may be one the interface
    /// doesn't speak).
    public static func forSetting(_ stored: String?) -> String {
        switch stored {
        case "english": "English"
        case "russian": "Russian"
        default: system
        }
    }

    /// A locale identifier or a language name → the language's English name: "ru", "ru-US", "Russian",
    /// "русский" → "Russian". The region is dropped ("pt-BR" → "Portuguese"): on macOS it is mostly the
    /// device's, not the language's. A script other than the language's usual one is kept, since it changes
    /// what gets written: "zh-Hant", "zh-TW" → "Chinese, Traditional"; "sr-Latn" → "Serbian (Latin)". A name
    /// it doesn't know ("Brazilian Portuguese") is kept as written; empty text means the system's.
    public static func name(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return system }
        return known(text) ?? text
    }

    private static let english = Locale(identifier: "en_US_POSIX")

    /// Lowercased English and native names → language code: "russian" and "русский" → "ru".
    private static let codesByName: [String: String] = {
        var codes: [String: String] = [:]
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) {
            let names = [english.localizedString(forLanguageCode: code),
                         Locale(identifier: code).localizedString(forLanguageCode: code)]
            for name in names.compactMap({ $0?.lowercased() }) where codes[name] == nil { codes[name] = code }
        }
        return codes
    }()

    /// The English name of the language `text` codes or names; nil when it is neither.
    private static func known(_ text: String) -> String? {
        if let code = Locale.Language.Components(identifier: text).languageCode?.identifier,
           let name = english.localizedString(forLanguageCode: code) {
            // The script is inferred where only a region says it (zh-TW → Hant).
            if let script = Locale.Language(identifier: text).script,
               script != Locale.Language(identifier: code).script,
               let scripted = english.localizedString(forIdentifier: "\(code)-\(script.identifier)") {
                return scripted
            }
            return name
        }
        return codesByName[text.lowercased()].flatMap { english.localizedString(forLanguageCode: $0) }
    }
}
