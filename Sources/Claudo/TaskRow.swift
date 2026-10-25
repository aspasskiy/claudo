import AppKit
import ClaudoCore
import SwiftUI

/// One task, as few lines as it needs: the title with at most two facts on the right of its first line, then
/// the area's dot and the why on one line. Today's first row is the lead: a raised card with the whole why, the
/// start of the note and a way into its session. Click expands, double-click renames. Nothing in a row moves
/// under the pointer: the hover actions float over the facts, which fade out beneath them.
struct TaskRow: View {
    /// The group the row is listed in.
    enum Context { case today, week, later }

    let task: TaskItem
    let context: Context
    /// Today's first row in the plan's order: where to start.
    var lead = false
    /// Title and facts on one line.
    var compact = false
    /// A step quieter: kept, not for now.
    var quiet = false
    /// The view the row is listed in. By project or by priority the row says its horizon itself ("Today",
    /// "Later") and leaves out what its group already says: the area's dot, the urgent mark.
    var grouping: Store.Grouping = .date
    /// Whether a project or priority row says its horizon: not when the filter picks that one alone.
    var marksHorizon = true
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let expanded = store.expanded == task.id
        let hover = hovering || store.debugHover == task.id
        let oneLine = compact && task.status.isOpen && !lead
        let padding: CGFloat = lead ? 11 : oneLine ? 5 : 6.5
        HStack(alignment: .top, spacing: Metrics.gutter) {
            StatusButton(task: task)
                .frame(width: Metrics.glyph, height: Self.glyphLine(lead: lead))
            VStack(alignment: .leading, spacing: lead ? 4 : 2.5) {
                TitleLine(task: task, context: context, lead: lead, grouping: grouping, marksHorizon: marksHorizon,
                          lineLimit: expanded ? nil : oneLine ? 1 : lead ? 3 : 2,
                          actions: hover && !expanded && task.status.isOpen)
                if WhyLine.shows(task, oneLine: oneLine, lead: lead, expanded: expanded) {
                    WhyLine(task: task, full: lead || expanded, dot: grouping != .project)
                }
                if lead, !expanded {
                    LeadExtras(task: task)
                }
                if let advice = task.advice, task.status.isOpen {
                    AdviceLine(task: task, advice: advice)
                }
                if expanded {
                    DetailPanel(task: task)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, padding)
        .background { surface(expanded: expanded, hover: hover) }
        // In the leading margin, level with the status glyph. The lead says it with its card's coral edge
        // instead: a dot there would sit on the card's border.
        .overlay(alignment: .topLeading) {
            if task.isNew && task.status.isOpen && !lead {
                NewDot()
                    .padding(.top, padding + Self.glyphLine(lead: lead) / 2 - 5)
            }
        }
        .opacity(quiet && !expanded ? 0.72 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.22)) { store.tapRow(task.id) }
        }
        .onHover { hovering = $0 }
        .contextMenu { TaskMenu(task: task) }
    }

    /// The lead is a raised card (white on light, a lighter grey on dark), so it never reads as a row under the
    /// pointer; new from the last plan, its edge is coral. An open row is a flat, firmer fill; the pointer's row
    /// the faintest one.
    @ViewBuilder private func surface(expanded: Bool, hover: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: lead ? 10 : 8, style: .continuous)
        if lead {
            let dark = scheme == .dark
            let isNew = task.isNew && task.status.isOpen
            shape
                .fill(dark ? Color.white.opacity(hover ? 0.075 : 0.06) : Color.white.opacity(hover ? 0.85 : 0.7))
                .overlay(shape.strokeBorder(isNew ? Palette.coral.opacity(dark ? 0.55 : 0.5)
                                            : dark ? Color.white.opacity(0.08) : Color.primary.opacity(0.08),
                                            lineWidth: isNew ? 1 : 0.5))
                .shadow(color: .black.opacity(dark ? 0 : 0.06), radius: 3, y: 1)
                .animation(.easeOut(duration: 0.12), value: hover)
        } else {
            shape
                .fill(Color.primary.opacity(expanded ? 0.06 : hover ? 0.035 : 0))
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }

    /// The height the status glyph is centered in: the title's first line (the lead's is larger).
    private static func glyphLine(lead: Bool) -> CGFloat {
        lead ? 17 : 16
    }
}

