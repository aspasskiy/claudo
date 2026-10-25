import ClaudoCore
import SwiftUI

/// The one thing the status bar says, highest priority first: an error, an undo, a run, a run's result, an
/// older plan, today's plan, no plan at all. A pure function of the store, so the order is testable.
enum BarState: Equatable {
    case error(String)
    case undo(title: String)
    case running(stage: PlanStage?, started: Date)
    case result(String)
    /// An earlier day's plan; `carried` of its rows are still on Today (0: they are done or moved).
    case stale(planDay: Day?, carried: Int)
    case idle(planned: Date)
    case never

    static func resolve(error: String?, removed: String?, runStarted: Date?, stage: PlanStage?, notice: String?,
                        planIsStale: Bool, carried: Int, plannedAt: Date?) -> BarState {
        if let error { return .error(error) }
        if let removed { return .undo(title: removed) }
        if let runStarted { return .running(stage: stage, started: runStarted) }
        if let notice { return .result(notice) }
        guard let plannedAt else { return .never }
        if planIsStale { return .stale(planDay: Day(plannedAt), carried: carried) }
        return .idle(planned: plannedAt)
    }

    /// The case alone: what the bar crossfades on. The run's clock or a new stage is the same state.
    var key: Int {
        switch self {
        case .error: 0
        case .undo: 1
        case .running: 2
        case .result: 3
        case .stale: 4
        case .idle: 5
        case .never: 6
        }
    }
}

extension Store {
    var barState: BarState {
        .resolve(error: error, removed: removal?.task.title, runStarted: runStarted, stage: stage,
                 notice: planNotice?.text, planIsStale: planIsStale, carried: carriedOver.count,
                 plannedAt: board.plannedAt)
    }
}

/// The popover's one place for app state, at the bottom and always 34 pt: a plan running (with a coral line
/// along its top edge), what the run changed, how fresh the plan is, an undo, an error. It never pushes the
/// list around; a new state crossfades in place.
struct StatusBar: View {
    /// "✓ 31 this week" opens the list's Done fold; the popover scrolls there.
    var showWeekDone: () -> Void = {}
    @EnvironmentObject var store: Store

