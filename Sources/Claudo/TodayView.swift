import ClaudoCore
import SwiftUI

/// Today, the list's first group: the day and what is left of it, the week's focus, one row to start with,
/// the rest in the plan's order (the diamond tells a call from work, so no headers split them), then the
/// waiting rows whose day to check back has come. No sub-headers: a status is a row's mark, not a place.
/// Under a filter there is no card: the lead is where the plan starts, not where the filter does. What got
/// done is in the list's "Done this week"; whether the plan is today's lives in the status bar.
struct TodaySection: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let open = store.listedToday
        let plan = TodayPlan(open: open)
        // The card is where the plan starts; a list filtered to some areas, kinds or statuses is plain rows.
        let lead = store.filter.narrows ? nil : plan.lead
        let rest = lead == nil ? (plan.lead.map { [$0] } ?? []) + plan.rest : plan.rest
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(title: L("Today", "Сегодня"), detail: Fmt.longDay(Day(store.now)), trailing: load(open),
                        trailingHelp: L("What is still open on Today, and your time on it (estimated)",
                                        "Что ещё открыто на сегодня и сколько это займёт (оценка)"))
            if !store.board.focus.isEmpty {
                FocusLine(text: store.board.focus)
                    .padding(.top, 3)
            }
            if let target = store.adding, target.when == .today {
                QuickAddRow(target: target)
                    .padding(.top, 8)
            }
            if open.isEmpty {
                TodayEmpty(done: store.listedDoneToday.count)
            }
            if let lead {
                TaskRow(task: lead, context: .today, lead: true)
                    .padding(.top, 8)
            }
            // Waiting rows whose day to check back has come close the day, as plain rows: the ↩ glyph says it.
            let rows = rest + plan.checkIns
            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rows) { TaskRow(task: $0, context: .today) }
                }
                .padding(.top, lead == nil ? 6 : 4)
            }
        }
        .animation(.snappy(duration: 0.25), value: open.map(\.id))
    }

    /// "5 left · ≈3h"; empty once nothing is open: the line below says how the day went.
    private func load(_ open: [TaskItem]) -> String? {
        guard !open.isEmpty else { return nil }
        let hours = TodayPlan.hours(open)
        return L("\(open.count) left", "осталось \(open.count)") + (hours > 0 ? " · " + Fmt.approx(hours) : "")
    }
}

/// The spacing the list's groups share, so one rhythm runs down the list.
enum ListRhythm {
    /// Between the list's groups: Today, This week, Later, Done.
    static let group: CGFloat = 18
}

/// The week's focus as one quiet line under the day; a click unfolds the rest. Folded it is one line with an
/// ellipsis, never a sentence cut into a broken second line.
private struct FocusLine: View {
    let text: String
    @EnvironmentObject var store: Store
    @State private var hover = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { store.showFocus.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "scope")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.coral)
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineSpacing(1.5)
                    .lineLimit(store.showFocus ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.horizontal, Metrics.rowInset)
        .help(store.showFocus ? L("This week's focus", "Фокус недели") : text)
    }
}

/// Today with nothing open: good news or a filter, in one quiet line. The rest of the list is right below it,
/// so it points nowhere.
private struct TodayEmpty: View {
    let done: Int
    @EnvironmentObject var store: Store

    var body: some View {
        if store.filter.narrows {
            EmptyLine(text: store.nothingListed(Store.Horizon.today.place, left: done > 0), compact: true)
        } else if done > 0 {
            EmptyLine(text: L("All done for today", "На сегодня всё сделано"), done: true, compact: true)
        } else {
            EmptyLine(text: Store.Horizon.today.empty, compact: true)
        }
    }
}

/// An empty list in one quiet line with at most one way on: "Nothing open", "Nothing for Atlas on Today".
/// An empty list is good news or a filter, never an alarm, so it stays small and grey.
struct EmptyLine: View {
    let text: String
    /// The list is empty because its work got done: the done glyph leads.
    var done = false
    /// Inside a group, on the rows' text edge under its header, instead of centered in the list.
    var compact = false
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if done {
                StatusGlyph(status: .done, size: 11)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
                    .padding(.trailing, 1)
            }
            Text(text)
                .foregroundStyle(.secondary)
            if let actionTitle {
                Text("·").foregroundStyle(Palette.faint)
                QuietLink(title: actionTitle, action: action)
            }
        }
        .font(.system(size: 11.5))
        .multilineTextAlignment(compact ? .leading : .center)
        .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
        .padding(.leading, Metrics.rowInset + (compact ? Metrics.textColumn : 0))
        .padding(.trailing, Metrics.rowInset)
        .padding(.vertical, compact ? 6 : 30)
    }
}

/// A way on from a quiet line: plain text that answers the pointer, no capsule and no color of its own.
private struct QuietLink: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.medium)
                .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .underline(hover, color: .secondary)
                .contentShape(Rectangle())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A fold at the end of a list ("Done this week 3"): 11.5 semibold under the groups' 13, with its chevron where