// MARK: - Status button

/// Click toggles done, ⌥-click walks todo → doing → waiting; right-click opens the menu. Under the pointer
/// an open circle previews the check a click would make, inside its fixed frame.
private struct StatusButton: View {
    let task: TaskItem
    @EnvironmentObject var store: Store
    @State private var hover = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                if NSEvent.modifierFlags.contains(.option) {
                    store.cycleStatus(task)
                } else {
                    store.toggleDone(task)
                }
            }
        } label: {
            ZStack {
                StatusGlyph(status: task.status, kind: task.kind, size: 15)
                // The check a click would make.
                if hover && task.status == .todo {
                    CheckShape()
                        .stroke(Color.secondary.opacity(0.7),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 6.5, height: 5)
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .contextMenu { StatusMenuItems(task: task) }
    }

    /// "Decision · To do — click to complete, ⌥-click for the next status".
    private var help: String {
        let what = (task.kind == .decision ? L("Decision · ", "Решение · ") : "") + task.status.inlineLabel
        let click = task.status.isOpen ? L("complete", "завершить") : L("reopen", "открыть снова")
        return L("\(what) — click to \(click), ⌥-click for the next status",
                 "\(what) — щелчок: \(click), ⌥-щелчок: следующий статус")
    }
}

// MARK: - Lines

/// The title, renamed in place on double-click.
private struct TitleText: View {
    let task: TaskItem
    var lineLimit: Int? = 2
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    @EnvironmentObject var store: Store
    @Environment(\.rendering) private var rendering
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if store.editing == task.id && rendering {
            Text(task.title)
                .font(.system(size: size, weight: weight))
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1.5))
        } else if store.editing == task.id {
            TextField(L("Title", "Название"), text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: size, weight: weight))
                .focused($focused)
                .onAppear {
                    draft = task.title
                    // Focus only sticks once the field is in the window.
                    DispatchQueue.main.async { focused = true }
                }
                .onSubmit { store.rename(task.id, draft) }
                .onExitCommand { store.editing = nil }
                // Clicking away keeps the edit, like Finder's rename.
                .onChange(of: focused) { _, isFocused in
                    if !isFocused, store.editing == task.id { store.rename(task.id, draft) }
                }
        } else {
            Text(task.title)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(task.status.isOpen ? .primary : .secondary)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The title with the row's facts on the right of its first line. Under the pointer the row's quick
/// actions take the facts' place: they float over the line, and the line is erased under them (fading in
/// from the left), so the row's own hover fill shows through. The title never re-truncates and nothing
/// moves; the same mechanism serves one-line, two-line and lead rows.
private struct TitleLine: View {
    let task: TaskItem
    let context: TaskRow.Context
    let lead: Bool
    let grouping: Store.Grouping
    let marksHorizon: Bool
    let lineLimit: Int?
    /// The pointer is on an open, folded row: show its actions.
    let actions: Bool
    @EnvironmentObject var store: Store

    var body: some View {
        let facts = Facts.any(task, context: context, lead: lead, grouping: grouping, marksHorizon: marksHorizon,
                              today: Day(store.now))
        let line = HStack(alignment: .firstTextBaseline, spacing: 0) {
            TitleText(task: task, lineLimit: lineLimit, size: lead ? 14 : 13, weight: lead ? .semibold : .regular)
            Spacer(minLength: facts ? 10 : 0)
            if facts {
                Facts(task: task, context: context, lead: lead, grouping: grouping, marksHorizon: marksHorizon)
            }
        }
        if store.editing == task.id || !task.status.isOpen {
            // Renaming offers no actions, and keeps the text field out of a compositing group.
            line
        } else {
            line
                .overlay(alignment: .trailingFirstTextBaseline) {
                    // The facts and the actions, whichever is wider, plus a fade: what the actions cover.
                    ZStack(alignment: .trailingFirstTextBaseline) {
                        if facts { Facts(task: task, context: context, lead: lead, grouping: grouping, marksHorizon: marksHorizon) }
                        HoverActions(task: task, context: context, lead: lead)
                    }
                    .hidden()
                    .background(Color.black)
                    .padding(.leading, HoverActions.fade)
                    .background(alignment: .leading) {
                        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: HoverActions.fade)
                    }
                    .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] + HoverActions.lift }
                    .opacity(actions ? 1 : 0)
                    .blendMode(.destinationOut)
                    .allowsHitTesting(false)
                }
                .compositingGroup()
                .overlay(alignment: .trailingFirstTextBaseline) {
                    HoverActions(task: task, context: context, lead: lead)
                        .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] + HoverActions.lift }
                        .opacity(actions ? 1 : 0)
                        .allowsHitTesting(actions)
                }
                .animation(.easeOut(duration: 0.12), value: actions)
        }
    }
}