    var body: some View {
        let state = store.barState
        // Each side in a ZStack: while a new state fades in, the old one fades out in the same place instead of
        // being laid out beside it.
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                leading(state)
                    .id(state.key)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .trailing) {
                trailing(state)
                    .id(state.key)
                    .transition(.opacity)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        // The line starts on the popover's text edge (18 pt); the buttons' capsules end on its container edge (8).
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: Metrics.statusBarHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                Divider()
                if case .running(let stage, _) = state {
                    RunLine(fraction: Self.fraction(stage)).transition(.opacity)
                }
            }
        }
        .background(alignment: .topLeading) { PlanShortcut() }
        .animation(.easeInOut(duration: 0.2), value: state.key)
    }

    private static func fraction(_ stage: PlanStage?) -> Double? {
        if case .summarizing(let done, let total) = stage, total > 0 { return min(1, Double(done) / Double(total)) }
        return nil
    }

    // MARK: Left: a glyph and a line

    @ViewBuilder private func leading(_ state: BarState) -> some View {
        switch state {
        case .error(let text):
            HStack(spacing: 6) {
                BarGlyph(systemImage: "exclamationmark.triangle.fill", tint: Palette.urgent)
                Text(store.errorIsPlanFailure ? Fmt.failure(text) : text)
                    .foregroundStyle(.primary)
                    .truncationMode(.tail)
            }
            .help(text)
        case .undo(let title):
            HStack(spacing: 6) {
                BarGlyph(systemImage: "trash", tint: .secondary)
                Text(L("Removed", "Удалено")).fontWeight(.medium).foregroundStyle(.primary)
                Text(title).foregroundStyle(.secondary).truncationMode(.tail)
            }
        case .running(let stage, _):
            HStack(spacing: 7) {
                Spinner(size: 10, lineWidth: 1.6)
                    .foregroundStyle(Palette.coral)
                    .frame(width: 12)
                // A new stage is the same state: its words crossfade in place.
                Text(stageText(stage))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: stageText(stage))
            }
        case .result(let text):
            HStack(spacing: 6) {
                BarGlyph(systemImage: "sparkles", tint: Palette.coral)
                Text(text).fontWeight(.medium).foregroundStyle(Palette.coralText)
            }
            .help(L("What the last plan changed", "Что изменил последний план"))
        case .stale(let day, let carried):
            HStack(spacing: 6) {
                BarGlyph(systemImage: "arrow.clockwise", tint: Palette.waiting)
                StaleLine(day: day, today: Day(store.now), carried: carried, sessions: store.sessionsSincePlan ?? 0)
                    .help(staleHelp(carried: carried))
            }
        case .idle(let planned):
            IdleLine(planned: planned, showWeekDone: showWeekDone)
        case .never:
            Text(L("Not planned yet", "Ещё не спланировано")).foregroundStyle(.secondary)
        }
    }

    private func staleHelp(carried: Int) -> String {
        let rows = plural(carried, "row", "rows", ru: ("задача", "задачи", "задач"))
        var lines = [carried > 0
            ? L("\(rows) on Today \(carried == 1 ? "comes" : "come") from an earlier day's plan",
                "\(rows) на сегодня — из прежнего плана")
            : L("Today isn't planned yet; the last plan is from an earlier day",
                "Сегодня ещё не спланировано: последний план составлен раньше")]
        if let n = store.sessionsSincePlan, n > 0 {
            lines.append(plural(n, "Claude Code session", "Claude Code sessions",
                                ru: ("сессия Claude Code", "сессии Claude Code", "сессий Claude Code"))
                         + L(" since", " с тех пор"))
        }
        let meta = Self.meta(store.board)
        if !meta.isEmpty { lines.append(meta) }
        return lines.joined(separator: "\n")
    }

    private func stageText(_ stage: PlanStage?) -> String {
        switch stage {
        case .summarizing(let done, let total):
            L("Summarizing with \(store.compact.name) · \(done)/\(total)",
              "Сводка сессий (\(store.compact.name)) · \(done)/\(total)")
        case .planning(let sessions):
            L("Planning from \(Self.sessions(sessions))…", "Планирование: \(Self.sessions(sessions))…")
        case .scanning, nil:
            L("Reading \(store.lookback) days of sessions…", "Чтение сессий за \(Self.days(store.lookback))…")
        }
    }

    // MARK: Right: at most two actions

    @ViewBuilder private func trailing(_ state: BarState) -> some View {
        let empty = store.board.tasks.isEmpty && store.board.areas.isEmpty
        switch state {
        case .error:
            HStack(spacing: 2) {
                if store.errorIsPlanFailure {
                    BarButton(title: L("Retry", "Повторить"), style: .quiet,
                              help: L("Ask Claude to plan again (⌘R)", "Попросить Claude спланировать заново (⌘R)")) {
                        store.refresh()
                    }
                }
                BarIconButton(systemImage: "xmark", help: L("Dismiss", "Закрыть")) { store.dismissError() }
            }
        case .undo:
            Button {
                withAnimation(.snappy(duration: 0.25)) { store.undoRemove() }
            } label: {
                HStack(spacing: 5) {
                    Text(L("Undo", "Отменить")).fontWeight(.semibold).foregroundStyle(Palette.coralText)
                    Text("⌘Z").foregroundStyle(Palette.faint)
                }
                .padding(.horizontal, 10)
                .frame(height: 22)
                .contentShape(Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z", modifiers: .command)
            .help(L("Put it back", "Вернуть"))
        case .running(_, let started):
            Text(Fmt.elapsed(started, now: store.now))
                .foregroundStyle(Palette.faint)
                .padding(.trailing, 10)
                .help(L("Claude is reading your sessions and planning; you can keep working",
                        "Claude читает ваши сессии и составляет план; можно работать дальше"))
        case .result:
            BarIconButton(systemImage: "xmark", help: L("Dismiss", "Закрыть")) {
                withAnimation(.easeInOut(duration: 0.2)) { store.dismissPlanNotice() }
            }
        case .stale(_, let carried):
            HStack(spacing: 6) {
                if carried > 0 {
                    BarButton(title: L("Keep", "Оставить"), style: .quiet,
                              help: L("Keep \(carried == 1 ? "it" : "these \(carried)") for today, as planned",
                                      carried == 1 ? "Оставить на сегодня, как в плане"
                                                   : "Оставить эти \(carried) на сегодня, как в плане")) {
                        withAnimation(.snappy(duration: 0.25)) { store.keepForToday() }
                    }
                }
                BarButton(title: L("Plan today", "План на сегодня"), systemImage: "sparkles", style: .filled,
                          help: L("Ask Claude for today's plan from the last \(store.lookback) days of sessions (⌘R)",
                                  "Попросить у Claude план на сегодня по сессиям за "
                                      + "\(Self.days(store.lookback)) (⌘R)")) {
                    store.refresh()
                }
            }
        case .idle:
            BarButton(title: store.suggestsReplan ? L("Re-plan", "Обновить") : L("Plan", "Спланировать"),
                      systemImage: "sparkles", style: .text,
                      help: L("Ask Claude to plan again from the last \(store.lookback) days of sessions (⌘R)",
                              "Попросить Claude спланировать заново по сессиям за \(Self.days(store.lookback)) (⌘R)")) {
                store.refresh()
            }
        case .never:
            // The empty board's own button says it in the middle of the popover.
            if !empty {
                BarButton(title: L("Plan", "Спланировать"), systemImage: "sparkles", style: .text,
                          help: L("Ask Claude for a plan from the last \(store.lookback) days of sessions (⌘R)",
                                  "Попросить у Claude план по сессиям за \(Self.days(store.lookback)) (⌘R)")) {
                    store.refresh()
                }
            }
        }
    }

    /// The run's particulars, for the tooltip: "Sonnet · 571 sessions · 30 days · $0.31".
    static func meta(_ board: Board) -> String {
        var parts: [String] = []
        if let model = board.model { parts.append(model.capitalized) }
        if board.sessionCount > 0 { parts.append(sessions(board.sessionCount)) }
        if let days = board.days { parts.append(Self.days(days)) }
        if let cost = board.costUSD { parts.append(String(format: "$%.2f", cost)) }
        return parts.joined(separator: " · ")
    }

    /// "11 sessions", "11 сессий".
    static func sessions(_ n: Int) -> String { plural(n, "session", "sessions", ru: ("сессия", "сессии", "сессий")) }

    /// "11 sessions since", "+11 сессий": Russian's «с тех пор» would push the reason off the bar.
    static func since(_ n: Int) -> String { Loc.russian ? "+" + sessions(n) : sessions(n) + " since" }

    /// "30 days", "30 дней".
    static func days(_ n: Int) -> String { plural(n, "day", "days", ru: ("день", "дня", "дней")) }
}

/// "Planned 2h ago · 11 sessions since · ✓ 31 this week": when the plan is from, whether the day has moved past
/// it, and the week's done count, which opens them.
private struct IdleLine: View {
    let planned: Date
    let showWeekDone: () -> Void
    @EnvironmentObject var store: Store

    var body: some View {
        // The week's count ignores the filter: under one it would read "3 this week" against 31 elsewhere,
        // like lost work. The click still opens the (filtered) list.
        let done = store.doneThisWeek.count
        // One line: when it runs long, the plan's time, its longest part, truncates first.
        HStack(spacing: 4) {
            Text(Fmt.planned(planned, now: store.now))
                .foregroundStyle(.secondary)
                .help([Fmt.plannedAt(planned, now: store.now), StatusBar.meta(store.board)]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
            if store.suggestsReplan, let n = store.sessionsSincePlan {
                // The day has moved past this morning's plan: a quiet nudge, since a run costs.
                Text("·").foregroundStyle(Palette.faint)
                Text(StatusBar.since(n)).foregroundStyle(.secondary)
                    .help(L("Claude Code sessions you worked in since this plan",
                            "Сессии Claude Code, в которых вы работали после этого плана"))
            }
            if done > 0 {
                Text("·").foregroundStyle(Palette.faint)
                WeekDoneLink(count: done, action: showWeekDone)
            }
        }
    }
}

/// "✓ 31 this week": a click opens the list's Done fold, at its end.
private struct WeekDoneLink: View {
    let count: Int
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.done.opacity(0.85))
                // Ticking a row ticks the number.
                Text(L("\(count) this week", "\(count) за неделю"))
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(.snappy(duration: 0.3), value: count)
                    .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L("Show what got done this week, with Claude's reasons",
                "Показать, что сделано за неделю, с пояснениями Claude"))
    }
}