/// a foldable group header keeps its own.
struct DisclosureRow: View {
    let title: String
    let count: Int
    let open: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text("\(count)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Palette.faint)
                Spacer(minLength: 0)
                DisclosureChevron(open: open)
            }
            .padding(.horizontal, Metrics.rowInset)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The fold's chevron, one width everywhere so group headers and folds keep it in one column.
struct DisclosureChevron: View {
    let open: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(Palette.faint)
            .rotationEffect(.degrees(open ? 90 : 0))
            .frame(width: 14)
    }
}

/// Inline "New task" row on top of its group: a row-sized field in the hover fill, so it reads as the row it
/// will become.
struct QuickAddRow: View {
    let target: Store.AddTarget
    @EnvironmentObject var store: Store
    @Environment(\.rendering) private var rendering
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.gutter) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.3, dash: [2.5, 2]))
                .frame(width: 15, height: 15)
                .frame(width: Metrics.glyph)
            if rendering {
                Text(placeholder).font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                field
            }
            Image(systemName: "return")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.faint)
                .help(L("Return adds it, Esc closes", "Return — добавить, Esc — закрыть"))
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    /// Enter adds and keeps the field open for the next one; Enter on an empty field or Esc closes it.
    private var field: some View {
        TextField(placeholder, text: $title)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .focused($focused)
            .onSubmit {
                let text = title
                title = ""
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.adding = nil
                } else {
                    withAnimation(.snappy(duration: 0.25)) { store.add(text, to: target) }
                }
            }
            .onExitCommand { store.adding = nil }
    }

    /// Where it lands, since the row says nothing else: "New task for today", "New task for this week in Atlas".
    private var placeholder: String {
        let when = switch target.when {
        case .today: L("for today", "на сегодня")
        case .week: L("for this week", "на эту неделю")
        case .later: L("for later", "на потом")
        }
        let task = L("New task \(when)", "Новая задача \(when)")
        guard let id = target.area, id != Area.inboxID, let area = store.board.area(id) else { return task }
        return task + L(" in \(area.title)", " в \(area.title)")
    }
}

extension Store {
    /// An empty filtered list in words: "Nothing for Atlas on Today", "No decisions left for Atlas and Lumen
    /// on Today", "Nothing in progress for 3 areas this week". `place` is `Horizon.place` or a phrase like it,
    /// in the interface's language: "on Today", "for later".
    func nothingListed(_ place: String, left: Bool = false) -> String {
        // The inbox follows «для» in Russian, so it takes the genitive; the areas' own names don't decline.
        let names = (board.orderedAreas + [.inbox]).filter { filter.areas.contains($0.id) }
            .map { $0.id == Area.inboxID ? L("Inbox", "входящих") : $0.name }
        let and = L("and", "и")
        let who: String? = switch names.count {
        case 0: nil
        case 1: names[0]
        case 2: "\(names[0]) \(and) \(names[1])"
        // "for 3 areas", "для 3 проектов": the Russian noun after "для" is genitive.
        default: plural(names.count, "area", "areas", ru: ("проекта", "проектов", "проектов"))
        }
        // One status picked names it; several say nothing more than "nothing".
        let status = filter.statuses.count == 1 ? filter.statuses.first : nil
        return Loc.russian ? Self.nothingRU(who: who, place: place, kind: filter.kind, status: status,
                                            important: filter.important, left: left)
            : Self.nothingEN(who: who, place: place, kind: filter.kind, status: status,
                             important: filter.important, left: left)
    }

    private static func nothingEN(who: String?, place: String, kind: TaskKind?, status: TaskStatus?,
                                  important: Bool, left: Bool) -> String {
        let noun: String? = switch kind {
        case .decision: "decisions"
        case .task: "work"
        case nil: nil
        }
        var what = noun.map { "No " + (important ? "important " : "") + $0 }
            ?? (important ? "Nothing important" : "Nothing")
        if let status { what += " " + status.filterLabel.lowercased() }
        return what + (left ? " left" : "") + (who.map { " for \($0)" } ?? "") + " " + place
    }

    /// Russian puts who and where first and what is missing last: "Для Atlas на сегодня ничего нет",
    /// "Для Atlas и Lumen на сегодня не осталось решений", "Для 3 проектов на этой неделе ничего в работе нет".
    private static func nothingRU(who: String?, place: String, kind: TaskKind?, status: TaskStatus?,
                                  important: Bool, left: Bool) -> String {
        let state: String? = switch status {
        case .doing: "в работе"
        case .waiting: "в ожидании"
        default: nil
        }
        let what: String
        switch kind {
        case .decision, .task:
            let noun = kind == .decision ? (important ? "важных решений" : "решений")
                : (important ? "важных задач" : "задач")
            what = (left ? "не осталось " : "нет ") + noun + (state.map { " " + $0 } ?? "")
        case nil:
            let thing = "ничего" + (important ? " важного" : "")
            what = thing + (state.map { " " + $0 } ?? "") + (left ? " не осталось" : " нет")
        }
        let line = [who.map { "для " + $0 }, place, what].compactMap { $0 }.joined(separator: " ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}