/// At most two facts, plain text: the due or check-back day, then the estimate; a red ! in front when it
/// can't wait. Order carries the rest of the importance, and ▶ comes with the hover actions. A closed row's
/// one fact is when it was closed. By project or by priority the horizon takes the estimate's place: "Today"
/// in the sun's color, "Later" in grey, This week unmarked.
private struct Facts: View {
    let task: TaskItem
    let context: TaskRow.Context
    let lead: Bool
    let grouping: Store.Grouping
    let marksHorizon: Bool
    @EnvironmentObject var store: Store

    /// Hours matter when planning a day or a week, which is the date view's business. A decision is a call to
    /// make, not hours to spend (the lead's excepted: it is where the day starts); a waiting task's time is
    /// someone else's.
    static func showsEstimate(_ task: TaskItem, context: TaskRow.Context, lead: Bool, grouping: Store.Grouping) -> Bool {
        guard grouping == .date, let hours = task.estimate, hours > 0 else { return false }
        return task.status != .waiting && (task.kind == .task || lead)
    }

    /// The red !, except in the priority view's Urgent group, whose header says it.
    static func showsUrgent(_ task: TaskItem, grouping: Store.Grouping) -> Bool {
        task.priority == .urgent && grouping != .priority
    }

    /// The horizon a row's group no longer says: Today or Later, by project or by priority — unless the filter
    /// picks that horizon alone, and its chip says it for every row.
    static func horizon(context: TaskRow.Context, grouping: Store.Grouping, marks: Bool = true) -> String? {
        guard grouping != .date, marks else { return nil }
        return switch context {
        case .today: L("Today", "Сегодня")
        case .week: nil
        case .later: L("Later", "Позже")
        }
    }

    /// The due or check-back day, except today's on Today: the tab already says it.
    static func showsDue(_ task: TaskItem, context: TaskRow.Context, today: Day) -> Bool {
        guard let due = task.due else { return false }
        return context != .today || due != today
    }

    /// Whether the row has any fact to show, so a bare title can take the whole line.
    static func any(_ task: TaskItem, context: TaskRow.Context, lead: Bool, grouping: Store.Grouping, marksHorizon: Bool,
                    today: Day) -> Bool {
        guard task.status.isOpen else { return task.completedAt != nil }
        return showsUrgent(task, grouping: grouping) || showsDue(task, context: context, today: today)
            || showsEstimate(task, context: context, lead: lead, grouping: grouping)
            || horizon(context: context, grouping: grouping, marks: marksHorizon) != nil
    }

