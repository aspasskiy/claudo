@testable import ClaudoCore
@testable import Claudo
import XCTest

/// Today's layout (lead · the rest in the plan's order · check in) and the words the rows print.
final class TodayPlanTests: XCTestCase {
    /// The words below are the English ones, whatever the Mac's language.
    override func setUp() {
        super.setUp()
        Loc.russian = false
    }

    let now = Date()
    var today: Day { Day(now) }

    private func task(_ id: String, _ status: TaskStatus = .todo, kind: TaskKind = .task, when: When = .today,
                      estimate: Double? = nil, rank: Int = 0, due: Day? = nil, plannedFor: Day? = nil) -> TaskItem {
        TaskItem(id: id, title: id, status: status, when: when, estimate: estimate, rank: rank, origin: .claude,
                 createdAt: now.addingTimeInterval(-3600), due: due, kind: kind, plannedFor: plannedFor)
    }

    // MARK: TodayPlan

    func testEveryOpenRowLandsInExactlyOnePartAndCheckInsNeverLead() {
        let open = [task("w1", .waiting), task("d1", kind: .decision), task("b1"), task("d2", kind: .decision),
                    task("b2", .doing), task("w2", .waiting), task("dd", .doing, kind: .decision)]
        let plan = TodayPlan(open: open)
        XCTAssertEqual(plan.lead?.id, "d1", "the first row that asks for action leads, a check-in never does")
        XCTAssertEqual(plan.rest.map(\.id), ["b1", "d2", "b2", "dd"], "calls and work keep the plan's order")
        XCTAssertEqual(plan.checkIns.map(\.id), ["w1", "w2"])
        let all = [plan.lead?.id].compactMap { $0 } + plan.rest.map(\.id) + plan.checkIns.map(\.id)
        XCTAssertEqual(all.count, Set(all).count, "a row shows twice")
        XCTAssertEqual(Set(all), Set(open.map(\.id)), "a row is missing")
    }

    func testAnyKindLeadsAndTheRestKeepTheirOrder() {
        let plan = TodayPlan(open: [task("b1", .doing), task("d1", kind: .decision), task("b2")])
        XCTAssertEqual(plan.lead?.id, "b1", "work in progress can lead")
        XCTAssertEqual(plan.rest.map(\.id), ["d1", "b2"], "the lead isn't repeated below it")
    }

    /// Done with the lead, the row right under the card moves up into it; nothing further down leapfrogs it.
    func testFinishingTheLeadPromotesTheNextRowInPlanOrder() {
        let open = [task("lead"), task("d1", kind: .decision), task("b1"), task("d2", kind: .decision)]
        let before = TodayPlan(open: open)
        var next = open
        next[0].status = .done
        let after = TodayPlan(open: next)
        XCTAssertEqual(after.lead?.id, before.rest.first?.id)
        XCTAssertEqual(after.rest.map(\.id), Array(before.rest.dropFirst()).map(\.id), "the others keep their places")
        let work = TodayPlan(open: [task("lead"), task("b1"), task("d1", kind: .decision)])
        XCTAssertEqual(work.rest.map(\.id), ["b1", "d1"], "a call isn't hoisted above the work before it")
    }

    func testOnlyCheckInsHaveNoLeadAndClosedRowsAreIgnored() {
        let plan = TodayPlan(open: [task("w1", .waiting), task("x", .done), task("w2", .waiting)])
        XCTAssertNil(plan.lead)
        XCTAssertEqual(plan.checkIns.map(\.id), ["w1", "w2"])
        XCTAssertTrue(plan.rest.isEmpty)
        XCTAssertEqual(TodayPlan(open: []), TodayPlan(open: [task("y", .dropped)]))
    }

    func testLoadSumsEstimatesAndSkipsTheUnestimated() {
        XCTAssertEqual(TodayPlan.hours([task("a", estimate: 2), task("b"), task("c", estimate: 1.5)]), 3.5)
        XCTAssertEqual(TodayPlan.hours([]), 0)
    }

