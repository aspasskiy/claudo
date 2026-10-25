import AppKit
import ClaudoCore
import Foundation

@MainActor
final class Store: ObservableObject {
    @Published private(set) var board: Board
    @Published private(set) var runStarted: Date?
    @Published private(set) var problem: Problem?

    /// What went wrong, kept as what happened and worded when shown: a switch of language rewords it.
    enum Problem: Equatable {
        /// A plan run failed: the planner's own text, which the status bar puts in plain words (`Fmt.failure`).
        case planFailed(String)
        case planningOff
        /// The system's reason, in the system's language.
        case sessionWontOpen(String)
        case saveFailed(String)
    }

    /// The problem in words: a failed run as the planner said it, the rest in the interface's language.
    var error: String? {
        switch problem {
        case .planFailed(let raw): raw
        case .planningOff: L("Planning is off for a fixture board", "Для тестовой доски планирование выключено")
        case .sessionWontOpen(let why): L("Couldn't open the session: \(why)", "Не удалось открыть сессию: \(why)")
        case .saveFailed(let why): L("Couldn't save the board: \(why)", "Не удалось сохранить доску: \(why)")
        case nil: nil
        }
    }

    /// The error is a plan run that failed, so the status bar offers Retry (not a save or a session that
    /// wouldn't open).
    var errorIsPlanFailure: Bool {
        guard case .planFailed = problem else { return false }
        return true
    }

    /// When an open task is for, the one thing that places it in the list, as in any task manager: Today
    /// (Claude's pick for the day, and whatever falls due), This week, Later. Status and kind are the row's
    /// marks and the filter's business, never a place. The header's chips are the same three.
    enum Horizon: CaseIterable {
        case today, week, later

        init(_ when: When) {
            switch when {
            case .today: self = .today
            case .week: self = .week
            case .later: self = .later
            }
        }
    }
    /// The horizons the filter narrows the list to; empty lists them all.
    var horizons: Set<Horizon> { Set(filter.when.map(Horizon.init)) }
    /// The header's three views, as in any task manager's "group by": the schedule (Today, This week, Later),
    /// by project (area) or by priority. The same rows in every view: the filter narrows them all alike. Kept
    /// between launches.
    enum Grouping: String, CaseIterable { case date, project, priority }
    @Published var grouping: Grouping = .date {
        didSet { if persistent { UserDefaults.standard.set(grouping.rawValue, forKey: "grouping") } }
    }
    @Published var expanded: String?
    /// Task whose title is being renamed in place.
    @Published var editing: String?
    /// Where the quick-add field shows; nil when hidden.
    @Published var adding: AddTarget?
    /// The list's "Done this week" fold at the end.
    @Published var showDone = false
    /// The Later group, folded under its header unless its chip is on.
    @Published var showLater = false
    /// The focus sentence on Today, unfolded past one line.
    @Published var showFocus = false
    /// Which horizons, areas, kinds, statuses and priorities the popover lists, in every view. Kept between launches.
    @Published var filter: BoardFilter {
        didSet { if persistent, let data = try? JSONEncoder().encode(filter) { UserDefaults.standard.set(data, forKey: "filter") } }
    }
    /// Ticks every second while the popover is open or a plan runs (relative times, run timer), and moves on
    /// at midnight and after a wake even when nobody looks, so the tray never shows yesterday.
    @Published private(set) var now = Date()
    /// Claude Code sessions written to since the last plan (file dates only), for "11 sessions since".
    @Published private(set) var sessionsSincePlan: Int?
    /// Debug renders: the row drawn as if the pointer were over it.
    @Published var debugHover: String?
    var popoverVisible = false

    struct AddTarget: Equatable {
        /// nil = the inbox. Always on top of the group `when` names.
        var area: String?
        var when: When
    }

    /// Opus plans; Sonnet boils the sessions down first (DESIGN.md › Compaction: on a real month Sonnet's notes
    /// tied Haiku's). Not a setting; the CLI takes others for experiments.
    let model = "opus"
    let compact: CompactMode = .sonnet
    /// Off by default: every run spends ~90k (7 days) to ~160k (30 days) tokens of the Claude subscription.
    @Published var autoMorning: Bool {
        didSet { if persistent { UserDefaults.standard.set(autoMorning, forKey: "autoMorning") } }
    }
    /// Days of sessions a plan run reads: the last week in full, older ones as short notes.
    @Published var lookback: Int {
        didSet { if persistent { UserDefaults.standard.set(lookback, forKey: "lookback") } }
    }
    static let lookbacks = [7, 14, 30]
    /// The interface's language, and the one Claude writes the board in. Kept between launches.
    @Published var language: AppLanguage {
        didSet {
            Loc.russian = language.isRussian
            if persistent { UserDefaults.standard.set(language.rawValue, forKey: "language") }
        }
    }
    /// What the running plan is busy with, for the banner.
    @Published private(set) var stage: PlanStage?
    static let morningHour = 9

