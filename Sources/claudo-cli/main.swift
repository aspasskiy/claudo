import ClaudoCore
import Foundation

/// The app's Language setting (its UserDefaults `language`): `plan` and `compact` write into the same board and
/// session cache as the app, so by default they write in the same language.
let appLanguage = PlanLanguage.forSetting(UserDefaults(suiteName: "site.spasskiy.claudo")?.string(forKey: "language"))

let usage = """
usage: claudo-cli [--data-dir <dir>] <command>

  digest [--days N] [--compact off|haiku|sonnet]
      print what a plan run would send (30 days by default); --compact previews the compacted
      digest from the session cache and calls nothing
  prompt [--language L]
      print the planner's system prompt and answer schema
  plan [model] [--days N] [--compact off|haiku|sonnet] [--effort E] [--compact-effort E]
       [--language L]
      run claude, merge its answer into the board and save it (spends subscription quota;
      sonnet and effort xhigh by default, effort is low|medium|high|xhigh|max); last-run.json
      in the data dir says where the time went
  compact [--model haiku|sonnet] [--effort E] [--days N] [--limit N] [--language L]
          [--dry-run]
      summarize the uncached sessions into that model's session cache (spends subscription
      quota; haiku by default); --limit takes the newest N, --dry-run only counts them
  cache [--model haiku|sonnet] [--days N]
      what that model's session cache holds for the window
  raw <session-id…> [--days N]
      print the blocks the summarizer reads for these sessions
  board [file]
      print a board as the app lists it: Today, This week, Later, the week's closed tasks
      (done and dropped, with reasons), then the areas (the data dir's board by default)
  merge <board.json|-> <answer.json> [--out file]
      fold a saved answer (last-result.json or a PlanResult) into a board ("-" = the data
      dir's) and print it; writes nothing but --out

--language takes a code or a name (ru, pt-BR, Russian) for what the model writes: the board's
texts and the session notes. By default it is the app's Language setting, else the system's
language (\(appLanguage) here). The prompts and the digest are English either way.
"""

// MARK: Arguments

var positional: [String] = []
var options: [String: String] = [:]
/// Options that take no value.
let switches: Set<String> = ["dry-run"]
do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        if arg.hasPrefix("--") {
            let name = String(arg.dropFirst(2))
            if switches.contains(name) {
                options[name] = "1"
                continue
            }
            guard let value = it.next() else { fail("\(arg) needs a value") }
            options[name] = value
        } else {
            positional.append(arg)
        }
    }
}
if let dir = options["data-dir"] {
    BoardStore.directory = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
}
let command = positional.first ?? "help"
let rest = Array(positional.dropFirst())
/// The look-back window; `digest` also takes it as its first argument.
let days = (options["days"] ?? (command == "digest" ? rest.first : nil)).flatMap(Int.init) ?? Planner().days
/// What the model writes in, for `prompt`, `plan` and `compact`.
let language = options["language"].map(PlanLanguage.name) ?? appLanguage

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// --compact for `digest` and `plan`.
func compactMode() -> CompactMode? {
    guard let name = options["compact"] else { return nil }
    guard let mode = CompactMode(rawValue: name.lowercased()) else { fail("--compact takes off, haiku or sonnet") }
    return mode
}

/// --model for `compact` and `cache`: whose notes, Haiku's by default.
func notesMode() -> CompactMode {
    guard let mode = CompactMode(rawValue: (options["model"] ?? "haiku").lowercased()), mode != .off else {
        fail("--model takes haiku or sonnet")
    }
    return mode
}

func loadBoard(_ path: String) -> Board {
    guard let board = BoardStore.load(from: URL(fileURLWithPath: path)) else { fail("can't read a board from \(path)") }
    return board
}

// MARK: Commands

