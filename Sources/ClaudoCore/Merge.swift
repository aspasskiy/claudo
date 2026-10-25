import Foundation

/// Folds one plan run into the live board. Rules: DESIGN.md › Merge rules.
/// Claude advises, the owner decides: pinned fields, owner titles and closed tasks are never
/// overridden; anything the run doesn't mention stays as it was.
public enum Merge {
    /// What a merge changed, for the CLI and a "3 new · 2 closed" line in the UI.
    public struct Summary: Sendable, Equatable {
        public var added = 0
        public var updated = 0
        public var closed = 0
        /// Closings turned into advice because the owner had set the status by hand.
        public var advised = 0

        public init() {}
    }

    /// Text caps (characters). The schema asks for them too, but nothing enforces that.
    enum Cap {
        static let title = 50
        static let note = 140
        static let why = 80
        static let areaStatus = 80
        static let outcome = 70
        static let focus = 140
        static let reason = 60
    }

    /// Closed tasks are kept this long, so re-suggestions can be recognized and swallowed: as long as the
    /// longest lookback, or a task the owner dropped comes back while its sessions are still read.
    static let closedTTL: TimeInterval = 30 * 86400

    public static func merge(_ result: PlanResult, into board: Board, now: Date = Date())
        -> (board: Board, summary: Summary) {
        var summary = Summary()
        let oldAreas = Dictionary(board.areas.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let cutoff = now.addingTimeInterval(-closedTTL)
        // The day this plan is for: owner's Today / not-today choices from earlier days no longer bind it.
        let planDay = Day(result.generatedAt)

        // Areas: the run's set and order, but an existing area keeps its look (rule 6).
        var areas: [Area] = []
        for var a in result.areas where a.id != Area.inboxID && !areas.contains(where: { $0.id == a.id }) {
            a.name = cap(a.name, Cap.title)
            a.status = cap(a.status, Cap.areaStatus)
            a.outcome = cap(a.outcome, Cap.outcome)
            a.attention = a.attention.map { min(100, max(0, $0)) }
            if let old = oldAreas[a.id] {
                a.color = old.color
                // The placeholder stands in for a symbol the run got wrong: a later run may pick a real one.
                if old.symbol != placeholderSymbol { a.symbol = old.symbol }
            }
            areas.append(a)
        }
        let validAreas = Set(areas.map(\.id)).union([Area.inboxID])

        // Rule 8 first: closed tasks older than 30 days go, and with them their ids and titles.
        var tasks = board.tasks
        tasks.removeAll { !$0.status.isOpen && ($0.completedAt ?? $0.updatedAt) < cutoff }
        for i in tasks.indices where tasks[i].status.isOpen {
            // A Today task without a day (from an older board) is dated by the last plan: write that day down
            // before the plan day moves, so a task this run doesn't mention stays carried over (rule 5).
            if tasks[i].when == .today && tasks[i].plannedFor == nil {
                tasks[i].plannedFor = board.plannedDay(of: tasks[i])
            }
            // A Today / not-today choice binds the plans of the day it was made (Later sticks): an older one
            // is released on every open task, mentioned by the run or not, so no stale pin outlives its day.
            // Bookkeeping, not an edit: updatedAt stays. A snooze is the owner's and is left alone.
            if tasks[i].pinned.contains(.when), !tasks[i].holdsWhenPin(on: planDay) {
                tasks[i].pinned.remove(.when)
                tasks[i].whenSetOn = nil
            }
        }

        // Tasks (rules 1–3).
        var touched = Set<String>()
        for (rank, planned) in result.tasks.enumerated() {
            let title = cap(planned.title, Cap.title)
            guard !title.isEmpty else { continue }
            var index = tasks.firstIndex { $0.id == planned.id }
            if index == nil {
                // Same task under a new id: recognize it by title, open or recently closed.
                let key = normalizedTitle(title)
                index = tasks.firstIndex { normalizedTitle($0.title) == key }
            }
            if let i = index {
                // A second suggestion of an already merged task adds nothing.
                guard touched.insert(tasks[i].id).inserted else { continue }
                if update(&tasks[i], with: planned, title: title, rank: rank, validAreas: validAreas,
                          planDay: planDay, now: now) {
                    summary.updated += 1
                }
            } else {
                let id = uniqueID(planned.id, taken: Set(tasks.map(\.id)))
                touched.insert(id)
                let session = planned.sessionId.isEmpty ? nil : planned.sessionId
                let today = planned.when == .today ? planDay : nil
                tasks.append(TaskItem(
                    id: id, title: title, note: cap(planned.note, Cap.note),
                    area: validAreas.contains(planned.area) ? planned.area : Area.inboxID,
                    status: planned.status.isOpen ? planned.status : .todo,
                    priority: planned.priority, when: planned.when,
                    estimate: planned.estimate > 0 ? planned.estimate : nil, rank: rank,
                    sessionId: session, cwd: session == nil ? nil : planned.cwd,
                    origin: .claude, createdAt: now, isNew: true,
                    why: cap(planned.why, Cap.why), due: planned.due, kind: planned.kind,
                    plannedFor: today, todaySince: today
                ))
                summary.added += 1
            }
        }

        // Closings (rule 4): the owner's own status choice turns a closing into advice.
        for closing in result.closed {
            guard let i = tasks.firstIndex(where: { $0.id == closing.id }), tasks[i].status.isOpen else { continue }
            let status: TaskStatus = closing.status == .dropped ? .dropped : .done
            let reason = cap(closing.reason, Cap.reason)
            if tasks[i].pinned.contains(.status) {
                let advice = Advice(status: status, reason: reason)
                guard tasks[i].advice != advice else { continue }
                tasks[i].advice = advice
                summary.advised += 1
            } else {
                tasks[i].status = status
                tasks[i].completedAt = now
                tasks[i].closedReason = reason.isEmpty ? nil : reason
                tasks[i].advice = nil
                summary.closed += 1
            }
            tasks[i].updatedAt = now
        }

        // An area the run dropped survives, parked, while it still holds open tasks (rule 6); the run
        // gave it no share of the week.
        for old in board.areas where !areas.contains(where: { $0.id == old.id }) {
            guard tasks.contains(where: { $0.area == old.id && $0.status.isOpen }) else { continue }
            var parked = old
            parked.weight = .parked
            parked.attention = nil
            areas.append(parked)
        }
        distinctColors(&areas, keeping: Set(oldAreas.keys))

        var merged = board
        merged.version = Board.currentVersion
        merged.focus = cap(result.focus, Cap.focus)
        merged.areas = areas
        merged.tasks = tasks
        merged.plannedAt = result.generatedAt
        merged.model = result.model
        merged.sessionCount = result.sessionCount
        merged.costUSD = result.costUSD
        merged.days = result.days
        // A fresh plan: nothing older is being kept.
        merged.keptOn = nil
        return (merged, summary)
    }

    /// Applies a planned task to a board task. Returns whether anything visible changed.
    private static func update(_ t: inout TaskItem, with p: PlanResult.PlannedTask, title: String, rank: Int,
                               validAreas: Set<String>, planDay: Day, now: Date) -> Bool {
        // Rule 2: Claude never reopens or edits what is already closed.
        guard t.status.isOpen else { return false }
        let before = t
        if t.origin == .claude, !t.pinned.contains(.title) { t.title = title }
        if !t.pinned.contains(.note) { t.note = cap(p.note, Cap.note) }
        t.why = cap(p.why, Cap.why)
        t.kind = p.kind
        if !t.pinned.contains(.due) { t.due = p.due }
        if !t.pinned.contains(.area), validAreas.contains(p.area) { t.area = p.area }
        if !t.pinned.contains(.status), p.status.isOpen { t.status = p.status }
        if !t.pinned.contains(.priority) { t.priority = p.priority }
        // The plan's Today is dated to its day; a stretch on Today keeps its first day. A when pin that
        // still holds (expired ones are gone by now) keeps the owner's own dates.
        if !t.pinned.contains(.when) {
            t.when = p.when
            if t.when == .today {
                t.plannedFor = planDay
                t.todaySince = before.when == .today ? (before.todaySince ?? before.plannedFor ?? planDay) : planDay
            } else {
                t.plannedFor = nil
                t.todaySince = nil
            }
        }
        if !t.pinned.contains(.estimate), p.estimate > 0 { t.estimate = p.estimate }
        // A known session link survives a run that didn't name one, or named it by the digest's short id
        // (an offline replay can't resolve it).
        if !p.sessionId.isEmpty, t.sessionId.map({ $0 == p.sessionId || !$0.hasPrefix(p.sessionId) }) ?? true {
            t.sessionId = p.sessionId
            t.cwd = p.cwd
        }
        // Claude lists it as open again, so an earlier "done?" no longer stands.
        t.advice = nil
        t.rank = rank
        var visible = before
        visible.rank = t.rank
        let changed = visible != t
        if changed { t.updatedAt = now }
        return changed
    }

    // MARK: Helpers

    /// What an area gets when the run names a symbol outside `Area.symbols`.
    static let placeholderSymbol = "folder.fill"

    /// New areas that collide with another area's color get the first unused one.
    private static func distinctColors(_ areas: inout [Area], keeping existing: Set<String>) {
        var used = Set<AreaColor>()
        for a in areas where existing.contains(a.id) { used.insert(a.color) }
        for i in areas.indices where !existing.contains(areas[i].id) {
            if used.contains(areas[i].color),
               let free = AreaColor.allCases.first(where: { $0 != .graphite && !used.contains($0) }) {
                areas[i].color = free
            }
            used.insert(areas[i].color)
        }
    }

    private static func uniqueID(_ proposed: String, taken: Set<String>) -> String {
        var base = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "c-" + UUID().uuidString.prefix(6).lowercased() }
        var id = base
        var n = 2
        while taken.contains(id) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    /// One line, at most `limit` characters: cut at a word boundary when one is close, then "…".
    static func cap(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let room = flat.prefix(limit - 1)
        var cut = room
        if let space = room.lastIndex(of: " "), room.distance(from: room.startIndex, to: space) >= limit * 3 / 5 {
            cut = room[..<space]
        }
        let trimmed = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:—–-"))
        return trimmed + "…"
    }

    /// Lowercased letters and digits only, ё folded to е: "Ещё раз: влить PR!" ≡ "еще раз влить pr".
    static func normalizedTitle(_ title: String) -> String {
        let folded = title.lowercased().replacingOccurrences(of: "ё", with: "е")
        let words = folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(words).split(separator: " ").joined(separator: " ")
    }
}