    /// False for `--board <fixture>`: nothing is read from or written to the real data dir.
    let persistent: Bool
    var running: Bool { runStarted != nil }
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private var shownAt: Date?

    init(fixture: URL? = nil) {
        if let fixture {
            persistent = false
            board = BoardStore.load(from: fixture) ?? .empty
            autoMorning = false
            lookback = 30
            filter = BoardFilter()
            // Renders and tests read the same words on any Mac; a render's `--language ru` or the menu switches.
            language = .english
        } else {
            persistent = true
            board = BoardStore.load()
            boardStamp = Self.boardFileDate()
            let defaults = UserDefaults.standard
            autoMorning = defaults.bool(forKey: "autoMorning")
            let days = defaults.integer(forKey: "lookback")
            lookback = Self.lookbacks.contains(days) ? days : 30
            filter = defaults.data(forKey: "filter").flatMap { try? JSONDecoder().decode(BoardFilter.self, from: $0) }
                ?? BoardFilter()
            grouping = defaults.string(forKey: "grouping").flatMap(Grouping.init(rawValue:)) ?? .date
            language = defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
        Loc.russian = language.isRussian
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A Mac that slept through midnight, or a day that turned with the popover closed.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUp() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUp() }
        })
        tick()
    }

    /// The clock, the board as `claudo-cli` may have left it, and the sessions since the plan, all as of now:
    /// after a wake and when the day changes.
    private func catchUp() {
        now = Date()
        reloadIfChangedOnDisk()
        countSessionsSincePlan()
    }

    private func tick() {
        let date = Date()
        if Day(date) != Day(now) {
            // A new day: Today, the stale look and the tray's count all change with it.
            catchUp()
        } else if running || (popoverVisible && date.timeIntervalSince(now) >= 15) {
            // Each tick re-renders the popover: every second only for the run timer.
            now = date
        }
        guard persistent, autoMorning, !running, Calendar.current.component(.hour, from: date) >= Self.morningHour,
              !(board.plannedAt.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false),
              lastAutoAttempt.map({ date.timeIntervalSince($0) > 3600 }) ?? true else { return }
        lastAutoAttempt = date
        refresh()
    }

    /// A failed morning run retries hourly, not every tick.
    private var lastAutoAttempt: Date?

    // MARK: Planning

    func refresh() {
        guard !running else { return }
        guard persistent else {
            problem = .planningOff
            return
        }
        reloadIfChangedOnDisk()
        runStarted = Date()
        now = Date()
        problem = nil
        stage = .scanning
        var planner = Planner(model: model, days: lookback)
        planner.compact = compact
        planner.language = language.planLanguage
        let snapshot = board
        let relay = Self.stageRelay(to: self)
        Task {
            let result = await Task.detached { Result { try planner.run(board: snapshot, progress: relay) } }.value
            runStarted = nil
            stage = nil
            switch result {
            case .success(let plan):
                // The run takes minutes; fold it into the board as it is now, edits made meanwhile included.
                let merged = Merge.merge(plan, into: board)
                board = merged.board
                dirty = true
                saveNow()
                showPlanSummary(merged.summary)
                countSessionsSincePlan()
            case .failure(let e):
                problem = .planFailed(e.localizedDescription)
            }
        }
    }

    func dismissError() { problem = nil }

    /// Hands the planner's stages, reported from its worker threads, to the main thread in order.
    private nonisolated static func stageRelay(to store: Store) -> @Sendable (PlanStage) -> Void {
        let target = WeakStore(store)
        return { stage in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { target.store?.stage = stage }
            }
        }
    }

    private final class WeakStore: @unchecked Sendable {
        weak var store: Store?
        init(_ store: Store) { self.store = store }
    }

    /// "✦ 2 new · 1 closed · 1 to review" for a few seconds after a run, worded when shown.
    struct PlanNotice: Equatable {
        let id = UUID()
        let summary: Merge.Summary

        var text: String {
            var parts: [String] = []
            if summary.added > 0 { parts.append(L("\(summary.added) new", "новых: \(summary.added)")) }
            if summary.closed > 0 { parts.append(L("\(summary.closed) closed", "закрыто: \(summary.closed)")) }
            if summary.advised > 0 {
                parts.append(L("\(summary.advised) to review", "на проверку: \(summary.advised)"))
            }
            // Reworded notes and estimates aren't news; "updated" stays out of the line.
            return parts.isEmpty ? L("Plan is up to date", "План актуален") : parts.joined(separator: " · ")
        }
    }
    @Published private(set) var planNotice: PlanNotice?

    func dismissPlanNotice() { planNotice = nil }

    func showPlanSummary(_ summary: Merge.Summary) {
        let notice = PlanNotice(summary: summary)
        planNotice = notice
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.planNotice == notice { self?.planNotice = nil }
        }
    }

    // MARK: External changes

    /// board.json's modification date as of our last load or save.
    private var boardStamp: Date?

    /// The file BoardStore reads and writes (its own URL isn't public).
    private static func boardFileDate() -> Date? {
        let url = BoardStore.directory.appendingPathComponent("board.json")
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// `claudo-cli plan` can rewrite board.json while the app runs: pick that up, unless we hold
    /// unsaved edits — then ours win, and the next save overwrites the file.
    func reloadIfChangedOnDisk() {
        guard persistent, !dirty, let date = Self.boardFileDate(), date > (boardStamp ?? .distantPast) else { return }
        board = BoardStore.load()
        boardStamp = date
    }

    /// Debug renders: a run that started `seconds` ago, at `stage`.
    func simulateRun(startedSecondsAgo seconds: TimeInterval, stage: PlanStage? = nil) {
        runStarted = Date().addingTimeInterval(-seconds)
        self.stage = stage
        now = Date()
    }

    /// Debug renders: a run that failed.
    func simulateError(_ text: String) {
        problem = .planFailed(text)
    }

    /// Debug renders: replace the board without saving.
    func replaceBoard(_ board: Board) {
        self.board = board
    }

    /// Debug renders: a fixture has no real sessions behind it.
    func simulateSessionsSincePlan(_ count: Int?) {
        sessionsSincePlan = count
    }

    // MARK: Freshness

    /// Counts sessions the owner wrote in after the last plan, off the main thread. Only transcripts
    /// written to since are read, and nothing is sent anywhere.
    func countSessionsSincePlan() {
        guard persistent, let planned = board.plannedAt else {
            if persistent { sessionsSincePlan = nil }
            return
        }
        Task {
            let count = await Task.detached(priority: .utility) { Sessions.promptedSince(planned) }.value
            if board.plannedAt == planned { sessionsSincePlan = count }
        }
    }

    // MARK: Popover lifecycle

    func popoverWillShow() {
        reloadIfChangedOnDisk()
        popoverVisible = true
        shownAt = Date()
        now = Date()
        countSessionsSincePlan()
    }

    /// NEW flags clear once the popover has actually been looked at.
    func popoverDidClose() {
        popoverVisible = false
        editing = nil
        adding = nil
        if let shownAt, Date().timeIntervalSince(shownAt) >= 1.5, board.unseenCount > 0 {
            mutate { $0.markSeen() }
        }
        shownAt = nil
    }

    // MARK: Task actions

    func toggleDone(_ t: TaskItem) {
        mutate { $0.setStatus(t.id, t.status.isOpen ? .done : .todo) }
    }

    func cycleStatus(_ t: TaskItem) {
        mutate { $0.setStatus(t.id, t.status.next) }
    }

    func setStatus(_ id: String, _ status: TaskStatus) { mutate { $0.setStatus(id, status) } }
    func setWhen(_ id: String, _ when: When) { mutate { $0.setWhen(id, when) } }
    func setDue(_ id: String, _ due: Day?) { mutate { $0.setDue(id, due) } }

    /// "Not today": off Today for the rest of the day; a row that is there because it falls due keeps its
    /// deadline and comes back tomorrow.
    func notToday(_ t: TaskItem) { mutate { $0.notToday(t.id) } }
    /// "Keep": the carried-over rows become today's again, nothing pinned.
    func keepForToday() { mutate { $0.keepForToday() } }
    func setPriority(_ id: String, _ priority: Priority) { mutate { $0.setPriority(id, priority) } }
    func setArea(_ id: String, _ area: String) { mutate { $0.setArea(id, area) } }
    func acceptAdvice(_ id: String) { mutate { $0.acceptAdvice(id) } }
    func dismissAdvice(_ id: String) { mutate { $0.dismissAdvice(id) } }

    /// The last removed task as it was, for the "Removed · Undo" toast.
    struct Removal: Equatable {
        let task: TaskItem
        let index: Int
        let at: Date
    }
    @Published private(set) var removal: Removal?

    func remove(_ id: String) {
        guard let index = board.tasks.firstIndex(where: { $0.id == id }) else { return }
        if expanded == id { expanded = nil }
        let removal = Removal(task: board.tasks[index], index: index, at: Date())
        mutate { $0.remove(id) }
        self.removal = removal
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.removal == removal { self?.removal = nil }
        }
    }

    /// Puts the task back exactly as it was: owner tasks were deleted, Claude's only dropped.
    func undoRemove() {
        guard let removal else { return }
        self.removal = nil
        mutate { board in
            if let i = board.tasks.firstIndex(where: { $0.id == removal.task.id }) {
                board.tasks[i] = removal.task
            } else {
                board.tasks.insert(removal.task, at: min(removal.index, board.tasks.count))
            }
        }
    }

    func rename(_ id: String, _ title: String) {
        editing = nil
        guard let old = board.task(id)?.title, title != old else { return }
        mutate { $0.rename(id, title) }
    }

    func add(_ title: String, to target: AddTarget) {
        mutate { $0.add(title: title, area: target.area ?? Area.inboxID, when: target.when) }
    }

    /// Whether the list shows this horizon: every one while no chip is on.
    func shows(_ horizon: Horizon) -> Bool { horizons.isEmpty || horizons.contains(horizon) }

    /// A horizon in the filter: on or off, any number at once. Turning the last one off lists everything again.
    func toggleHorizon(_ horizon: Horizon) {
        var when = filter.when
        if when.contains(horizon.when) { when.remove(horizon.when) } else { when.insert(horizon.when) }
        // All three on is no filter at all.
        filter.when = when.count == Horizon.allCases.count ? [] : when
        expanded = nil
        adding = nil
    }

    func showAllHorizons() {
        filter.when = []
        expanded = nil
        adding = nil
    }

    func setGrouping(_ grouping: Grouping) {
        guard grouping != self.grouping else { return }
        self.grouping = grouping
        expanded = nil
        adding = nil
    }

    /// Quick add (⌘N / header +): on top of the first group listed (Today, else This week, else Later), in
    /// the one area the filter names, else the inbox.
    func startAdding() {
        expanded = nil
        editing = nil
        let when: When = shows(.today) ? .today : shows(.week) ? .week : .later
        if when == .later { showLater = true }
        adding = AddTarget(area: filter.areas.count == 1 ? filter.areas.first : nil, when: when)
    }

    private var lastTap: (id: String, at: Date)?

    /// Click expands; a second click within the double-click interval renames instead of collapsing.
    func tapRow(_ id: String) {
        // Clicks inside the rename field belong to the field.
        guard editing != id else { return }
        let date = Date()
        if let last = lastTap, last.id == id, date.timeIntervalSince(last.at) < NSEvent.doubleClickInterval {
            lastTap = nil
            expanded = id
            editing = id
            return
        }
        lastTap = (id, date)
        if editing != id { editing = nil }
        expanded = expanded == id ? nil : id
    }

    /// Opens the source session in Terminal via a throwaway .command file.
    func resume(_ t: TaskItem) {
        guard let id = t.sessionId, let cwd = t.cwd else { return }
        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // The real binary, not whatever `claude` a login shell finds first (a terminal app may put a shim there).
        let claude = ClaudeCLI.path.map { "'\($0)'" } ?? "claude"
        let script = "#!/bin/zsh -l\ncd \(quoted) && exec \(claude) --resume \(id)\n"
        let dir = persistent ? Paths.support : FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("resume.command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            problem = .sessionWontOpen(error.localizedDescription)
        }
    }

    func copy(_ t: TaskItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.note.isEmpty ? t.title : "\(t.title)\n\(t.note)", forType: .string)
    }

    // MARK: Derived (each open task is in exactly one of Today, This week, Later)

    var todayTasks: [TaskItem] { board.today(now: now) }
    var openToday: [TaskItem] { todayTasks.filter { $0.status.isOpen } }
    var doneToday: [TaskItem] { todayTasks.filter { $0.status == .done } }
    var hoursLeftToday: Double { board.hoursLeftToday(now: now) }
    /// Open and not on Today, for this week or later: the most important first, then the plan's order.
    var weekTasks: [TaskItem] { board.upcoming(.week, now: now) }
    var laterTasks: [TaskItem] { board.upcoming(.later, now: now) }
    var focusAreas: [Area] { board.orderedAreas.filter { $0.weight == .focus } }
    /// Today's open rows as the popover lays them out (lead, decisions, blocks, check-ins).
    var todayPlan: TodayPlan { TodayPlan(open: openToday) }
    /// Today's rows left over from an earlier day's plan.
    var carriedOver: [TaskItem] { openToday.filter { board.isCarriedOver($0, now: now) } }
    /// False once the owner keeps the older plan for today (`Board.keptOn`).
    var planIsStale: Bool { board.planIsStale(now: now) }
    /// "11 sessions since · Re-plan" in the footer: a plan of today's that the day has moved past.
    var suggestsReplan: Bool { !running && !planIsStale && (sessionsSincePlan ?? 0) >= 5 }

    /// Done in the last 7 days, newest first: the list's "Done this week".
    var doneThisWeek: [TaskItem] { board.doneThisWeek(now: now) }

    // MARK: Filter (what the popover lists; the tray and its tooltip ignore it)

    /// The popover's list narrowed by the filter: the same three horizons, only the rows that pass.
    var listedToday: [TaskItem] { openToday.filter(passes) }
    var listedDoneToday: [TaskItem] { doneToday.filter(passes) }
    var listedTodayPlan: TodayPlan { TodayPlan(open: listedToday) }
    var listedWeek: [TaskItem] { weekTasks.filter(passes) }
    var listedLater: [TaskItem] { laterTasks.filter(passes) }
    var listedDoneThisWeek: [TaskItem] { doneThisWeek.filter(passes) }
    /// A horizon's open rows that pass the rest of the filter, picked or not: the filter panel's count.
    func listedCount(_ horizon: Horizon) -> Int {
        switch horizon {
        case .today: listedToday.count
        case .week: listedWeek.count
        case .later: listedLater.count
        }
    }
    func passes(_ t: TaskItem) -> Bool { filter.passes(t, areas: Set(board.areas.map(\.id))) }

    /// Every listed row with its horizon, in the list's own order: Today's as planned, then This week's and
    /// Later's, the most important first. What the project and priority views regroup.
    var listedRows: [ListGroups.Row] {
        (shows(.today) ? listedToday.map { .init(task: $0, horizon: .today) } : [])
            + (shows(.week) ? listedWeek.map { .init(task: $0, horizon: .week) } : [])
            + (shows(.later) ? listedLater.map { .init(task: $0, horizon: .later) } : [])
    }

    /// The list by project or by priority; empty while it is grouped by date.
    var listedGroups: [ListGroups.Group] {
        switch grouping {
        case .date: []
        case .project: ListGroups.byArea(listedRows, areas: board.orderedAreas)
        case .priority: ListGroups.byPriority(listedRows)
        }
    }

    /// The areas the filter can pick from, by weight, plus the inbox when it holds open work.
    var filterableAreas: [Area] {
        let open = board.openTasks
        let known = Set(board.areas.map(\.id))
        let inbox = open.contains { $0.area == Area.inboxID || !known.contains($0.area) }
        return board.orderedAreas.filter { a in a.weight != .parked || open.contains { $0.area == a.id } }
            + (inbox ? [.inbox] : [])
    }

    func toggleFilterArea(_ id: String) {
        if filter.areas.contains(id) { filter.areas.remove(id) } else { filter.areas.insert(id) }
        expanded = nil
    }

    /// `nil` shows both kinds.
    func setFilterKind(_ kind: TaskKind?) {
        filter.kind = kind
        expanded = nil
    }

    func toggleFilterStatus(_ status: TaskStatus) {
        if filter.statuses.contains(status) { filter.statuses.remove(status) } else { filter.statuses.insert(status) }
        expanded = nil
    }

    func setFilterImportant(_ on: Bool) {
        filter.important = on
        expanded = nil
    }

    func clearFilter() {
        filter = BoardFilter()
        expanded = nil
    }

    // MARK: Persistence

    private func mutate(_ change: (inout Board) -> Void) {
        change(&board)
        dirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        guard persistent else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard persistent, dirty else { return }
        do {
            try BoardStore.save(board)
            dirty = false
            boardStamp = Self.boardFileDate()
        } catch {
            problem = .saveFailed(error.localizedDescription)
        }
    }
}
