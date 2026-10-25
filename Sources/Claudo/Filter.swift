import ClaudoCore
import Foundation

/// What the popover lists, any combination at once: Today, This week or Later only, some areas only, decisions
/// or work only, work under way or waiting only, the important only. Empty means everything; it narrows every
/// view of the list and the panel's counts, never the tray.
struct BoardFilter: Codable, Equatable {
    /// The horizons to keep; empty keeps all three. What is on Today is the board's call (`Board.isOnToday`:
    /// due or overdue counts too), so the store applies this part, not `passes`.
    var when: Set<When> = []
    /// Area ids to keep; empty keeps every area. `Area.inboxID` also keeps rows of areas the board no
    /// longer has, the way the inbox files them.
    var areas: Set<String> = []
    /// `.decision` keeps the calls to make, `.task` the work; nil keeps both.
    var kind: TaskKind?
    /// `.doing` keeps work under way, `.waiting` work on someone else; empty keeps every status.
    var statuses: Set<TaskStatus> = []
    /// Urgent and high priority only.
    var important = false

    init(when: Set<When> = [], areas: Set<String> = [], kind: TaskKind? = nil, statuses: Set<TaskStatus> = [],
         important: Bool = false) {
        self.when = when
        self.areas = areas
        self.kind = kind
        self.statuses = statuses
        self.important = important
    }

    /// A filter saved by an older build has only some of the keys: the rest keep everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        when = try c.decodeIfPresent(Set<When>.self, forKey: .when) ?? []
        areas = try c.decodeIfPresent(Set<String>.self, forKey: .areas) ?? []
        kind = try c.decodeIfPresent(TaskKind.self, forKey: .kind)
        statuses = try c.decodeIfPresent(Set<TaskStatus>.self, forKey: .statuses) ?? []
        important = try c.decodeIfPresent(Bool.self, forKey: .important) ?? false
    }

    var isActive: Bool { !when.isEmpty || narrows }
    /// Some part other than the horizons is on: rows drop out of the groups they are in, so Today has no lead
    /// card and an empty group says what the filter left nothing of.
    var narrows: Bool { !areas.isEmpty || kind != nil || !statuses.isEmpty || important }

    /// `known` is the board's area ids, so a row of a vanished area counts as the inbox's.
    func passes(_ t: TaskItem, areas known: Set<String>) -> Bool {
        if let kind, t.kind != kind { return false }
        if !statuses.isEmpty, !statuses.contains(t.status) { return false }
        if important, t.priority > .high { return false }
        guard !areas.isEmpty else { return true }
        let area = known.contains(t.area) ? t.area : Area.inboxID
        return areas.contains(area)
    }
}
