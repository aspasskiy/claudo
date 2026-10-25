import ClaudoCore
import Foundation

/// Every date, count and duration the popover and the tray print, in the interface's language (`Loc`).
enum Fmt {
    /// One formatter per pattern and language: a switch in the menu redraws everything in the new one.
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    private static func string(_ format: String, ru: String? = nil, _ date: Date) -> String {
        let pattern = Loc.russian ? ru ?? format : format
        let key = "\(Loc.russian ? "ru" : "en") \(pattern)"
        if let f = formatters[key] { return f.string(from: date) }
        let f = DateFormatter()
        f.locale = Loc.locale
        f.dateFormat = pattern
        formatters[key] = f
        return f.string(from: date)
    }

    private static func time(_ date: Date) -> String { string("HH:mm", date) }
    private static func weekday(_ date: Date) -> String { lowerRU(string("EEE", date)) }
    private static func date(_ date: Date) -> String { string("d MMM", date) }

    /// ru_RU's "EEE" is «Пт» whatever the formatting context; Russian writes it «пт» mid-sentence.
    private static func lowerRU(_ text: String) -> String { Loc.russian ? text.lowercased() : text }

    /// "Sun 25 Oct", «вс, 25 окт.»: always mid-sentence («Срок: вс, 25 окт.»).
    static func day(_ date: Date) -> String { lowerRU(string("EEE d MMM", ru: "EEE, d MMM", date)) }
    static func day(_ day: Day) -> String { Fmt.day(day.date()) }
    static func longDay(_ day: Day) -> String { string("EEEE d MMMM", ru: "EEEE, d MMMM", day.date()) }

    /// "1 day", "6 days", "1 session", "11 sessions"; in Russian for the nouns the interface counts.
    static func count(_ n: Int, _ noun: String) -> String {
        if Loc.russian, let ru = russianNouns[noun] { return plural(n, noun, noun, ru: ru) }
        return "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private static let russianNouns: [String: (one: String, few: String, many: String)] = [
        "day": ("день", "дня", "дней"),
        "session": ("сессия", "сессии", "сессий"),
        "Claude Code session": ("сессия Claude Code", "сессии Claude Code", "сессий Claude Code"),
        "row": ("задача", "задачи", "задач"),
        "task": ("задача", "задачи", "задач"),
    ]

    /// "Friday's plan", or "The 16 Oct plan" once it is more than six days old.
    static func planName(_ day: Day, today: Day) -> String {
        let recent = day.days(to: today) < 7
        guard Loc.russian else {
            return recent ? "\(string("EEEE", day.date()))'s plan" : "The \(date(day.date())) plan"
        }
        return "План от \(planDay(day, today: today))"
    }

    /// The plan's day as "от" takes it, for a sentence that names the plan another way: "8 из плана от пятницы".
    /// English: "Friday", "16 Oct".
    static func planDay(_ day: Day, today: Day) -> String {
        guard day.days(to: today) < 7 else { return date(day.date()) }
        guard Loc.russian else { return string("EEEE", day.date()) }
        // The weekday after "от" takes the genitive, which no date format gives.
        let genitive = ["воскресенья", "понедельника", "вторника", "среды", "четверга", "пятницы", "субботы"]
        return genitive[Calendar.current.component(.weekday, from: day.date()) - 1]
    }

    /// "Planned just now", "Planned 25 min ago", "Planned 2h ago" today; "Planned yesterday 16:12",
    /// "Planned Fri 16:12" this week; "Planned 16 Oct" before. Relative today, so it never reads like the
    /// run's clock ("1:27") beside it. Russian says «План: 2 ч назад»: «Спланировано» leaves the status bar no
    /// room for the sessions since.
    static func planned(_ date: Date, now: Date) -> String {
        let back = Day(date).days(to: Day(now))
        if back <= 0 {
            let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
            if minutes < 1 { return L("Planned just now", "План: только что") }
            if minutes < 60 { return L("Planned \(minutes) min ago", "План: \(minutes) мин назад") }
            return L("Planned \(minutes / 60)h ago", "План: \(minutes / 60) ч назад")
        }
        if back == 1 { return L("Planned yesterday \(time(date))", "План: вчера в \(time(date))") }
        if back < 7 { return L("Planned \(weekday(date)) \(time(date))", "План: \(weekday(date)), \(time(date))") }
        return L("Planned \(Fmt.date(date))", "План: \(Fmt.date(date))")
    }

    /// The exact moment, for the tooltip: "Planned Sun 25 Oct 03:20".
    static func plannedAt(_ date: Date, now: Date) -> String {
        L("Planned \(day(date)) \(time(date))", "Спланировано \(day(date)), \(time(date))")
    }