    var body: some View {
        let today = Day(store.now)
        if !task.status.isOpen {
            if let at = task.completedAt {
                Text(Fmt.closed(at, now: store.now))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.faint)
                    .fixedSize()
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // First, so a deadline reads after it: "Today  ⚑ Tomorrow", never "⚑ Tomorrow  Today".
                if let horizon = Self.horizon(context: context, grouping: grouping, marks: marksHorizon) {
                    Text(horizon)
                        .font(.system(size: 11, weight: context == .today ? .medium : .regular))
                        .foregroundStyle(context == .today ? AnyShapeStyle(Palette.today) : AnyShapeStyle(Palette.faint))
                        .help(context == .today ? L("On Today", "На сегодня")
                              : L("Kept for later", "Отложено на потом"))
                }
                let urgent = Self.showsUrgent(task, grouping: grouping)
                let due = task.due.flatMap { Self.showsDue(task, context: context, today: today) ? $0 : nil }
                // Only when there is something in it: an empty stack would still take its spacing.
                if urgent || due != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if urgent {
                            UrgentMark()
                        }
                        if let due {
                            DueChip(due: due, today: today, check: task.status == .waiting)
                        }
                    }
                }
                if Self.showsEstimate(task, context: context, lead: lead, grouping: grouping), let hours = task.estimate {
                    EstimateLabel(hours: hours)
                }
            }
            .fixedSize()
        }
    }
}

/// The area's dot, then why it matters now, on one line: enough to make the order legible at a glance; the
/// whole of it is a hover away, and in full on the lead and on an open row. A task Claude closed says why,
/// behind Claude's ✦ in the dot's place.
private struct WhyLine: View {
    let task: TaskItem
    let full: Bool
    /// The area's dot; the project view's header already names the area, and its column stays empty.
    var dot = true
    @EnvironmentObject var store: Store

    /// A row without a why is a title alone; a one-line row shows its why only once it is open; a closed row
    /// only Claude's reason for closing it.
    static func shows(_ task: TaskItem, oneLine: Bool, lead: Bool, expanded: Bool) -> Bool {
        guard task.status.isOpen else { return !(task.closedReason ?? "").isEmpty }
        return !task.why.isEmpty && (!oneLine || expanded)
    }

