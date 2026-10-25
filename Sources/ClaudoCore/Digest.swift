import Foundation

/// The digest: what one plan run reads, in English like the prompt, whatever language the board is written
/// in. The owner's day, the board as it stands, git, activity by folder, project memory, then the sessions
/// themselves, newest first.
extension Planner {
    /// Sessions this recent are shown in full; older ones as a short note of context.
    public static let detailDays = 7
    /// Total characters the digest may take; the oldest sessions are dropped first.
    static let budget = 460_000
    /// Memory indexes of the projects touched in the window, newest first, within this total.
    static let memoryBudget = 25_000
    /// A session that moved this recently is still going, whatever its last record says.
    static let liveWindow: TimeInterval = 2 * 3600
    /// Rows of the per-folder activity table, busiest first.
    static let activityRows = 15
    /// The owner's day, local hours: "hours left" counts to its end.
    static let dayStartHour = 7
    static let dayEndHour = 23
    /// Session ids appear in the digest by this prefix; `decode` resolves it back.
    static let shortIDLength = 8

    /// `compact` (from a compaction pass) swaps raw blocks for notes, and older noted sessions for one
    /// line each. `repos` is the git state of the week's folders (`GitState.scan`); empty leaves the
    /// section out.
    public func digest(sessions: [SessionDigest], board: Board, now: Date = Date(),
                       compact: CompactReport? = nil, repos: [RepoState] = []) -> String {
        let detailCutoff = now.addingTimeInterval(-Double(Self.detailDays) * 86400)
        let recent = sessions.filter { $0.end >= detailCutoff }
        let older = sessions.filter { $0.end < detailCutoff }

        let weekend = Day(now).isWeekend()
        var out = "Now: \(DigestFormat.full(now)), \(DigestFormat.weekday(now)) — "
            + "\(weekend ? "weekend" : "workday"), time zone \(TimeZone.current.identifier). "
            + "≈ \(Self.hoursLeft(now)) h left in the owner's day (until ~\(Self.dayEndHour):00).\n"
        out += "Window: the last \(DigestFormat.count(days, "day")), \(DigestFormat.count(sessions.count, "session"))"
        if !older.isEmpty {
            out += ": \(recent.count) from the last \(DigestFormat.count(Self.detailDays, "day")) in full, "
                + "\(older.count) older in brief"
        }
        out += "."
        if let compact {
            let noted = sessions.filter { compact.summaries[$0.id] != nil }.count
            if noted > 0 { out += " Compaction: \(DigestFormat.count(noted, "session")) summarized." }
        }
        out += "\n\n"
        out += Self.boardSection(board, now: now, sessions: sessions)
        out += Self.repoSection(repos)

        // Where the time went, by the folder a session was started in — often not its topic: the owner
        // starts errands from whatever folder is open, so the model must read titles, not this table.
        let wide = !older.isEmpty
        out += wide
            ? "# Activity by launch folder — the topic may differ (sessions / prompts over "
                + "\(DigestFormat.count(Self.detailDays, "day")) · over \(DigestFormat.count(days, "day")); "
                + "last session)\n"
            : "# Activity by launch folder — the topic may differ (sessions / prompts / last session)\n"
        func promptCount(_ group: [SessionDigest]) -> Int { group.reduce(0) { $0 + $1.prompts.count } }
        let rows = Dictionary(grouping: sessions, by: \.cwd).map { cwd, all in
            (cwd: cwd, all: all, week: all.filter { $0.end >= detailCutoff })
        }.sorted { a, b in
            (promptCount(a.week), promptCount(a.all)) > (promptCount(b.week), promptCount(b.all))
        }
        for row in rows.prefix(Self.activityRows) {
            let last = DigestFormat.short(row.all.map(\.end).max()!)
            out += wide
                ? "- \(Paths.tilde(row.cwd)): \(row.week.count) / \(promptCount(row.week)) · "
                    + "\(row.all.count) / \(promptCount(row.all)); \(last)\n"
                : "- \(Paths.tilde(row.cwd)): \(row.all.count) / \(promptCount(row.all)) / \(last)\n"
        }
        if rows.count > Self.activityRows {
            let rest = rows.dropFirst(Self.activityRows).flatMap(\.all)
            out += "- …\(rows.count - Self.activityRows) more folders: \(rest.count) / \(promptCount(rest))\n"
        }
        out += "\n"

        // Memory indexes carry dated follow-ups ("recheck ~08.10") the sessions alone don't surface.
        // Newest projects first; ones untouched this week get a shorter excerpt; a block that doesn't fit
        // leaves room for smaller ones.
        var memory = ""
        var seen = Set<URL>()
        for s in sessions where seen.insert(s.folder).inserted {
            let index = s.folder.appendingPathComponent("memory/MEMORY.md")
            guard let text = try? String(contentsOf: index, encoding: .utf8), !text.isEmpty else { continue }
            let block = "## \(Paths.tilde(s.cwd))\n\(text.clipped(s.end >= detailCutoff ? 5000 : 1500))\n\n"
            guard memory.count + block.count <= Self.memoryBudget else { continue }
            memory += block
        }
        if !memory.isEmpty { out += "# Project memory (indexes)\n\(memory)" }

        // A running length: String.count is O(n), and there are hundreds of blocks.
        var length = out.count
        var truncated = false
        func append(_ block: String) -> Bool {
            let n = block.count
            guard length + n <= Self.budget else { return false }
            out += block
            length += n
            return true
        }
        _ = append("# Sessions of the last \(DigestFormat.count(Self.detailDays, "day")), newest first\n")
        for s in recent where !truncated {
            truncated = !append(Self.block(s, detailed: true, compact: compact, now: now))
        }
        if !older.isEmpty, !truncated {
            let heading = "\n# Sessions older than \(DigestFormat.count(Self.detailDays, "day")), in brief: "
            _ = append(heading + (compact == nil
                ? "title, first prompt, result\n"
                : "sessions with a summary in one line (date · folder · \"title\" · prompts · state · importance; "
                    + "\"Open\" at importance 2+, for a done one only its first item: what may be left); the others "
                    + "as the first prompt and the result\n"))
            for s in older where !truncated {
                truncated = !append(Self.block(s, detailed: false, compact: compact, now: now))
            }
        }
        if truncated { out += "\n…older sessions didn't fit in the limit…\n" }
        return out
    }

