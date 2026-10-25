import Foundation

// MARK: - Enums

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case todo, doing, waiting, done, dropped

    public var isOpen: Bool { self == .todo || self == .doing || self == .waiting }
}

/// Ordered as its cases are declared: the first sorts first.
public protocol CaseOrdered: CaseIterable, Comparable {}

extension CaseOrdered {
    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

public enum Priority: String, Codable, CaseOrdered, Sendable {
    case urgent, high, medium, low
}

public enum When: String, Codable, CaseOrdered, Sendable {
    case today, week, later
}

/// How much of the week an area should get.
public enum Weight: String, Codable, CaseOrdered, Sendable {
    case focus, active, background, parked
}

public enum AreaColor: String, Codable, CaseIterable, Sendable {
    case coral, orange, yellow, green, mint, teal, blue, indigo, purple, pink, graphite
}

public enum Origin: String, Codable, Sendable {
    case claude, user
}

/// Task fields the owner can set by hand. A pinned field is never overwritten by a plan run
/// (a `when` pin only for the day it was set, unless it is Later: `TaskItem.holdsWhenPin`).
public enum Field: String, Codable, CaseIterable, Sendable {
    case title, note, area, status, priority, when, estimate, due
}

/// What a task asks of the owner: work to do, or a call only they can make.
public enum TaskKind: String, Codable, CaseIterable, Sendable {
    /// A block of work (1–3 h of the owner's own attention, or an agent run they steer).
    case task
    /// A yes/no or a choice: a go-ahead to merge or roll out, a session waiting for the owner's answer. Minutes.
    case decision
}

// MARK: - Day

/// A local calendar day, "2026-10-26" in JSON: due dates and the day a task was put on Today.
/// A date becomes a day in the local zone (a plan made at 23:50 still belongs to that day), always on the
/// Gregorian calendar, whatever the system one; day arithmetic ignores the zone, so DST can't skip a day.
public struct Day: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = Self.gregorian(in: calendar.timeZone).dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    private static func gregorian(in zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    /// For arithmetic only: UTC noon has no DST gaps.
    private static let utc = gregorian(in: TimeZone(identifier: "UTC")!)
    private var utcNoon: Date { Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))! }

    /// "yyyy-MM-dd" only; nil for anything else, an empty string included.
    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 3, parts[0].count == 4,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The first moment of the day in the calendar's zone (midnight, or 01:00 where DST skips it).
    public func date(calendar: Calendar = .current) -> Date {
        Self.gregorian(in: calendar.timeZone).date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func adding(days n: Int) -> Day {
        let date = Self.utc.date(byAdding: .day, value: n, to: utcNoon)!
        let c = Self.utc.dateComponents([.year, .month, .day], from: date)
        return Day(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Whole days from this day to `other` (negative when `other` is earlier).
    public func days(to other: Day) -> Int {
        Self.utc.dateComponents([.day], from: utcNoon, to: other.utcNoon).day ?? 0
    }

    /// Saturday or Sunday (by the calendar's weekend, not hard-coded).
    func isWeekend(calendar: Calendar = .current) -> Bool { calendar.isDateInWeekend(date(calendar: calendar)) }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let day = Day(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a yyyy-MM-dd day: \(s)")
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

// MARK: - Area

/// A line of work: a product, a company, a life project.
public struct Area: Codable, Identifiable, Hashable, Sendable {
    /// Implicit home of owner-added tasks until a plan run files them.
    public static let inboxID = "inbox"
    public static let inbox = Area(id: inboxID, name: "Inbox", symbol: "tray.fill", color: .graphite,
                                   weight: .active, status: "", outcome: "")

    /// SF Symbols a plan run may pick from (the schema enum). The UI still validates the name.
    public static let symbols = [
        "printer.fill", "doc.text.fill", "airplane", "house.fill", "building.2.fill", "building.columns.fill",
        "gamecontroller.fill", "sparkles", "cart.fill", "briefcase.fill", "chart.line.uptrend.xyaxis",
        "megaphone.fill", "dollarsign.circle.fill", "hammer.fill", "paintbrush.fill", "globe", "person.2.fill",
        "heart.fill", "leaf.fill", "book.fill", "camera.fill", "film", "wrench.and.screwdriver.fill",
        "server.rack", "iphone", "laptopcomputer", "scissors", "tshirt.fill", "map.fill", "suitcase.fill",
        "envelope.fill", "bubble.left.and.bubble.right.fill", "shippingbox.fill", "cube.fill", "folder.fill",
        "tray.fill", "terminal.fill", "graduationcap.fill", "music.note", "flag.fill",
    ]

    public var id: String
    public var name: String
    public var symbol: String
    public var color: AreaColor
    public var weight: Weight
    /// What is going on there right now (≤ 80 chars).
    public var status: String
    /// What "done this week" looks like (≤ 70 chars, may be empty).
    public var outcome: String
    /// Share of the owner's attention over the last 7 days, by topic, in percent (the planner's estimate).
    public var attention: Int?

    public init(id: String, name: String, symbol: String, color: AreaColor, weight: Weight,
                status: String, outcome: String, attention: Int? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
        self.weight = weight
        self.status = status
        self.outcome = outcome
        self.attention = attention
    }
}

// MARK: - Task

/// Claude's pending suggestion on a task whose status the owner set by hand.
public struct Advice: Codable, Hashable, Sendable {
    public var status: TaskStatus
    public var reason: String

    public init(status: TaskStatus, reason: String) {
        self.status = status
        self.reason = reason
    }
}

public struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var note: String
    /// Area id; `Area.inboxID` for unsorted owner tasks.
    public var area: String
    public var status: TaskStatus
    public var priority: Priority
    public var when: When
    /// Hours.
    public var estimate: Double?
    /// Claude's importance order from the last run (lower = more important); owner tasks go last.
    public var rank: Int
    /// Source session to resume, and the folder `claude --resume` must run in.
    public var sessionId: String?
    public var cwd: String?
    public var origin: Origin
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    /// Added by the last plan run and not yet seen in the popover.
    public var isNew: Bool
    public var pinned: Set<Field>
    public var advice: Advice?
    /// Why a plan run closed it ("merged into main").
    public var closedReason: String?
    /// The stake, in a few words: why it matters now (≤ 80 chars; old evidence carries its date).
    public var why: String
    /// A deadline or appointment; for a waiting task, the day to check back or nudge.
    public var due: Day?
    public var kind: TaskKind
    /// The day it was last put on Today (by a plan run or the owner); nil while `when` isn't today.
    /// Earlier than the current day = carried over from an older plan.
    public var plannedFor: Day?
    /// The first day of its current stretch on Today, for "on Today since 18.10".
    public var todaySince: Day?
    /// The day the owner last set `when` by hand: a Today / not-today choice binds that day's plans only.
    public var whenSetOn: Day?
    /// "Not today" on a task that is on Today only because it falls due: off Today until this day, while
    /// the deadline itself stays as it is.
    public var snoozedUntil: Day?

    public init(id: String, title: String, note: String = "", area: String = Area.inboxID,
                status: TaskStatus = .todo, priority: Priority = .medium, when: When = .week,
                estimate: Double? = nil, rank: Int = Int.max / 2, sessionId: String? = nil, cwd: String? = nil,
                origin: Origin, createdAt: Date, updatedAt: Date? = nil, completedAt: Date? = nil,
                isNew: Bool = false, pinned: Set<Field> = [], advice: Advice? = nil, closedReason: String? = nil,
                why: String = "", due: Day? = nil, kind: TaskKind = .task, plannedFor: Day? = nil,
                todaySince: Day? = nil, whenSetOn: Day? = nil, snoozedUntil: Day? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.area = area
        self.status = status
        self.priority = priority
        self.when = when
        self.estimate = estimate
        self.rank = rank
        self.sessionId = sessionId
        self.cwd = cwd
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
        self.isNew = isNew
        self.pinned = pinned
        self.advice = advice
        self.closedReason = closedReason
        self.why = why
        self.due = due
        self.kind = kind
        self.plannedFor = plannedFor
        self.todaySince = todaySince
        self.whenSetOn = whenSetOn
        self.snoozedUntil = snoozedUntil
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, note, area, status, priority, when, estimate, rank, sessionId, cwd, origin, createdAt,
             updatedAt, completedAt, isNew, pinned, advice, closedReason, why, due, kind, plannedFor, todaySince,
             whenSetOn, snoozedUntil
    }

    /// Lenient: on an older board every field but the id, title, status and creation date may be missing,
    /// and decodes with a default (no why, no dates, kind task).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        area = try c.decodeIfPresent(String.self, forKey: .area) ?? Area.inboxID
        status = try c.decode(TaskStatus.self, forKey: .status)
        priority = try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .medium
        when = try c.decodeIfPresent(When.self, forKey: .when) ?? .week
        estimate = try c.decodeIfPresent(Double.self, forKey: .estimate)
        rank = try c.decodeIfPresent(Int.self, forKey: .rank) ?? Int.max / 2
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .claude
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        isNew = try c.decodeIfPresent(Bool.self, forKey: .isNew) ?? false
        pinned = try c.decodeIfPresent(Set<Field>.self, forKey: .pinned) ?? []
        advice = try c.decodeIfPresent(Advice.self, forKey: .advice)
        closedReason = try c.decodeIfPresent(String.self, forKey: .closedReason)
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        due = try c.decodeIfPresent(Day.self, forKey: .due)
        kind = try c.decodeIfPresent(TaskKind.self, forKey: .kind) ?? .task
        plannedFor = try c.decodeIfPresent(Day.self, forKey: .plannedFor)
        todaySince = try c.decodeIfPresent(Day.self, forKey: .todaySince)
        whenSetOn = try c.decodeIfPresent(Day.self, forKey: .whenSetOn)
        snoozedUntil = try c.decodeIfPresent(Day.self, forKey: .snoozedUntil)
    }

    /// Whether the owner's `when` choice still binds a plan made on `day`. A Today / not-today choice holds
    /// for the day it was made; Later holds until they change it; a pin without a day (an older board's) holds.
    func holdsWhenPin(on day: Day) -> Bool {
        guard pinned.contains(.when) else { return false }
        guard when != .later, let setOn = whenSetOn else { return true }
        return setOn >= day
    }

    /// Display order inside a list: doing → todo → waiting → done → dropped, then priority, then rank.
    static func displayOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        func group(_ s: TaskStatus) -> Int {
            switch s {
            case .doing: 0
            case .todo: 1
            case .waiting: 2
            case .done: 3
            case .dropped: 4
            }
        }
        if group(a.status) != group(b.status) { return group(a.status) < group(b.status) }
        if !a.status.isOpen, let ca = a.completedAt, let cb = b.completedAt, ca != cb { return ca > cb }
        if a.priority != b.priority { return a.priority < b.priority }
        if a.rank != b.rank { return a.rank < b.rank }
        return a.createdAt < b.createdAt
    }
}

// MARK: - Board

public struct Board: Codable, Sendable {
    /// The board format this build writes. Older boards still load: missing fields decode with defaults.
    public static let currentVersion = 4

    public var version: Int
    /// Where the week's attention should go (≤ 140 chars).
    public var focus: String
    /// Ordered by importance as the last run returned them.
    public var areas: [Area]
    public var tasks: [TaskItem]
    public var plannedAt: Date?
    public var model: String?
    public var sessionCount: Int
    public var costUSD: Double?
    /// How many days of sessions the last run read (nil on older boards).
    public var days: Int?
    /// The day the owner kept an older plan's Today ("Keep"): the plan isn't stale for that day.
    public var keptOn: Day?

    public init(version: Int = Board.currentVersion, focus: String = "", areas: [Area] = [], tasks: [TaskItem] = [],
                plannedAt: Date? = nil, model: String? = nil, sessionCount: Int = 0, costUSD: Double? = nil,
                days: Int? = nil, keptOn: Day? = nil) {
        self.version = version
        self.focus = focus
        self.areas = areas
        self.tasks = tasks
        self.plannedAt = plannedAt
        self.model = model
        self.sessionCount = sessionCount
        self.costUSD = costUSD
        self.days = days
        self.keptOn = keptOn
    }

    public static let empty = Board()

    // MARK: Queries

    /// The area, the inbox for `Area.inboxID`, or nil for an unknown id.
    public func area(_ id: String) -> Area? {
        id == Area.inboxID ? Area.inbox : areas.first { $0.id == id }
    }

    /// Areas by weight, keeping the run's order inside a weight.
    public var orderedAreas: [Area] {
        areas.enumerated().sorted { ($0.element.weight, $0.offset) < ($1.element.weight, $1.offset) }.map(\.element)
    }

    public func task(_ id: String) -> TaskItem? { tasks.first { $0.id == id } }

    /// Tasks of an area (unknown area ids count as inbox), in display order.
    public func tasks(in areaID: String) -> [TaskItem] {
        let known = Set(areas.map(\.id))
        return tasks.filter { t in
            areaID == Area.inboxID ? (t.area == Area.inboxID || !known.contains(t.area)) : t.area == areaID
        }.sorted(by: TaskItem.displayOrder)
    }

    public var openTasks: [TaskItem] { tasks.filter { $0.status.isOpen } }

    public var unseenCount: Int { tasks.filter { $0.isNew && $0.status.isOpen }.count }

    // MARK: Today · This week · Later
    //
    // One list, placed by `when`: every open task is in exactly one part. Today holds what is planned for
    // today and whatever falls due; This week and Later hold the rest (`upcoming`).

    /// The local day the last plan run was made on.
    public var planDay: Day? { plannedAt.map { Day($0) } }

    /// True when the last plan was made on an earlier day than `now` and the owner hasn't kept it for
    /// today: Today shows an older plan.
    public func planIsStale(now: Date = Date()) -> Bool {
        let day = Day(now)
        guard let planDay, planDay < day else { return false }
        return keptOn.map { $0 < day } ?? true
    }

    /// The day a Today task was put there (without `plannedFor`, from an older board: the last plan's day).
    public func plannedDay(of t: TaskItem) -> Day? {
        t.plannedFor ?? planDay ?? Day(t.updatedAt)
    }

    /// Open and on Today: planned for today (fresh or carried over), or due today or earlier and not
    /// snoozed past today.
    public func isOnToday(_ t: TaskItem, now: Date = Date()) -> Bool {
        guard t.status.isOpen else { return false }
        if t.when == .today { return true }
        let day = Day(now)
        guard let due = t.due, due <= day else { return false }
        return t.snoozedUntil.map { $0 <= day } ?? true
    }

    /// On Today from an earlier day's plan and not re-confirmed since ("↻ Fri").
    public func isCarriedOver(_ t: TaskItem, now: Date = Date()) -> Bool {
        guard t.status.isOpen, t.when == .today, let day = plannedDay(of: t) else { return false }
        return day < Day(now)
    }

    /// Days it has sat on Today without leaving it (0 = put there today); nil when it isn't on Today.
    public func daysOnToday(_ t: TaskItem, now: Date = Date()) -> Int? {
        guard t.when == .today, let since = t.todaySince ?? plannedDay(of: t) else { return nil }
        return max(0, since.days(to: Day(now)))
    }

    /// Today: open tasks on Today (due or overdue first, then the plan's order), then the ones closed today
    /// that were on it.
    public func today(now: Date = Date()) -> [TaskItem] {
        let cal = Calendar.current
        let day = Day(now)
        let open = tasks.filter { isOnToday($0, now: now) }.sorted { a, b in
            Self.todayOrder(a, b, today: day)
        }
        let closed = tasks.filter { t in
            guard !t.status.isOpen, t.when == .today || (t.due.map { $0 <= day } ?? false) else { return false }
            return t.completedAt.map { cal.isDate($0, inSameDayAs: now) } ?? false
        }.sorted(by: TaskItem.displayOrder)
        return open + closed
    }

    /// Due or overdue first (earliest due first), then the plan's rank, then priority. A task today's plan
    /// placed keeps its rank even when it falls due: the plan already weighed the date.
    static func todayOrder(_ a: TaskItem, _ b: TaskItem, today: Day) -> Bool {
        func dueFirst(_ t: TaskItem) -> Day? {
            guard let due = t.due, due <= today, !(t.when == .today && t.plannedFor == today) else { return nil }
            return due
        }
        let da = dueFirst(a)
        let db = dueFirst(b)
        switch (da, db) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        if a.rank != b.rank { return a.rank < b.rank }
        if a.priority != b.priority { return a.priority < b.priority }
        return a.createdAt < b.createdAt
    }

    /// Open tasks for `when` that aren't on Today, as This week and Later list them: the most important
    /// first, then the plan's order, then the oldest. `.today` gives none: a task for today is on Today.
    public func upcoming(_ when: When, now: Date = Date()) -> [TaskItem] {
        tasks.filter { $0.status.isOpen && $0.when == when && !isOnToday($0, now: now) }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority < b.priority }
                if a.rank != b.rank { return a.rank < b.rank }
                return a.createdAt < b.createdAt
            }
    }

    /// Tasks done in the 7 days before `now`, the latest first.
    public func doneThisWeek(now: Date = Date()) -> [TaskItem] {
        closedThisWeek(now: now).filter { $0.status == .done }
    }

    /// Tasks done or dropped in the 7 days before `now`, the latest first: what `claudo-cli` shows of a run.
    public func closedThisWeek(now: Date = Date()) -> [TaskItem] {
        tasks.filter { t in
            !t.status.isOpen && (t.completedAt.map { now.timeIntervalSince($0) < 7 * 86400 } ?? false)
        }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// Owner hours planned for the open Today tasks.
    public func hoursLeftToday(now: Date = Date()) -> Double {
        today(now: now).filter(\.status.isOpen).reduce(0) { $0 + ($1.estimate ?? 0) }
    }

    // MARK: Owner actions (each pins the field it touches)

    private mutating func edit(_ id: String, _ field: Field?, now: Date, _ change: (inout TaskItem) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
        if let field { tasks[i].pinned.insert(field) }
        tasks[i].updatedAt = now
    }

    public mutating func setStatus(_ id: String, _ status: TaskStatus, now: Date = Date()) {
        edit(id, .status, now: now) { t in
            t.status = status
            t.completedAt = status.isOpen ? nil : now
            t.advice = nil
            if status.isOpen { t.closedReason = nil }
        }
    }

    public mutating func setPriority(_ id: String, _ priority: Priority, now: Date = Date()) {
        edit(id, .priority, now: now) { $0.priority = priority }
    }

    /// Moving onto Today dates it to today; moving off clears the Today days. The choice binds the
    /// plans of this day only, unless it is Later (`holdsWhenPin`).
    public mutating func setWhen(_ id: String, _ when: When, now: Date = Date()) {
        let day = Day(now)
        // A task already on Today keeps the first day of its stretch (an undated one: its plan's day).
        let since = task(id).flatMap { $0.when == .today ? ($0.todaySince ?? plannedDay(of: $0)) : nil }
        edit(id, .when, now: now) { t in
            if when == .today {
                if t.when != .today || t.plannedFor.map({ $0 < day }) ?? true { t.plannedFor = day }
                t.todaySince = since ?? day
            } else {
                t.plannedFor = nil
                t.todaySince = nil
            }
            t.when = when
            t.whenSetOn = day
        }
    }

    public mutating func setDue(_ id: String, _ due: Day?, now: Date = Date()) {
        edit(id, .due, now: now) { $0.due = due }
    }

    /// "Keep for today": re-dates carried-over Today tasks to today without pinning anything, and the older
    /// plan stops reading as stale for the rest of the day.
    public mutating func keepForToday(now: Date = Date()) {
        let day = Day(now)
        for i in tasks.indices where isCarriedOver(tasks[i], now: now) {
            let since = tasks[i].todaySince ?? plannedDay(of: tasks[i])
            tasks[i].plannedFor = day
            tasks[i].todaySince = since
            tasks[i].updatedAt = now
        }
        keptOn = day
    }

    /// "Not today": off Today for the rest of the day. A planned Today task moves to the week (a choice that
    /// binds today's plans only); one that is on Today because it falls due is snoozed until tomorrow, its
    /// deadline untouched.
    public mutating func notToday(_ id: String, now: Date = Date()) {
        guard let t = task(id) else { return }
        let day = Day(now)
        if t.when == .today { setWhen(id, .week, now: now) }
        if let due = t.due, due <= day {
            edit(id, nil, now: now) { $0.snoozedUntil = day.adding(days: 1) }
        }
    }

    public mutating func setArea(_ id: String, _ area: String, now: Date = Date()) {
        edit(id, .area, now: now) { $0.area = area }
    }

    public mutating func rename(_ id: String, _ title: String, now: Date = Date()) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        edit(id, .title, now: now) { $0.title = title }
    }

    public mutating func setNote(_ id: String, _ note: String, now: Date = Date()) {
        edit(id, .note, now: now) { $0.note = note }
    }

    public mutating func setEstimate(_ id: String, _ hours: Double?, now: Date = Date()) {
        edit(id, .estimate, now: now) { $0.estimate = hours }
    }

    /// An owner task. Only the fields the owner chose are pinned, so a plan run can still file
    /// an inbox task into an area and estimate it.
    @discardableResult
    public mutating func add(title: String, area: String = Area.inboxID, when: When = .week,
                             now: Date = Date()) -> TaskItem? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var pinned: Set<Field> = [.title, .when]
        if area != Area.inboxID { pinned.insert(.area) }
        let day = Day(now)
        let task = TaskItem(id: "u-" + UUID().uuidString.prefix(8).lowercased(), title: title, area: area,
                            when: when, origin: .user, createdAt: now, pinned: pinned,
                            plannedFor: when == .today ? day : nil, todaySince: when == .today ? day : nil,
                            whenSetOn: day)
        tasks.append(task)
        return task
    }

    /// Owner tasks are deleted; Claude's become dropped, so the next run knows not to suggest them again.
    public mutating func remove(_ id: String, now: Date = Date()) {
        guard let t = task(id) else { return }
        if t.origin == .user {
            tasks.removeAll { $0.id == id }
        } else {
            setStatus(id, .dropped, now: now)
        }
    }

    public mutating func acceptAdvice(_ id: String, now: Date = Date()) {
        guard let advice = task(id)?.advice else { return }
        setStatus(id, advice.status, now: now)
        edit(id, nil, now: now) { $0.closedReason = advice.reason.isEmpty ? nil : advice.reason }
    }

    public mutating func dismissAdvice(_ id: String, now: Date = Date()) {
        edit(id, nil, now: now) { $0.advice = nil }
    }

    public mutating func markSeen() {
        for i in tasks.indices where tasks[i].isNew { tasks[i].isNew = false }
    }
}