    var body: some View {
        let reason = task.status.isOpen ? nil : task.closedReason
        HStack(alignment: .firstTextBaseline, spacing: Metrics.markGap) {
            if reason != nil {
                Image(systemName: "sparkles")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Palette.coral)
                    .frame(width: Metrics.mark)
                    .help(L("Closed by Claude", "Закрыто Claude"))
            } else if dot {
                AreaDot(area: store.board.area(task.area))
            } else {
                Color.clear.frame(width: Metrics.mark, height: 1)
            }
            Text(reason ?? task.why)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineSpacing(1)
                .lineLimit(full ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .help(full ? "" : reason ?? task.why)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The row's area as a small dot in its color, centered on the why's lowercase letters; the name is a hover
/// away (the dot's hit area is wider than the dot, so the tooltip is easy to reach).
private struct AreaDot: View {
    let area: Area?

    var body: some View {
        Circle()
            .fill(area?.color.color ?? Palette.quiet)
            .frame(width: Metrics.mark, height: Metrics.mark)
            .padding(4)
            .contentShape(Rectangle())
            .help((area ?? .inbox).title)
            .padding(-4)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
    }
}

/// What a row offers under the pointer: ▶ back into its session, and the one quick move a step along its
/// horizon — "Not today" on Today, "Today" on This week, "This week" on Later. Drawn over the facts by
/// `TitleLine`.
private struct HoverActions: View {
    let task: TaskItem
    let context: TaskRow.Context
    let lead: Bool
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if Self.offersResume(task, context: context, lead: lead) {
                ResumeButton(task: task)
            }
            if context == .today {
                HoverAction(title: L("Not today", "Не сегодня")) {
                    withAnimation(.snappy(duration: 0.25)) { store.notToday(task) }
                }
                .help(Self.notTodayHelp(task, today: Day(store.now)))
            } else if context == .later {
                HoverAction(title: L("This week", "Эта неделя")) {
                    withAnimation(.snappy(duration: 0.25)) { store.setWhen(task.id, .week) }
                }
                .help(L("Move it to This week", "Перенести на эту неделю"))
            } else {
                HoverAction(title: L("Today", "Сегодня")) {
                    withAnimation(.snappy(duration: 0.25)) { store.setWhen(task.id, .today) }
                }
                .help(L("Put it on Today", "Перенести на сегодня"))
            }
        }
        .fixedSize()
    }

    /// On the title's baseline the pills' smaller text sits low; this centers them on the title instead.
    static let lift: CGFloat = 1
    /// How far the title fades out before the actions: long enough that a glyph cut under them is gone.
    static let fade: CGFloat = 32

    /// The lead has its "Open session" button; Later's rows aren't for now.
    static func offersResume(_ task: TaskItem, context: TaskRow.Context, lead: Bool) -> Bool {
        context != .later && !lead && task.sessionId != nil && task.cwd != nil
    }

    /// Where "Not today" sends the row.
    static func notTodayHelp(_ task: TaskItem, today: Day) -> String {
        if let due = task.due, due <= today {
            return task.status == .waiting
                ? L("Off Today until tomorrow; the check-back day stays",
                    "Убрать с сегодня до завтра; день проверки остаётся")
                : L("Off Today until tomorrow; the deadline stays", "Убрать с сегодня до завтра; срок остаётся")
        }
        return L("Off Today, to This week", "Убрать с сегодня на эту неделю")
    }
}

/// The lead card's second half: the start of the note — often the first step itself — under the why, and the
/// way back into the session.
private struct LeadExtras: View {
    let task: TaskItem

    var body: some View {
        if !task.note.isEmpty {
            Text(task.note)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineSpacing(1)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Metrics.mark + Metrics.markGap)
        }
        if task.sessionId != nil, task.cwd != nil {
            OpenSessionPill(task: task)
                .padding(.top, 3)
        }
    }
}

/// Claude's suggestion on a task the owner set by hand, in Claude's color but as text: one click to accept,
/// × to dismiss.
private struct AdviceLine: View {
    let task: TaskItem
    let advice: Advice
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.markGap) {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.coral)
                .frame(width: Metrics.mark)
            (Text(advice.status.question).fontWeight(.medium).foregroundStyle(Palette.coralText)
                + Text(advice.reason.isEmpty ? "" : "  " + advice.reason).foregroundStyle(.secondary))
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(advice.reason)
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                TextAction(title: advice.status == .done ? L("Mark done", "Да, готово") : L("Apply", "Применить"),
                           tint: Palette.coralText) {
                    withAnimation(.snappy(duration: 0.25)) { store.acceptAdvice(task.id) }
                }
                Button {
                    withAnimation(.snappy(duration: 0.2)) { store.dismissAdvice(task.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.faint)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Dismiss Claude's suggestion", "Закрыть совет Claude"))
            }
            .padding(.trailing, -4)
        }
        .frame(minHeight: 18)
    }
}

// MARK: - Expanded detail

/// A calm inline inspector, in three bands: the note in full; one row of controls — status and priority as
/// compact menus, when as a segmented control; then a footer with the dates on the text column and the
/// actions as icons on the right (▶ open session, copy, rename, and delete apart). The status menu has no
/// Done: the glyph on the left is how a task gets done.
private struct DetailPanel: View {
    let task: TaskItem
    @EnvironmentObject var store: Store