/// "5 from Saturday's plan · 11 sessions since": how many of Today's rows are an older day's, never "left"
/// (Today's own line says what is left). The sessions drop out rather than truncate when the buttons need room.
private struct StaleLine: View {
    let day: Day?
    let today: Day
    let carried: Int
    let sessions: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(sessions > 0 ? StatusBar.since(sessions) : nil)
            line(nil)
        }
    }

    private func line(_ since: String?) -> some View {
        (Text(lead).fontWeight(.medium).foregroundColor(.primary)
            + Text(since.map { " · " + $0 } ?? "").foregroundColor(.secondary))
            .fixedSize()
    }

    /// "5 from Saturday's plan", or the plan's name alone once none of its rows is left on Today.
    private var lead: String {
        Loc.russian ? russianLead : englishLead
    }

    private var englishLead: String {
        let name = day.map { Fmt.planName($0, today: today) } ?? "An older plan"
        guard carried > 0 else { return name }
        // "The 16 Oct plan" reads "5 from the 16 Oct plan" mid-sentence.
        let first = name.prefix(1).lowercased() + name.dropFirst()
        return "\(carried) from " + (name.hasPrefix("The ") || name.hasPrefix("An ") ? first : name)
    }

    /// «План от субботы», «5 из плана от субботы», «5 из плана от 16 окт.»: the tray's tooltip names it the same.
    private var russianLead: String {
        guard let day else { return carried > 0 ? "\(carried) из прежнего плана" : "Прежний план" }
        guard carried > 0 else { return Fmt.planName(day, today: today) }
        return "\(carried) из плана от \(Fmt.planDay(day, today: today))"
    }
}

