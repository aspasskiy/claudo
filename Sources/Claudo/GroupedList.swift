import ClaudoCore
import SwiftUI

/// The listed rows regrouped for the list's other two views, by project and by priority. The rows come in the
/// list's own order — Today's as planned, then This week's and Later's, the most important first — and keep it
/// inside each group, so every group reads now before later.
enum ListGroups {
    struct Row: Identifiable, Equatable {
        let task: TaskItem
        /// Where the date view lists it; the other views say it on the row.
        let horizon: Store.Horizon
        var id: String { task.id }
    }

    struct Group: Identifiable, Equatable {
        enum Key: Equatable {
            case area(Area)
            case priority(Priority)
        }

        let key: Key
        let rows: [Row]

        var id: String {
            switch key {
            case .area(let area): "area-\(area.id)"
            case .priority(let priority): "priority-\(priority.rawValue)"
            }
        }
    }

    /// The areas as the board orders them (by weight), the inbox last with the rows of areas the board no
    /// longer has; an area with nothing listed steps aside.
    static func byArea(_ rows: [Row], areas: [Area]) -> [Group] {
        let known = Set(areas.map(\.id))
        let grouped = Dictionary(grouping: rows) { known.contains($0.task.area) ? $0.task.area : Area.inboxID }
        return (areas.filter { $0.id != Area.inboxID } + [.inbox]).compactMap { area in
            grouped[area.id].map { Group(key: .area(area), rows: $0) }
        }
    }

    /// Urgent, High, Medium, Low; a priority with nothing listed steps aside.
    static func byPriority(_ rows: [Row]) -> [Group] {
        let grouped = Dictionary(grouping: rows, by: \.task.priority)
        return Priority.allCases.compactMap { priority in
            grouped[priority].map { Group(key: .priority(priority), rows: $0) }
        }
    }
}

/// The list by project or by priority: a header per group, its rows below, each row saying the horizon its
/// group no longer does ("Today", "Later"). No lead card and no fold for Later: the date view is where the
/// day is planned, these are where the work is surveyed. A quick add opens on top, its placeholder saying
/// where the task lands; what got done folds at the end, as in the date view.
struct GroupedList: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let groups = store.listedGroups
        VStack(alignment: .leading, spacing: 0) {
            if let adding = store.adding {
                QuickAddRow(target: adding)
                    .padding(.bottom, groups.isEmpty ? 0 : ListRhythm.group - 6)
            }
            if groups.isEmpty, store.adding == nil {
                let empty = store.filter.isActive ? store.nothingListed(store.listedPlace)
                    : L("Nothing open", "Нет открытых задач")
                EmptyLine(text: empty, compact: true)
            }
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                GroupSection(group: group, grouping: store.grouping)
                    .padding(.top, index == 0 ? 0 : ListRhythm.group)
            }
            DoneFold()
        }
        .animation(.snappy(duration: 0.25), value: groups.map(\.id))
    }
}

/// One project or priority: its header, then its rows.
private struct GroupSection: View {
    let group: ListGroups.Group
    let grouping: Store.Grouping
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch group.key {
            case .area(let area):
                GroupHeader(title: area.title, count: group.rows.count, help: Self.help(area), area: area)
            case .priority(let priority):
                GroupHeader(title: priority.label, count: group.rows.count, help: priority.help)
            }
            // With one horizon picked its chip says it: no row repeats "Today", and Later's rows aren't quieter.
            let alone = store.horizons.count == 1
            ForEach(group.rows) { row in
                TaskRow(task: row.task, context: row.horizon.context, quiet: row.horizon == .later && !alone,
                        grouping: grouping, marksHorizon: !alone)
            }
        }
        .animation(.snappy(duration: 0.25), value: group.rows.map(\.id))
    }

    /// What is going on there and what this week should bring, as the filter's areas say it.
    private static func help(_ area: Area) -> String {
        let outcome = area.outcome.isEmpty ? "" : L("This week: \(area.outcome)", "На этой неделе: \(area.outcome)")
        return [area.status, outcome]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension Store.Horizon {
    /// The row's context: what its hover action moves it to, and whether a due-today date is news.
    var context: TaskRow.Context {
        switch self {
        case .today: .today
        case .week: .week
        case .later: .later
        }
    }
}

extension Priority {
    fileprivate var help: String {
        switch self {
        case .urgent: L("Urgent: can't wait", "Срочный: не ждёт")
        case .high: L("High priority", "Высокий приоритет")
        case .medium: L("Medium priority", "Средний приоритет")
        case .low: L("Low priority", "Низкий приоритет")
        }
    }
}

extension Store.Grouping {
    /// The header's tab.
    var title: String {
        switch self {
        case .date: L("Schedule", "Расписание")
        case .project: L("Projects", "Проекты")
        case .priority: L("Priority", "Приоритет")
        }
    }

    /// The tab's symbol: Priority's bars are the priority picker's.
    var symbol: String {
        switch self {
        case .date: "calendar"
        case .project: "folder"
        case .priority: "cellularbars"
        }
    }

    var help: String {
        switch self {
        case .date: L("Today, This week, Later", "Сегодня, Эта неделя, Позже")
        case .project: L("Each project's tasks, today's first",
                         "Задачи по проектам, сначала сегодняшние")
        case .priority: L("Urgent, High, Medium, Low; today's first in each",
                             "Срочный, высокий, средний, низкий; в каждом сначала сегодняшние")
        }
    }
}

extension Store {
    /// Where an empty filtered list says nothing is, for the horizons the filter picks: "on Today", "this week".
    var listedPlace: String {
        let on = Horizon.allCases.filter { horizons.contains($0) }
        return on.count == 1 ? on[0].place : L("on the board", "на доске")
    }
}
