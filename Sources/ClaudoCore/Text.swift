import Foundation

extension String {
    /// The first `limit` characters, with "…" when anything was cut.
    func clipped(_ limit: Int) -> String {
        count <= limit ? self : String(prefix(limit)) + "…"
    }

    /// Both ends within `limit`: final replies tend to open with what was done and close with what's next.
    func headTail(_ limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit / 2)) + " … " + String(suffix(limit / 2))
    }

    /// The non-blank lines, trimmed and joined with " ⏎ ".
    var oneLine: String {
        split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
    }
}

extension Double {
    /// Hours as the board, the digest and the CLI write them: "2", "0.5". Never traps, whatever a hand-edited
    /// board holds.
    public var hoursText: String {
        self == rounded() && abs(self) < 1e9 ? String(Int(self)) : String(format: "%.1f", self)
    }
}

/// Dates and counts as the digest and the summarizer's input write them: English, day before month.
enum DigestFormat {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    private static let fullF = formatter("yyyy-MM-dd HH:mm")
    private static let shortF = formatter("dd.MM HH:mm")
    private static let dayF = formatter("dd.MM")
    private static let weekdayF = formatter("EEEE")

    static func full(_ d: Date) -> String { fullF.string(from: d) }
    static func short(_ d: Date) -> String { shortF.string(from: d) }
    static func day(_ d: Date) -> String { dayF.string(from: d) }
    static func weekday(_ d: Date) -> String { weekdayF.string(from: d) }
    static func day(_ d: Day) -> String { String(format: "%02d.%02d", d.day, d.month) }
    /// "1 prompt", "3 prompts".
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