    /// On the board's own Today order: a row that falls due today without today's plan placing it comes
    /// first and leads; the plan's rows keep their ranks; a check-in whose day came sits in its section.
    func testOnTheBoardsTodayOrder() {
        var board = Board(plannedAt: now.addingTimeInterval(-7200))
        board.tasks = [
            task("decide", kind: .decision, rank: 0, plannedFor: today),
            task("block", rank: 1, plannedFor: today),
            task("reply", when: .week, rank: 5, due: today),
            task("check", .waiting, when: .week, rank: 6, due: today),
            task("later", when: .week, rank: 7, due: today.adding(days: 2)),
        ]
        let open = board.today(now: now).filter(\.status.isOpen)
        let plan = TodayPlan(open: open)
        XCTAssertEqual(plan.lead?.id, "reply")
        XCTAssertEqual(plan.rest.map(\.id), ["decide", "block"])
        XCTAssertEqual(plan.checkIns.map(\.id), ["check"])
        XCTAssertFalse(open.contains { $0.id == "later" }, "due in two days stays off Today")
    }

    // MARK: Words

    /// An empty filtered list names what the filter keeps, in the areas' order.
    @MainActor func testAnEmptyFilteredListSaysWhatItHides() {
        let store = Store(fixture: URL(fileURLWithPath: "/dev/null"))
        func area(_ id: String, _ name: String, _ weight: Weight) -> Area {
            Area(id: id, name: name, symbol: "folder.fill", color: .blue, weight: weight, status: "", outcome: "")
        }
        store.replaceBoard(Board(areas: [area("lumen", "Lumen", .active), area("atlas", "Atlas", .focus),
                                         area("mosaic", "Mosaic", .background)]))
        store.toggleFilterArea("atlas")
        XCTAssertEqual(store.nothingListed("on Today"), "Nothing for Atlas on Today")
        store.toggleFilterArea("lumen")
        store.setFilterKind(.decision)
        XCTAssertEqual(store.nothingListed("on Today", left: true), "No decisions left for Atlas and Lumen on Today")
        store.toggleFilterArea("mosaic")
        store.setFilterKind(.task)
        XCTAssertEqual(store.nothingListed("this week"), "No work for 3 areas this week")
        store.setFilterImportant(true)
        XCTAssertEqual(store.nothingListed("for later"), "No important work for 3 areas for later")
        store.clearFilter()
        store.toggleFilterArea(Area.inboxID)
        store.toggleFilterStatus(.doing)
        XCTAssertEqual(store.nothingListed("this week"), "Nothing in progress for Inbox this week")
    }

    func testCountsArePlural() {
        XCTAssertEqual(Fmt.count(1, "day"), "1 day")
        XCTAssertEqual(Fmt.count(6, "day"), "6 days")
        XCTAssertEqual(Fmt.count(0, "session"), "0 sessions")
        XCTAssertEqual(Fmt.count(11, "session"), "11 sessions")
    }

    func testDueChipWords() {
        let d = Day(year: 2026, month: 10, day: 24)
        XCTAssertEqual(Fmt.due(d, today: d, check: false), "Today")
        XCTAssertEqual(Fmt.due(d.adding(days: 1), today: d, check: false), "Tomorrow")
        XCTAssertEqual(Fmt.due(d.adding(days: 2), today: d, check: false), "Mon 26")
        XCTAssertEqual(Fmt.due(d.adding(days: 68), today: d, check: false), "31 Dec")
        XCTAssertEqual(Fmt.due(d.adding(days: -2), today: d, check: false), "Overdue 2d")
        // A check-back day: the chip draws ↩ in front, so the words are the day alone.
        XCTAssertEqual(Fmt.due(d.adding(days: 2), today: d, check: true), "Mon 26")
        XCTAssertEqual(Fmt.due(d, today: d, check: true), "Today")
        XCTAssertEqual(Fmt.due(d.adding(days: -2), today: d, check: true), "2d ago")
    }
}