    var body: some View {
        let since = onTodaySince
        VStack(alignment: .leading, spacing: 7) {
            if !task.note.isEmpty {
                Text(task.note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, Metrics.mark + Metrics.markGap)
            }
            // Russian runs longer: when the three don't fit at their size, the same three a little tighter.
            ViewThatFits(in: .horizontal) {
                controls(tight: false)
                controls(tight: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .center, spacing: 2) {
                if task.due != nil || since != nil {
                    DatesLine(task: task, since: since)
                }
                Spacer(minLength: 8)
                if task.sessionId != nil, task.cwd != nil {
                    IconButton(systemImage: "play.fill",
                               help: L("Open session in Terminal", "Открыть сессию в Терминале"), size: 9.5) {
                        store.resume(task)
                    }
                }
                IconButton(systemImage: "doc.on.doc",
                           help: L("Copy title and note", "Скопировать название и заметку")) {
                    store.copy(task)
                }
                IconButton(systemImage: "pencil", help: L("Rename", "Переименовать")) { store.editing = task.id }
                IconButton(systemImage: "trash",
                           help: task.origin == .user ? L("Delete", "Удалить")
                               : L("Remove from the board", "Убрать с доски"),
                           tint: Palette.urgent) {
                    withAnimation(.snappy(duration: 0.25)) { store.remove(task.id) }
                }
                .padding(.leading, 8)
            }
            // The icons' own padding: the trash's glyph lines up with the row's right edge.
            .padding(.trailing, -5)
        }
        .padding(.top, 6)
        // The icons' boxes are taller than their glyphs: the footer needs no air of its own below.
        .padding(.bottom, -3)
    }

    private func controls(tight: Bool) -> some View {
        HStack(spacing: tight ? 4 : 6) {
            MenuPill(title: task.status.inlineLabel,
                     glyph: AnyView(StatusGlyph(status: task.status, kind: task.kind, size: 10)),
                     help: L("Status", "Статус"), tight: tight) {
                StatusMenuItems(task: task, statuses: [.todo, .doing, .waiting])
            }
            PillPicker(options: When.allCases.map { .init(value: $0, label: $0.shortLabel) },
                       selection: task.when, tight: tight) { w in
                withAnimation(.snappy(duration: 0.25)) { store.setWhen(task.id, w) }
            }
            MenuPill(title: task.priority.label,
                     glyph: AnyView(PriorityGlyph(priority: task.priority, size: 10)),
                     help: L("Priority", "Приоритет"), tight: tight) {
                ForEach(Priority.allCases, id: \.self) { p in
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { store.setPriority(task.id, p) }
                    } label: {
                        if task.priority == p { Label(p.label, systemImage: "checkmark") } else { Text(p.label) }
                    }
                }
            }
        }
    }

    /// The first day of its current stretch on Today, once that is an earlier day.
    private var onTodaySince: Day? {
        let today = Day(store.now)
        return store.board.daysOnToday(task, now: store.now).flatMap { days -> Day? in
            days > 0 && task.status.isOpen ? today.adding(days: -days) : nil
        }
    }
}

/// "Due Mon 26 Oct · in 2 days" and "On Today since Sun 18 Oct · 6 days", their icons in the dot's column.
private struct DatesLine: View {
    let task: TaskItem
    let since: Day?
    @EnvironmentObject var store: Store

    var body: some View {
        let today = Day(store.now)
        VStack(alignment: .leading, spacing: 3) {
            if let due = task.due {
                let ahead = today.days(to: due)
                let day = Fmt.day(due)
                let label = task.status == .waiting ? L("Check back \(day)", "Проверить: \(day)")
                    : ahead < 0 ? L("Was due \(day)", "Срок прошёл: \(day)") : L("Due \(day)", "Срок: \(day)")
                line(task.status == .waiting ? "arrow.uturn.backward" : "calendar",
                     Text(label)
                        .foregroundStyle(ahead < 0 && task.status.isOpen ? AnyShapeStyle(Palette.urgent)
                                         : AnyShapeStyle(.secondary))
                        + Text(" · \(Fmt.relative(due, today: today))").foregroundStyle(Palette.faint))
            }
            if let since {
                let days = plural(since.days(to: today), "day", "days", ru: ("день", "дня", "дней"))
                line("arrow.clockwise",
                     Text(L("On Today since \(Fmt.day(since))", "На сегодня с \(Fmt.day(since))"))
                        .foregroundStyle(.secondary)
                        + Text(" · \(days)").foregroundStyle(Palette.faint))
            }
        }
        .font(.system(size: 11).monospacedDigit())
    }

