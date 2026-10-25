import ClaudoCore
import Foundation

/// The language picked in the menu: the system's, or one of the two the interface is written in. It is also the
/// language Claude writes the board in. Kept between launches (UserDefaults `language`).
enum AppLanguage: String, CaseIterable {
    case system, english, russian

    /// Russian when picked, or when the system prefers it; English otherwise.
    var isRussian: Bool {
        switch self {
        case .system: Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
        case .english: false
        case .russian: true
        }
    }

    /// The language the planner writes in: the system's may be one the interface doesn't speak. `claudo-cli`
    /// reads the same setting the same way.
    var planLanguage: String { PlanLanguage.forSetting(rawValue) }

    /// The menu item, each language in its own words.
    var title: String {
        switch self {
        case .system: L("Match System", "Как в системе")
        case .english: "English"
        case .russian: "Русский"
        }
    }
}

/// What the interface speaks right now. The store sets it at launch and whenever the menu changes it.
enum Loc {
    nonisolated(unsafe) static var russian = false

    /// For dates and numbers in the current language.
    static var locale: Locale { Locale(identifier: russian ? "ru_RU" : "en_US_POSIX") }
}

/// A piece of interface text, written in both languages where it is used: `L("Plan", "Спланировать")`.
func L(_ english: String, _ russian: String) -> String {
    Loc.russian ? russian : english
}

/// A count with its noun: "1 session", "5 sessions"; Russian has three forms: "1 сессия", "2 сессии", "5 сессий".
func plural(_ n: Int, _ one: String, _ many: String,
            ru: (one: String, few: String, many: String)) -> String {
    guard Loc.russian else { return "\(n) \(n == 1 ? one : many)" }
    let tens = n % 100, ones = n % 10
    let form = (11...14).contains(tens) ? ru.many : ones == 1 ? ru.one : (2...4).contains(ones) ? ru.few : ru.many
    return "\(n) \(form)"
}
