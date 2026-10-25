import AppKit
import ClaudoCore
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// Resolved at draw time, so it follows the popover's (or the menu bar's) appearance.
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: .adaptive(light: light, dark: dark))
    }
}

/// The few colors that carry meaning. Coral is Claude's voice: focus, NEW, advice, planning; no area wears it.
enum Palette {
    /// Coral as a fill or a glyph.
    static let coral = Color(light: 0xD97757, dark: 0xE8896A)
    /// Coral as text: darker on light backgrounds (≈3.7:1), where the fill's coral reads at under 3:1.
    static let coralText = Color(light: 0xC2603E, dark: 0xE8896A)
    /// Grey between `.secondary` and `.tertiary` (≈3:1): counts, shares, the "Later" rule — read, not studied.
    /// `.secondary` carries what the owner reads (dates, estimates, the load); `.tertiary` only placeholders
    /// and disabled controls.
    static let faint = Color(light: 0x8A8A8E, dark: 0x7C7C80)
    static let doing = Color(light: 0x2F7CF6, dark: 0x5C9DFF)
    static let waiting = Color(light: 0xE8870E, dark: 0xF5A524)
    static let done = Color(light: 0x2EA44F, dark: 0x3FC866)
    static let urgent = Color(light: 0xE5484D, dark: 0xFF6369)
    /// Today's sun: a due-today date, as text (≈4:1 on light).
    static let today = Color(light: 0xA86400, dark: 0xFFC53D)
    static let quiet = Color(light: 0x8A8A8E, dark: 0x98989F)
}

extension AreaColor {
    var color: Color {
        switch self {
        // Coral is Claude's: an area the planner colors coral wears the rose instead.
        case .coral, .pink: Color(light: 0xE5457A, dark: 0xFF6B97)
        case .orange: Color(light: 0xF0861F, dark: 0xFF9F43)
        case .yellow: Color(light: 0xD9A200, dark: 0xFFD23F)
        case .green: Color(light: 0x34A853, dark: 0x4CD471)
        case .mint: Color(light: 0x00AE9E, dark: 0x45D9C6)
        case .teal: Color(light: 0x2A98B8, dark: 0x5CC8E0)
        case .blue: Color(light: 0x2F7CF6, dark: 0x4C9BFF)
        case .indigo: Color(light: 0x5856D6, dark: 0x7D7AFF)
        case .purple: Color(light: 0x9E4FD8, dark: 0xBF7BF0)
        case .graphite: Color(light: 0x8A8A8E, dark: 0x8E8E93)
        }
    }
}

extension Area {
    /// The inbox in the interface's language; every other area as Claude named it.
    var title: String { id == Area.inboxID ? L("Inbox", "Входящие") : name }
}

extension TaskStatus {
    var label: String {
        switch self {
        case .todo: L("To Do", "Не начато")
        case .doing: L("In Progress", "В работе")
        case .waiting: L("Waiting", "Ждёт")
        case .done: L("Done", "Готово")
        case .dropped: L("Dropped", "Отменено")
        }
    }

    /// How Claude's advice reads on a row: "Done?".
    var question: String {
        switch self {
        case .todo: L("Reopen?", "Вернуть?")
        case .doing: L("In progress?", "В работе?")
        case .waiting: L("Waiting?", "Ждёт?")
        case .done: L("Done?", "Готово?")
        case .dropped: L("Drop?", "Отменить?")
        }
    }

    /// ⌥-click on the status glyph walks the open statuses.
    var next: TaskStatus {
        switch self {
        case .todo: .doing
        case .doing: .waiting
        case .waiting, .done, .dropped: .todo
        }
    }
}

extension Priority {
    var label: String {
        switch self {
        case .urgent: L("Urgent", "Срочный")
        case .high: L("High", "Высокий")
        case .medium: L("Medium", "Средний")
        case .low: L("Low", "Низкий")
        }
    }
}

extension When {
    var label: String {
        switch self {
        case .today: L("Today", "Сегодня")
        case .week: L("This Week", "Эта неделя")
        case .later: L("Later", "Позже")
        }
    }

    var shortLabel: String {
        switch self {
        case .today: L("Today", "Сегодня")
        case .week: L("Week", "Неделя")
        case .later: L("Later", "Позже")
        }
    }
}

extension Day {
    /// The coming Monday (a week ahead on a Monday): where weekend errands that need office hours go.
    var nextMonday: Day {
        let weekday = Calendar.current.component(.weekday, from: date())
        let ahead = (9 - weekday) % 7
        return adding(days: ahead == 0 ? 7 : ahead)
    }
}

enum Symbols {
    /// Claude picks area symbols from a list, but a name this macOS lacks would draw nothing.
    static func valid(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "folder.fill"
    }
}

/// Shared metrics so rows and section headers line up on one text column.
enum Metrics {
    static let popoverWidth: CGFloat = 420
    /// The popover has one size, whatever it shows: the tabs' row, the list, the status bar. Switching tabs,
    /// expanding a row or an undo never resizes it. ~600 pt fits a small laptop screen under the menu bar, and
    /// Today's first screen should fit the list without scrolling (`--render` prints it).
    static let headerHeight: CGFloat = 44
    static let listHeight: CGFloat = 520
    static let statusBarHeight: CGFloat = 34
    static var popoverHeight: CGFloat { headerHeight + listHeight + statusBarHeight }
    /// The line of removable filter chips under the tabs while a filter is on; it takes its height from the list.
    static let chipRowHeight: CGFloat = 30
    /// List inset from the popover edge, and the row's own inset inside it.
    static let listInset: CGFloat = 8
    static let rowInset: CGFloat = 10
    /// The status glyph / area tile column; text starts after it plus `gutter`.
    static let glyph: CGFloat = 18
    static let gutter: CGFloat = 10
    static var textColumn: CGFloat { glyph + gutter }
    /// A narrow column at the start of a row's secondary lines: the why's area dot, the advice's ✦, the
    /// lead's ▶, the dates' icons. The text after it starts `mark + markGap` in, so those lines share an edge.
    static let mark: CGFloat = 6
    static let markGap: CGFloat = 5
}

/// True inside debug renders: ImageRenderer draws text fields as placeholders, so views swap in plain text.
private struct RenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var rendering: Bool {
        get { self[RenderingKey.self] }
        set { self[RenderingKey.self] = newValue }
    }
}