    /// Hours from `now` (or from the start of the owner's day, ~07:00) to its end, ~23:00 local; at least 1.
    static func hoursLeft(_ now: Date, calendar: Calendar = .current) -> Int {
        guard let start = calendar.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: now),
              let end = calendar.date(bySettingHour: dayEndHour, minute: 0, second: 0, of: now) else { return 1 }
        return max(1, Int((end.timeIntervalSince(max(now, start)) / 3600).rounded()))
    }

    /// A session as the digest shows it: the summarizer's note when there is one (one line once it is older
    /// than the detail tier), else the raw block.
    static func block(_ s: SessionDigest, detailed: Bool, compact: CompactReport?, now: Date) -> String {
        if let summary = compact?.summaries[s.id] {
            return detailed ? noteBlock(s, summary, now: now) : noteLine(s, summary)
        }
        return detailed ? detailBlock(s, now: now) : briefBlock(s, now: now)
    }

    /// `## session=… · cwd · "title" · dates · N prompts · state · importance 3/4 [· running now | CUT OFF]`,
    /// then the note and what's left open.
    static func noteBlock(_ s: SessionDigest, _ note: SessionSummary, now: Date) -> String {
        var block = "\n## session=\(shortID(s.id)) · \(Paths.tilde(s.cwd))"
        if let title = s.title { block += " · \"\(title)\"" }
        block += " · \(DigestFormat.short(s.start)) → \(DigestFormat.short(s.end))"
        block += " · \(DigestFormat.count(s.prompts.count, "prompt"))"
        block += " · \(label(note.state)) · importance \(note.importance)/4"
        block += endMark(s, now: now, long: false)
        block += "\nSummary: \(note.summary)\n"
        if !note.open.isEmpty { block += "Open: \(openList(note.open))\n" }
        if let recap = s.recap { block += "Claude Code recap: \(recap)\n" }
        if let words = lastWords(s) { block += "Owner's last words: \(words)\n" }
        return block
    }

    /// How the owner ended a session, in their own words ("drop it", "sent", "go ahead"), which a note can
    /// blur. A short last prompt ("yes", "ok") gets the one before it for context.
    static func lastWords(_ s: SessionDigest) -> String? {
        guard let last = s.prompts.last else { return nil }
        var words = "\"\(last.clipped(200).oneLine)\""
        if last.count < 60, s.prompts.count > 1 {
            words = "\"\(s.prompts[s.prompts.count - 2].clipped(140).oneLine)\" → " + words
        }
        return words
    }

    /// An older noted session in one line: what it was and how it ended. What it left open follows while it
    /// may matter (importance 2+): all of it for an unfinished session, the first item for a done one — the
    /// summarizer puts what is still owed first, and a finished goal often leaves a reply or a bill behind.
    static func noteLine(_ s: SessionDigest, _ note: SessionSummary) -> String {
        var line = "- \(DigestFormat.day(s.end)) · \(Paths.shortProject(s.cwd)) · \"\(title(s))\""
        line += " · \(DigestFormat.count(s.prompts.count, "prompt")) · \(label(note.state)) · \(note.importance)/4"
        if s.awaitingReply { line += " · CUT OFF" }
        line += " · session=\(shortID(s.id))\n"
        if let first = note.open.first {
            if note.state != .done && note.importance >= 2 {
                line += "  Open: \(openList(note.open))\n"
            } else if note.importance >= 2 {
                line += "  Open: \(openList([first]))\n"
            }
        }
        return line
    }

    static func label(_ state: SessionSummary.State) -> String {
        switch state {
        case .done: "done"
        case .inProgress: "in progress"
        case .blocked: "blocked"
        case .abandoned: "abandoned"
        case .noWork: "no work"
        }
    }

    /// A recent session: the first prompt states the goal, the tail shows where it ended up.
    static func detailBlock(_ s: SessionDigest, now: Date) -> String {
        var block = "\n## session=\(shortID(s.id)) · \(Paths.tilde(s.cwd))"
        if let title = s.title { block += " · \"\(title)\"" }
        block += " · \(DigestFormat.short(s.start)) → \(DigestFormat.short(s.end))"
        block += " · \(DigestFormat.count(s.prompts.count, "prompt"))"
        block += endMark(s, now: now, long: true)
        block += "\n"
        var picked = s.prompts.count > 12 ? [s.prompts[0]] + s.prompts.suffix(11) : s.prompts
        if s.prompts.count > 12 { picked.insert(skipped(s.prompts.count - 12), at: 1) }
        for p in picked { block += "> \(p.clipped(350).oneLine)\n" }
        if let recap = s.recap { block += "Claude Code recap: \(recap)\n" }
        if !s.lastReply.isEmpty {
            // The recap tells where it ended: a shorter tail keeps the specifics and the digest's budget.
            block += "Assistant's last reply: \(s.lastReply.headTail(s.recap == nil ? 1200 : 800).oneLine)\n"
        }
        return block
    }

    /// An older session as context: what it was about and how it ended — Claude Code's recap when it has one.
    static func briefBlock(_ s: SessionDigest, now: Date) -> String {
        var block = "\n## session=\(shortID(s.id)) · \(Paths.tilde(s.cwd))"
        if let title = s.title { block += " · \"\(title)\"" }
        block += " · \(DigestFormat.short(s.start)) → \(DigestFormat.short(s.end))"
        block += " · \(DigestFormat.count(s.prompts.count, "prompt"))"
        block += endMark(s, now: now, long: false)
        // Half the month is one- or two-prompt errands: a line each is enough.
        let errand = s.prompts.count <= 2
        block += "\n> \(s.prompts[0].clipped(errand ? 120 : 160).oneLine)\n"
        if let recap = s.recap {
            block += "Result (Claude Code recap): \(recap)\n"
        } else if !s.lastReply.isEmpty {
            block += "Result: \(s.lastReply.headTail(errand ? 100 : 240).oneLine)\n"
        }
        return block
    }

    /// An agent is still on the owner's last prompt: its turn isn't over (`SessionDigest.turnOpen`) and the
    /// session moved within the last two hours (a long run writes little text and none at the end until it is
    /// done). A session that answered and stopped isn't "going", however recent: its work is finished.
    static func isLive(_ s: SessionDigest, now: Date) -> Bool {
        s.turnOpen && now.timeIntervalSince(s.lastRecord ?? s.end) < liveWindow
    }

    /// " · running now" while an agent works on the owner's last prompt, " · CUT OFF" once a session has
    /// stood still with the prompt unanswered; nothing for a session that answered.
    static func endMark(_ s: SessionDigest, now: Date, long: Bool) -> String {
        if isLive(s, now: now) { return " · running now" }
        guard s.awaitingReply else { return "" }
        return long ? cutOff : " · CUT OFF"
    }

    /// The end mark of a session whose last prompt got no reply, in full; the summarizer reads it too.
    static let cutOff = " · CUT OFF: the last prompt got no reply"

    /// The line that stands for the prompts a block leaves out.
    static func skipped(_ n: Int) -> String { "…(\(DigestFormat.count(n, "prompt")) skipped)…" }

    /// The board as the model must see it: what exists, what the owner fixed by hand (*), how long each
    /// task has been around and on Today, and what was closed recently so it isn't suggested again.
    /// `sessions` date the last activity of a task's source session.
    static func boardSection(_ board: Board, now: Date, sessions: [SessionDigest] = []) -> String {
        var out = "# Current board — update it\n"
        guard !board.areas.isEmpty || !board.tasks.isEmpty else {
            return out + "The board is empty: this is the first run, create the areas and tasks from scratch.\n\n"
        }
        if let plannedAt = board.plannedAt {
            out += "Last run: \(DigestFormat.full(plannedAt)), \(DigestFormat.weekday(plannedAt)). "
                + "The focus, the areas' statuses and outcomes, the notes and \"why\" below are its text: "
                + "recheck them against fresh sessions and git.\n"
        }
        out += "Focus: \(board.focus.isEmpty ? "—" : board.focus)\n"
        out += "A star * marks a field the owner set by hand: don't change it. "
            + "area=inbox is the owner's task without an area: assign one.\n"

        out += "\n## Areas (status and outcome from the last run)\n"
        for a in board.areas {
            out += "- id=\(a.id) \"\(a.name)\" symbol=\(a.symbol) color=\(a.color.rawValue) weight=\(a.weight.rawValue)"
            if !a.status.isEmpty { out += " | \(a.status)" }
            if !a.outcome.isEmpty { out += " | by the end of the week: \(a.outcome)" }
            out += "\n"
        }

        // Grouped by area in board order, so the model reads each line of work as a whole.
        let areaOrder = Dictionary(board.areas.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { a, _ in a })
        func byArea(_ a: TaskItem, _ b: TaskItem) -> Bool {
            let (oa, ob) = (areaOrder[a.area] ?? -1, areaOrder[b.area] ?? -1)
            return oa != ob ? oa < ob : TaskItem.displayOrder(a, b)
        }
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let open = board.tasks.filter(\.status.isOpen).sorted(by: byArea)
        let today = Day(now)
        out += "\n## Open tasks\n"
        if open.isEmpty { out += "none\n" }
        for t in open {
            // A Today / not-today choice binds only the day it was made: an older one is the plan's to redo.
            func mark(_ f: Field) -> String {
                (f == .when ? t.holdsWhenPin(on: today) : t.pinned.contains(f)) ? "*" : ""
            }
            var line = "- id=\(t.id) [\(t.status.rawValue)\(mark(.status))] when=\(t.when.rawValue)\(mark(.when))"
            line += " priority=\(t.priority.rawValue)\(mark(.priority))"
            if let h = t.estimate { line += " \(h.hoursText)h\(mark(.estimate))" }
            line += " area=\(t.area)\(mark(.area))"
            if t.kind == .decision { line += " kind=decision" }
            if t.origin == .user { line += " from the owner" }
            line += " \"\(t.title)\""
            if !t.note.isEmpty { line += " — \(t.note)" }
            var facts: [String] = []
            if !t.why.isEmpty { facts.append("why: \(t.why)") }
            facts.append("created \(DigestFormat.day(t.createdAt))")
            if let days = board.daysOnToday(t, now: now), let since = t.todaySince ?? board.plannedDay(of: t) {
                var stretch = "on Today since \(DigestFormat.day(since)) (day \(days + 1))"
                if board.isCarriedOver(t, now: now), let planned = board.plannedDay(of: t) {
                    stretch += ", carried over from the plan of \(DigestFormat.day(planned))"
                }
                facts.append(stretch)
            }
            // The year rides along: the model writes the due back as yyyy-mm-dd on every run.
            if let due = t.due { facts.append("due\(mark(.due)) \(due)") }
            if let until = t.snoozedUntil, until > today {
                facts.append("snoozed by the owner until \(DigestFormat.day(until))")
            }
            if let id = t.sessionId {
                var session = "session=\(Self.shortID(id))"
                if let s = byID[id] {
                    session += isLive(s, now: now)
                        ? " (running now)" : " (last active \(DigestFormat.short(s.lastRecord ?? s.end)))"
                }
                facts.append(session)
            }
            if let advice = t.advice {
                facts.append("advice \"\(advice.status.rawValue)\" awaits the owner's decision: \(advice.reason)")
            }
            out += line + " · " + facts.joined(separator: " · ") + "\n"
        }

        let cutoff = now.addingTimeInterval(-Merge.closedTTL)
        let closed = board.tasks.filter { !$0.status.isOpen && ($0.completedAt ?? $0.updatedAt) >= cutoff }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
        if !closed.isEmpty {
            out += "\n## Closed in the last \(Int(Merge.closedTTL / 86400)) days — don't suggest again\n"
            for t in closed {
                let by = t.pinned.contains(.status) ? " by the owner" : ""
                let closedOn = DigestFormat.day(t.completedAt ?? t.updatedAt)
                var line = "- id=\(t.id) [\(t.status.rawValue)\(by) \(closedOn)] \"\(t.title)\""
                if let reason = t.closedReason { line += " — \(reason)" }
                out += line + "\n"
            }
        }
        return out + "\n"
    }

    /// Git of the week's folders, a line per repo (`GitState`).
    static func repoSection(_ repos: [RepoState]) -> String {
        guard !repos.isEmpty else { return "" }
        var out = "# Repository state (git of the folders worked in over the last "
            + "\(DigestFormat.count(detailDays, "day")): branch · uncommitted · unpushed · last commit; "
            + "under a repo, its unpushed commits, newest first)\n"
        for r in repos { out += GitState.line(r) + "\n" }
        return out + "\n"
    }

    /// Session ids are UUIDs; their first 8 hex digits tell ~600 sessions apart and cost a third of the tokens.
    static func shortID(_ id: String) -> String { String(id.prefix(shortIDLength)) }

    static func title(_ s: SessionDigest) -> String { s.title ?? s.prompts[0].oneLine.clipped(60) }

    /// A note's open items, one line: "Reply to the client; check the totals".
    static func openList(_ items: [String]) -> String {
        items.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.joined(separator: "; ")
    }
}
