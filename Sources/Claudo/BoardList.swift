import ClaudoCore
import SwiftUI

/// The popover's one list. By date (the default) it is placed by one thing only, when each task is for: Today,
/// This week, Later (folded), then what got done this week, folded. Whether a task is a call or work, started
/// or waiting, is its row's mark, not a place. By project or by priority the same rows regroup
/// (`GroupedList`). In every view the filter narrows the list to some horizons, areas, kinds, statuses or
/// priorities; a group with nothing to list steps aside unless the filter picks its horizon.
struct BoardList: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if store.grouping == .date {
                byDate
            } else {
                GroupedList()
            }
        }
        .padding(.horizontal, Metrics.listInset)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    /// Never blank: with no horizon picked Today always shows, and a horizon the filter picks shows its group,
    /// empty or not.
    private var byDate: some View {
        let week = HorizonSection.listed(.week, store: store)
        let later = HorizonSection.listed(.later, store: store)
        return VStack(alignment: .leading, spacing: 0) {
            if store.shows(.today) {
                TodaySection()
            }
            if week {
                HorizonSection(horizon: .week)
                    .padding(.top, store.shows(.today) ? ListRhythm.group : 0)
            }
            if later {
                HorizonSection(horizon: .later)
                    .padding(.top, store.shows(.today) || week ? ListRhythm.group : 0)
            }
            DoneFold()
        }
    }
}

/// What got done, folded at the end of every view: the day's with Today alone, otherwise the week's. Later
/// alone has nothing to do with this week's done.
struct DoneFold: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let todayAlone = store.horizons == [.today]
        let done = store.horizons == [.later] ? [] : todayAlone ? store.listedDoneToday : store.listedDoneThisWeek
        if !done.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                DisclosureRow(title: todayAlone ? L("Done today", "Сделано сегодня")
                                  : L("Done this week", "Сделано за неделю"),
                              count: done.count, open: store.showDone) {
                    withAnimation(.snappy(duration: 0.22)) { store.showDone.toggle() }
                }
                .help(todayAlone ? L("Closed today", "Закрыто сегодня")
                      : L("Closed in the last 7 days, newest first", "Закрыто за последние 7 дней, сначала новые"))
                if store.showDone {
                    ForEach(done) { TaskRow(task: $0, context: todayAlone ? .today : .week) }
                }
            }
            .padding(.top, ListRhythm.group)
        }
    }
}

/// This week or Later: a header and the rows, the most important first, each with its area and why on a
/// second line like Today's. Later folds under its header until opened or until the filter picks it. Picked
/// alone it drops its header: the filter's chip under the header already says what this is.
struct HorizonSection: View {
    let horizon: Store.Horizon
    @EnvironmentObject var store: Store

    /// Whether the group shows at all: it has rows, the filter picks it, or a new task is being added to it.
    @MainActor static func listed(_ horizon: Store.Horizon, store: Store) -> Bool {
        guard store.shows(horizon) else { return false }
        return !rows(horizon, store: store).isEmpty || store.horizons.contains(horizon)
            || store.adding?.when == horizon.when
    }

    @MainActor static func rows(_ horizon: Store.Horizon, store: Store) -> [TaskItem] {
        horizon == .later ? store.listedLater : store.listedWeek
    }

    var body: some View {
        let rows = Self.rows(horizon, store: store)
        let picked = store.horizons.contains(horizon)
        let alone = store.horizons == [horizon]
        let adding = store.adding.flatMap { $0.when == horizon.when ? $0 : nil }
        // Later folds while the list holds more than Later; This week never does.
        let foldable = horizon == .later && !picked
        let open = !foldable || store.showLater || adding != nil
        VStack(alignment: .leading, spacing: 0) {
            if !alone {
                GroupHeader(title: horizon.title, count: rows.count, help: horizon.help,
                            open: foldable ? open : nil) {
                    withAnimation(.snappy(duration: 0.22)) { store.showLater.toggle() }
                }
            }
            if open {
                if let adding {
                    QuickAddRow(target: adding)
                        .padding(.top, alone ? 0 : 4)
                }
                if rows.isEmpty, adding == nil {
                    EmptyLine(text: store.filter.narrows ? store.nothingListed(horizon.place) : horizon.empty,
                              compact: !alone)
                }
                ForEach(rows) { TaskRow(task: $0, context: horizon == .later ? .later : .week) }
            }
        }
        .animation(.snappy(duration: 0.25), value: rows.map(\.id))
    }
}

extension Store.Horizon {
    var title: String {
        switch self {
        case .today: L("Today", "Сегодня")
        case .week: L("This week", "Эта неделя")
        case .later: L("Later", "Позже")
        }
    }

    var when: When {
        switch self {
        case .today: .today
        case .week: .week
        case .later: .later
        }
    }

    /// Where a filtered empty line says nothing is: "Nothing for Atlas this week".
    var place: String {
        switch self {
        case .today: L("on Today", "на сегодня")
        case .week: L("this week", "на этой неделе")
        case .later: L("for later", "на потом")
        }
    }

    /// The group's empty line, with no filter to blame.
    var empty: String {
        switch self {
        case .today: L("Nothing on Today", "На сегодня ничего нет")
        case .week: L("Nothing else this week", "На этой неделе больше ничего")
        case .later: L("Nothing kept for later", "Ничего не отложено")
        }
    }

    fileprivate var help: String {
        switch self {
        case .today: L("What to do today", "Что сделать сегодня")
        case .week: L("Not on Today, for this week: the most important first",
                      "Не на сегодня, но на этой неделе: сначала важное")
        case .later: L("Kept for later: the most important first", "Отложено на потом: сначала важное")
        }
    }
}

/// A group's title in the list: "Today  Sunday 25 October … 5 left · ≈3h", "This week 12", "Later 5 ›".
/// The one place 13 semibold sits on its own, a step over the 11.5 folds ("Done this week") and the rows'
/// 13 regular. A foldable group (Later) is a button with its chevron on the right edge.
struct GroupHeader: View {
    let title: String
    var count: Int? = nil
    /// After the title, in grey: Today's date.
    var detail: String? = nil
    /// On the right, in grey: Today's load.
    var trailing: String? = nil
    var trailingHelp: String? = nil
    var help: String? = nil
    /// Set for a group that folds: whether it is open now.
    var open: Bool? = nil
    /// A project's group: its symbol in its color before the title.
    var area: Area? = nil
    var toggle: () -> Void = {}
    @State private var hover = false

    var body: some View {
        if open != nil {
            Button(action: toggle) { content }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let area {
                SymbolMark(area: area, size: 12)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(open == false && !hover ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .help(help ?? "")
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let count {
                Text("\(count)")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.faint)
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(.snappy(duration: 0.3), value: count)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(trailingHelp ?? "")
            }
            if let open {
                DisclosureChevron(open: open)
            }
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