    /// A failed plan run in plain words: "Claude usage limit reached · resets 6pm" instead of
    /// "claude exited 1: Claude AI usage limit reached|1729…". The raw text goes in the tooltip.
    static func failure(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("usage limit") || lower.contains("limit reached") || lower.contains("rate limit") {
            return L("Claude usage limit reached", "Достигнут лимит Claude")
                + (resetTime(in: text).map { L(" · resets \($0)", " · сброс в \($0)") } ?? "")
        }
        if lower.contains("cli not found") {
            return L("Claude Code isn't installed: no claude command found",
                     "Claude Code не установлен: команда claude не найдена")
        }
        if lower.contains("didn't parse") {
            return L("Claude's plan came back unreadable", "Claude вернул нечитаемый план")
        }
        if lower.contains("has no areas") { return L("Claude's plan came back empty", "Claude вернул пустой план") }
        if let m = text.firstMatch(of: #/(?i)no claude sessions in the last (\d+) days/#), let n = Int(m.1) {
            return L("No Claude sessions in the last \(n) days", "Нет сессий Claude за последние \(count(n, "day"))")
        }
        if let m = text.firstMatch(of: #/(?i)^(\S+) didn't answer in (\d+) min/#) {
            let who = m.1.prefix(1).uppercased() + m.1.dropFirst()
            return L("\(who) didn't answer in \(m.2) min", "\(who) не ответил за \(m.2) мин")
        }
        // Before the summarizer's own "Sonnet returned no summaries": claude's report can lack summaries too.
        if let m = text.firstMatch(of: #/(?i)^claude returned no (\w+)/#) {
            return m.1 == "plan" ? L("Claude returned no plan", "Claude не вернул план")
                : L("Claude returned no \(m.1)", "Claude не вернул сводки")
        }
        if let m = text.firstMatch(of: #/(?i)^(\S+) returned no summaries/#) {
            let model = m.1.prefix(1).uppercased() + m.1.dropFirst()
            return L("\(model) returned no summaries", "\(model) не вернул сводки")
        }
        // Planner: "claude exited 1: <its stderr>", "claude: <its result>".
        var rest = text
        var fromClaude = false
        for prefix in [#"^claude exited -?\d+:\s*"#, #"^claude:\s*"#] {
            if let r = rest.range(of: prefix, options: [.regularExpression, .caseInsensitive]) {
                rest.removeSubrange(r)
                fromClaude = true
            }
        }
        rest = rest.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard let first = rest.first else { return L("Claude stopped with an error", "Claude завершился с ошибкой") }
        // Claude's own words stay as it wrote them; in Russian a lead says whose they are.
        if Loc.russian, fromClaude { return "Claude завершился с ошибкой: " + rest }
        return first.uppercased() + rest.dropFirst()
    }

    /// "18:00" / "6pm" from "resets at 18:00", "reset at 6pm", or the CLI's "limit reached|<unix time>".
    private static func resetTime(in text: String) -> String? {
        if let r = text.range(of: #"\|\d{9,11}"#, options: .regularExpression),
           let seconds = TimeInterval(text[r].dropFirst()) {
            return time(Date(timeIntervalSince1970: seconds))
        }
        guard let r = text.range(of: #"resets?\s+(at\s+)?\d{1,2}(:\d{2})?\s?(am|pm)?"#,
                                 options: [.regularExpression, .caseInsensitive]) else { return nil }
        let words = text[r].split(separator: " ").dropFirst().filter { $0.lowercased() != "at" }
        return words.joined(separator: " ")
    }

    /// A due chip's words relative to today: "Overdue 2d", "Today", "Tomorrow", "Mon 26", "31 Dec".
    /// A waiting task's due is the day to check back; its chip draws ↩ in front of the day, and a day
    /// gone by reads "2d ago".
    static func due(_ due: Day, today: Day, check: Bool) -> String {
        let ahead = today.days(to: due)
        if ahead < 0 {
            let days = -ahead
            // Russian reads both as "2 дн. назад": the chip's red ⚑ or its ↩ tells which, and «Просрочено» would
            // push long titles onto a second line.
            return check ? L("\(days)d ago", "\(days) дн. назад") : L("Overdue \(days)d", "\(days) дн. назад")
        }
        switch ahead {
        case 0: return L("Today", "Сегодня")
        case 1: return L("Tomorrow", "Завтра")
        case 2..<7: return string("EEE d", ru: "EEE, d", due.date())
        default: return date(due.date())
        }
    }

    /// When a task was ticked: "09:40" today, "Fri" this week, "16 Oct" before.
    static func closed(_ date: Date, now: Date) -> String {
        let back = Day(date).days(to: Day(now))
        if back == 0 { return time(date) }
        return back < 7 ? weekday(date) : Fmt.date(date)
    }

    /// "in 2 days", "today", "2 days ago".
    static func relative(_ day: Day, today: Day) -> String {
        let ahead = today.days(to: day)
        switch ahead {
        case 0: return L("today", "сегодня")
        case 1: return L("tomorrow", "завтра")
        case -1: return L("yesterday", "вчера")
        case 2...: return L("in \(ahead) days", "через \(count(ahead, "day"))")
        default: return L("\(-ahead) days ago", "\(count(-ahead, "day")) назад")
        }
    }

    /// Owner attention: "5m", "15m", "1h", "2.5h".
    static func estimate(_ h: Double) -> String {
        if h < 0.95 { return L("\(minutes(h))m", "\(minutes(h)) мин") }
        return hours((h * 2).rounded() / 2)
    }

    /// "≈4h", "≈3.5h", "≈20 min": a sum of estimates, rounded the way people say it.
    static func approx(_ h: Double) -> String {
        h < 0.95 ? L("≈\(minutes(h)) min", "≈\(minutes(h)) мин") : "≈" + hours((h * 2).rounded() / 2)
    }

    /// Minutes in fives, at least five.
    private static func minutes(_ h: Double) -> Int { max(5, Int((h * 60 / 5).rounded()) * 5) }

    static func elapsed(_ from: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(from)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "2h", "2.5h"; "2 ч", "2,5 ч".
    static func hours(_ h: Double) -> String {
        let number = h.hoursText
        return L("\(number)h", "\(number.replacingOccurrences(of: ".", with: ",")) ч")
    }
}