switch command {
case "digest":
    let start = Date()
    let sessions = Sessions.scan(days: days)
    // --compact previews what a compacted run would send, from the cache only: nothing is called.
    var report: CompactReport?
    if let mode = compactMode(), let model = mode.model {
        report = Compactor.cachedReport(sessions, cache: SessionCache.load(model: model), mode: mode)
    }
    let text = Planner(days: days).digest(sessions: sessions, board: BoardStore.load(), compact: report,
                                          repos: GitState.scan(sessions: sessions))
    print(text)
    note(String(format: "%d sessions, %d chars, scanned in %.1fs", sessions.count, text.count,
                Date().timeIntervalSince(start)))

case "prompt":
    print(Planner.systemPrompt(language: language))
    print("\n--- schema ---\n" + Planner.answerSchema)

case "plan":
    var planner = Planner(days: days)
    if let model = rest.first { planner.model = model }
    if let mode = compactMode() { planner.compact = mode }
    if let effort = options["effort"] { planner.effort = effort }
    if let effort = options["compact-effort"] { planner.compactEffort = effort }
    planner.language = language
    let start = Date()
    do {
        let result = try planner.run(board: BoardStore.load(), progress: { [mode = planner.compact] in
            note(describe($0, mode))
        })
        // Merge onto a fresh load: the board may have changed while claude was thinking.
        let (board, summary) = Merge.merge(result, into: BoardStore.load())
        try BoardStore.save(board)
        print(render(board))
        note(String(format: "\n+%d new · %d updated · %d closed · %d advice — %.0fs, $%.3f list price",
                    summary.added, summary.updated, summary.closed, summary.advised,
                    Date().timeIntervalSince(start), board.costUSD ?? 0))
    } catch {
        fail(error.localizedDescription)
    }

case "compact":
    let limit = options["limit"].flatMap(Int.init)
    let mode = notesMode()
    let sessions = Sessions.scan(days: days)
    var cache = SessionCache.load(model: mode.model ?? "haiku")
    let estimate = CompactEstimate.make(sessions, cache: cache, mode: mode, limit: limit)
    print("\(days) days: \(estimate.sessions) sessions" + (limit.map { " · --limit \($0)" } ?? ""))
    print("\(mode.name): \(estimate.toSummarize) sessions in \(estimate.batches) calls of ≤ "
          + "\(SessionSummarizer.batchChars / 1000)k chars (subscription), notes in \(language)")
    if options["dry-run"] != nil {
        print("--dry-run: nothing was called")
        exit(0)
    }
    let start = Date()
    do {
        let compactor = Compactor.live(mode: mode, limit: limit, effort: options["effort"] ?? Planner().compactEffort,
                                       language: language)
        let report: CompactReport
        do {
            defer { try? cache.save() }
            report = try compactor.run(sessions, cache: &cache, progress: { stage in
                switch stage {
                case .summarizing(let done, let total):
                    // A line per ~10% keeps a 600-session pass readable.
                    if done == 0 || done == total || done % max(1, total / 10) == 0 { note(describe(stage, mode)) }
                default: note(describe(stage, mode))
                }
            })
        }
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in report.summarized {
            guard let s = byID[id], let x = report.summaries[id] else { continue }
            print("\n## \(s.id) · \(Paths.tilde(s.cwd)) · \"\(s.title ?? "—")\" · \(s.prompts.count) prompts")
            print("  \(mode.name) [\(x.state.rawValue), \(x.importance)/4]: \(x.summary)")
            for item in x.open { print("    · \(item)") }
        }
        note(String(format: "\n%@: %d summarized in %d calls, %d failed, %.0fs, ≈$%.3f list price", mode.name,
                    report.summarized.count, report.batches, report.failures,
                    Date().timeIntervalSince(start), report.costUSD))
    } catch {
        fail(error.localizedDescription)
    }

case "cache":
    let mode = notesMode()
    let sessions = Sessions.scan(days: days)
    let cache = SessionCache.load(model: mode.model ?? "haiku")
    let summaries = sessions.filter { cache.summary(for: $0) != nil }
    let stale = sessions.filter { s in cache.entries[s.id] != nil && cache.summary(for: s) == nil }
    print("""
    \(mode.name) cache: \(cache.entries.count) entries
    \(days) days: \(sessions.count) sessions · \(mode.name) summaries \(summaries.count) · \
    changed since cached: \(stale.count)
    """)

case "raw":
    guard !rest.isEmpty else { fail("raw needs session ids") }
    let byID = Dictionary(Sessions.scan(days: days).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for id in rest {
        guard let s = byID[id] else {
            note("no session \(id) in the last \(days) days")
            continue
        }
        print(s.rawBlock)
    }

case "board":
    print(render(rest.first.map(loadBoard) ?? BoardStore.load()))

case "merge":
    guard rest.count == 2 else { fail("merge needs <board.json|-> <answer.json>") }
    let board = rest[0] == "-" ? BoardStore.load() : loadBoard(rest[0])
    guard let data = FileManager.default.contents(atPath: rest[1]) else { fail("can't read \(rest[1])") }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let result: PlanResult
    if let decoded = try? decoder.decode(PlanResult.self, from: data) {
        result = decoded
    } else {
        do {
            // A raw answer (last-result.json): no digest at hand, so session ids are taken as they are.
            result = try Planner.decode(answer: data, sessions: nil, model: board.model ?? "?", costUSD: nil,
                                        now: Date())
        } catch {
            fail(error.localizedDescription)
        }
    }
    let (merged, summary) = Merge.merge(result, into: board)
    print(render(merged))
    note("\n+\(summary.added) new · \(summary.updated) updated · \(summary.closed) closed · \(summary.advised) advice")
    if let out = options["out"] {
        do { try BoardStore.save(merged, to: URL(fileURLWithPath: out)) } catch { fail(error.localizedDescription) }
        note("wrote \(out)")
    }

default:
    print(usage)
    exit(command == "help" ? 0 : 2)
}

// MARK: Rendering

func describe(_ stage: PlanStage, _ mode: CompactMode) -> String {
    switch stage {
    case .scanning: "scanning sessions…"
    case .summarizing(let done, let total): "\(mode.name) \(done)/\(total)"
    case .planning(let sessions): "planning from \(sessions) sessions…"
    }
}

/// The board as the app's schedule lists it — Today, This week, Later — then the week's closed tasks, dropped
/// ones too (a run's drops and their reasons show here), then the areas.
func render(_ board: Board, now: Date = Date()) -> String {
    let stamp = DateFormatter()
    stamp.dateFormat = "dd.MM HH:mm"
    var out = ""
    if !board.focus.isEmpty { out += "Focus: \(board.focus)\n" }
    if let at = board.plannedAt {
        var meta = "Planned \(stamp.string(from: at)) · \(board.model ?? "?") · \(board.sessionCount) sessions"
        if let cost = board.costUSD { meta += String(format: " · $%.2f", cost) }
        if board.planIsStale(now: now) {
            meta += " · stale: Today is an older day's plan"
        } else if let kept = board.keptOn, let planDay = board.planDay, planDay < kept {
            meta += " · kept for \(dayMonth(kept)) (the owner kept the \(dayMonth(planDay)) plan)"
        }
        out += meta + "\n"
    }
    if board.areas.isEmpty && board.tasks.isEmpty { return out + "\n(empty board)\n" }

    let today = board.today(now: now).filter(\.status.isOpen)
    out += "\nTODAY · \(today.count) open · ≈\(board.hoursLeftToday(now: now).hoursText)h\n"
    for t in today { out += line(t, board, now: now) }
    for (title, when) in [("THIS WEEK", When.week), ("LATER", .later)] {
        let tasks = board.upcoming(when, now: now)
        out += "\n\(title) · \(tasks.count)\n"
        for t in tasks { out += line(t, board, now: now) }
    }
    let closed = board.closedThisWeek(now: now)
    let dropped = closed.filter { $0.status == .dropped }.count
    out += "\nCLOSED THIS WEEK · \(closed.count - dropped) done · \(dropped) dropped\n"
    for t in closed { out += line(t, board, now: now) }

    out += "\nAREAS\n"
    var areas = board.orderedAreas
    if board.tasks(in: Area.inboxID).contains(where: \.status.isOpen) { areas.insert(.inbox, at: 0) }
    for area in areas {
        let open = board.tasks(in: area.id).filter(\.status.isOpen).count
        var header = " ■ \(area.name)  [\(area.weight.rawValue)]"
        if let share = area.attention { header += " \(share)%" }
        out += header + "  \(area.symbol) · \(area.color.rawValue) · \(open) open  #\(area.id)\n"
        if !area.status.isEmpty { out += "   \(area.status)\n" }
        if !area.outcome.isEmpty { out += "   → \(area.outcome)\n" }
    }
    return out
}

/// A task row, then its why:
/// `◆ high   0.1h Merge the fix into main?  [Atlas]  #id  ↻ 23.10 · day 3 on Today · due 26.10`.
/// A due task the owner put off shows `snoozed till 25.10` (it waits in This week or Later meanwhile).
func line(_ t: TaskItem, _ board: Board, now: Date) -> String {
    let status = switch t.status {
    case .todo: "○"
    case .doing: "◐"
    case .waiting: "⏸"
    case .done: "✓"
    case .dropped: "✕"
    }
    let glyph = t.kind == .decision && t.status.isOpen ? "◆" : status
    func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    let area = board.area(t.area)?.name ?? Area.inbox.name
    var s = "  \(glyph) \(pad(t.priority.rawValue, 6)) "
    s += pad(t.estimate.map { $0.hoursText + "h" } ?? "", 4) + " \(t.title)  [\(area)]  #\(t.id)"
    var marks: [String] = []
    if board.isCarriedOver(t, now: now), let day = board.plannedDay(of: t) { marks.append("↻ \(dayMonth(day))") }
    if t.status.isOpen, let days = board.daysOnToday(t, now: now), days > 0 { marks.append("day \(days + 1) on Today") }
    if let due = t.due { marks.append("due \(dayMonth(due))" + (t.pinned.contains(.due) ? "*" : "")) }
    if let until = t.snoozedUntil, until > Day(now), t.status.isOpen { marks.append("snoozed till \(dayMonth(until))") }
    if let at = t.completedAt, !t.status.isOpen { marks.append("closed \(dayMonth(Day(at)))") }
    if t.origin == .user { marks.append("owner") }
    if t.isNew { marks.append("✦new") }
    if t.sessionId != nil { marks.append("⌘") }
    let pins = t.pinned.subtracting([.due]).map(\.rawValue).sorted()
    if !pins.isEmpty { marks.append("*" + pins.joined(separator: ",")) }
    if !marks.isEmpty { s += "  " + marks.joined(separator: " · ") }
    if let advice = t.advice { s += "  → \(advice.status.rawValue)? \(advice.reason)" }
    if let reason = t.closedReason { s += "  — \(reason)" }
    s += "\n"
    if !t.why.isEmpty, t.status.isOpen { s += "      ↳ \(t.why)\n" }
    return s
}

func dayMonth(_ d: Day) -> String { String(format: "%02d.%02d", d.day, d.month) }