// MARK: - Plan run result

/// One Claude run's answer, folded into the live board by `Merge.merge`.
public struct PlanResult: Codable, Sendable {
    public struct PlannedTask: Codable, Sendable {
        public var id: String
        public var title: String
        public var note: String
        public var area: String
        public var status: TaskStatus
        public var priority: Priority
        public var when: When
        public var estimate: Double
        /// Empty when there's no source session.
        public var sessionId: String
        /// Filled by the planner from the digest; never by the model.
        public var cwd: String?
        /// The stake: why it matters now (≤ 80 chars).
        public var why: String
        /// Deadline, appointment, or check-back day for a waiting task.
        public var due: Day?
        public var kind: TaskKind

        public init(id: String, title: String, note: String, area: String, status: TaskStatus, priority: Priority,
                    when: When, estimate: Double, sessionId: String, cwd: String? = nil, why: String = "",
                    due: Day? = nil, kind: TaskKind = .task) {
            self.id = id
            self.title = title
            self.note = note
            self.area = area
            self.status = status
            self.priority = priority
            self.when = when
            self.estimate = estimate
            self.sessionId = sessionId
            self.cwd = cwd
            self.why = why
            self.due = due
            self.kind = kind
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, note, area, status, priority, when, estimate, sessionId, cwd, why, due, kind
        }

