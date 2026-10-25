import ClaudoCore
import Foundation

/// Today's open rows the way the popover lays them out: one row to start with, then the rest in the plan's
/// order, then the check-ins whose day has come. The board's Today order is the plan's order and nothing is
/// hoisted past it, so when the lead is done the row right under its card is the one that moves up into it.
/// Every open row lands in exactly one part, and the tray's "Next:" is the same lead.
struct TodayPlan: Equatable {
    /// The first row in the plan's order that asks for action; a check-in never leads.
    let lead: TaskItem?
    /// Calls and work after the lead, in the plan's order (the diamond tells a call from work).
    let rest: [TaskItem]
    /// Waiting rows on Today: their check-back day has come, or the plan put them there.
    let checkIns: [TaskItem]

    init(open: [TaskItem]) {
        let open = open.filter(\.status.isOpen)
        let lead = open.first { $0.status != .waiting }
        self.lead = lead
        rest = open.filter { $0.status != .waiting && $0.id != lead?.id }
        checkIns = open.filter { $0.status == .waiting }
    }

    /// Owner hours estimated for the rows: Today's load, "≈3h".
    static func hours(_ rows: [TaskItem]) -> Double {
        rows.reduce(0) { $0 + ($1.estimate ?? 0) }
    }
}