/// The bar's leading glyph, one size and column for every state.
private struct BarGlyph: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 12)
    }
}

/// The bar's actions: a coral text link (Plan), a quiet capsule (Keep, Retry) or the one filled call to action
/// (Plan today). All 22 pt tall, so the bar's line never shifts between states.
private struct BarButton: View {
    enum Style { case text, quiet, filled }
    let title: String
    var systemImage: String? = nil
    let style: Style
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9.5, weight: .semibold))
                }
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, style == .text ? 10 : 8)
            .frame(height: 22)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }

    private var foreground: AnyShapeStyle {
        switch style {
        case .text: AnyShapeStyle(Palette.coralText)
        case .quiet: hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
        case .filled: AnyShapeStyle(.white)
        }
    }

    private var background: Color {
        switch style {
        case .text: Palette.coral.opacity(hover ? 0.12 : 0)
        case .quiet: Color.primary.opacity(hover ? 0.11 : 0.06)
        case .filled: Palette.coral.opacity(hover ? 0.88 : 1)
        }
    }
}

private struct BarIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// ⌘R plans from any state but a run, whichever button the bar shows: one shortcut in the whole popover.
private struct PlanShortcut: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Button("") { if !store.running { store.refresh() } }
            .keyboardShortcut("r", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The run's progress along the bar's top edge, 2 pt of coral: how far the summaries are, or a soft
/// sweep while Claude reads and plans (static in renders, which can't animate).
private struct RunLine: View {
    let fraction: Double?
    @Environment(\.rendering) private var rendering

    var body: some View {
        GeometryReader { g in
            let width = g.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.coral.opacity(0.14))
                if let fraction {
                    Rectangle()
                        .fill(Palette.coral)
                        .frame(width: max(4, width * fraction))
                        .animation(.snappy(duration: 0.5), value: fraction)
                } else if rendering {
                    sweep(at: 0.42, width: width)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        sweep(at: Self.phase(context.date), width: width)
                    }
                }
            }
        }
        .frame(height: 2)
        .clipped()
    }

    /// A segment a third of the bar wide, fading at both ends, crossing from off the left edge to off the right.
    private func sweep(at phase: Double, width: CGFloat) -> some View {
        let segment = width * 0.34
        return Rectangle()
            .fill(LinearGradient(colors: [Palette.coral.opacity(0), Palette.coral, Palette.coral.opacity(0)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: segment)
            .offset(x: -segment + (width + segment) * phase)
    }

    /// 0…1 over 1.6 s, eased so the segment glides in and out rather than ticking.
    private static func phase(_ date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}