        /// Lenient like `TaskItem`: a result saved by an older build may lack fields.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            area = try c.decodeIfPresent(String.self, forKey: .area) ?? Area.inboxID
            status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .todo
            priority = try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .medium
            when = try c.decodeIfPresent(When.self, forKey: .when) ?? .week
            estimate = try c.decodeIfPresent(Double.self, forKey: .estimate) ?? 0
            sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
            due = try c.decodeIfPresent(Day.self, forKey: .due)
            kind = try c.decodeIfPresent(TaskKind.self, forKey: .kind) ?? .task
        }
    }

    public struct ClosedTask: Codable, Sendable {
        public var id: String
        /// done or dropped.
        public var status: TaskStatus
        public var reason: String

        public init(id: String, status: TaskStatus, reason: String) {
            self.id = id
            self.status = status
            self.reason = reason
        }
    }

    public var focus: String
    public var areas: [Area]
    /// Every open task that should stay on the board, most important first.
    public var tasks: [PlannedTask]
    /// Existing open tasks that are finished or no longer relevant.
    public var closed: [ClosedTask]
    public var generatedAt: Date
    public var model: String
    public var sessionCount: Int
    public var costUSD: Double?
    /// The look-back window the run read.
    public var days: Int?

    public init(focus: String, areas: [Area], tasks: [PlannedTask], closed: [ClosedTask], generatedAt: Date,
                model: String, sessionCount: Int, costUSD: Double? = nil, days: Int? = nil) {
        self.focus = focus
        self.areas = areas
        self.tasks = tasks
        self.closed = closed
        self.generatedAt = generatedAt
        self.model = model
        self.sessionCount = sessionCount
        self.costUSD = costUSD
        self.days = days
    }
}