    private func line(_ icon: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.markGap) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Palette.faint)
                .frame(width: Metrics.mark)
            text
        }
    }
}

private extension TaskStatus {
    /// A status inside the popover, in sentence case ("To do"); menus keep `label`'s title case.
    var inlineLabel: String {
        switch self {
        case .todo: L("To do", "Не начато")
        case .doing: L("In progress", "В работе")
        default: label
        }
    }
}

// MARK: - Menus (a convenience; every action also has a button)

private struct StatusMenuItems: View {
    let task: TaskItem
    var statuses: [TaskStatus] = [.todo, .doing, .waiting, .done]
    @EnvironmentObject var store: Store

    var body: some View {
        ForEach(statuses, id: \.self) { s in
            Button {
                withAnimation(.snappy(duration: 0.25)) { store.setStatus(task.id, s) }
            } label: {
                if task.status == s { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
            }
        }
    }
}

private struct TaskMenu: View {
    let task: TaskItem
    @EnvironmentObject var store: Store

    var body: some View {
        let today = Day(store.now)
        StatusMenuItems(task: task)
        Divider()
        if store.board.isOnToday(task, now: store.now) {
            // A row that is on Today because it falls due comes back tomorrow; its date stays.
            let back = task.due.map { $0 <= today } ?? false
            Button(back ? L("Not Today (Back Tomorrow)", "Не сегодня (вернётся завтра)") : L("Not Today", "Не сегодня")) {
                store.notToday(task)
            }
        } else if task.status.isOpen {
            Button(L("Today", "Сегодня")) { store.setWhen(task.id, .today) }
        }
        Menu(L("When", "Когда")) {
            ForEach(When.allCases, id: \.self) { w in
                Button(w.label) { store.setWhen(task.id, w) }
            }
        }
        Menu(L("Due", "Срок")) {
            Button(L("Today", "Сегодня")) { store.setDue(task.id, today) }
            Button(L("Tomorrow", "Завтра")) { store.setDue(task.id, today.adding(days: 1)) }
            Button(L("Next Monday", "В следующий понедельник")) { store.setDue(task.id, today.nextMonday) }
            Button(L("In a Week", "Через неделю")) { store.setDue(task.id, today.adding(days: 7)) }
            if task.due != nil {
                Divider()
                Button(L("No Due Date", "Без срока")) { store.setDue(task.id, nil) }
            }
        }
        Menu(L("Priority", "Приоритет")) {
            ForEach(Priority.allCases, id: \.self) { p in
                Button(p.label) { store.setPriority(task.id, p) }
            }
        }
        Menu(L("Move to", "Переместить в")) {
            ForEach(store.board.orderedAreas) { a in
                Button(a.title) { store.setArea(task.id, a.id) }
            }
            Button(Area.inbox.title) { store.setArea(task.id, Area.inboxID) }
        }
        Divider()
        if task.sessionId != nil, task.cwd != nil {
            Button(L("Open Session in Terminal", "Открыть сессию в Терминале")) { store.resume(task) }
        }
        Button(L("Rename", "Переименовать")) { store.expanded = task.id; store.editing = task.id }
        Button(L("Copy", "Скопировать")) { store.copy(task) }
        Divider()
        Button(task.origin == .user ? L("Delete", "Удалить") : L("Remove", "Убрать")) { store.remove(task.id) }
    }
}
