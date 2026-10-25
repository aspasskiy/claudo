@testable import ClaudoCore
import XCTest

/// Merge rules for days: why / due / kind from the plan, the plan's dated Today, and the owner's when
/// choices that bind only the day they were made.
final class MergeDayTests: XCTestCase {
    /// F.result is generated at F.now: this is the plan's day. F.board was planned the day before.
    let today = Day(F.now)
    var yesterday: Day { today.adding(days: -1) }

    private func merge(_ result: PlanResult, _ board: Board) -> Board {
        Merge.merge(result, into: board, now: F.now).board
    }

    private func planned(_ id: String, when: When = .today, why: String = "", due: Day? = nil,
                         kind: TaskKind = .task) -> PlanResult.PlannedTask {
        var p = F.planned(id, "Task \(id)", when: when)
        p.why = why
        p.due = due
        p.kind = kind
        return p
    }

    private func task(_ id: String, when: When = .week) -> TaskItem {
        F.task(id, "Task \(id)", when: when)
    }

    // MARK: why · due · kind

    func testWhyDueAndKindComeFromThePlan() throws {
        let long = String(repeating: "the client awaits a reply ", count: 8)
        let board = F.board(tasks: [task("t")])
        var merged = merge(F.result(tasks: [planned("t", when: .week, why: long, due: today.adding(days: 2),
                                                    kind: .decision)]), board)
        var t = try XCTUnwrap(merged.task("t"))
        XCTAssertLessThanOrEqual(t.why.count, 80)
        XCTAssertTrue(t.why.hasSuffix("…"))
        XCTAssertEqual(t.due, today.adding(days: 2))
        XCTAssertEqual(t.kind, .decision)

        // The next run's word stands: no due clears it, a task is a task again.
        merged = merge(F.result(tasks: [planned("t", when: .week, why: "The deadline moved")]), merged)
        t = try XCTUnwrap(merged.task("t"))
        XCTAssertNil(t.due)
        XCTAssertEqual(t.kind, .task)
        XCTAssertEqual(t.why, "The deadline moved")
    }

    func testTheOwnersDueIsKept() throws {
        var board = F.board(tasks: [task("t")])
        board.setDue("t", today.adding(days: 3), now: F.now - 60)
        let merged = merge(F.result(tasks: [planned("t", when: .week, due: today.adding(days: 1))]), board)
        XCTAssertEqual(merged.task("t")?.due, today.adding(days: 3))
        XCTAssertEqual(merged.task("t")?.pinned, [.due])
    }

    func testNewTasksGetTheNewFieldsAndTheirTodayIsDated() throws {
        let merged = merge(F.result(tasks: [planned("a", why: "Partner waiting since 16.10", due: today, kind: .decision),
                                            planned("b", when: .week)]), F.board())
        let a = try XCTUnwrap(merged.task("a"))
        XCTAssertEqual(a.why, "Partner waiting since 16.10")
        XCTAssertEqual(a.due, today)
        XCTAssertEqual(a.kind, .decision)
        XCTAssertEqual(a.plannedFor, today)
        XCTAssertEqual(a.todaySince, today)
        XCTAssertFalse(merged.isCarriedOver(a, now: F.now))
        XCTAssertTrue(merged.isCarriedOver(a, now: F.now + F.day), "tomorrow it is yesterday's plan")
        let b = try XCTUnwrap(merged.task("b"))
        XCTAssertNil(b.plannedFor)
        XCTAssertNil(b.todaySince)
    }

    // MARK: Day-scoped when pins

    func testYesterdaysTodayYieldsToTheNewPlan() throws {
        var board = F.board(tasks: [task("t")])
        board.setWhen("t", .today, now: F.now - F.day)
        let merged = merge(F.result(tasks: [planned("t", when: .week)]), board)
        let t = try XCTUnwrap(merged.task("t"))
        XCTAssertEqual(t.when, .week)
        XCTAssertFalse(t.pinned.contains(.when))
        XCTAssertNil(t.whenSetOn)
        XCTAssertNil(t.plannedFor)
        XCTAssertNil(t.todaySince)
    }

    func testYesterdaysNotTodayYieldsToo() throws {
        var board = F.board(tasks: [task("t", when: .today)])
        board.setWhen("t", .week, now: F.now - F.day)
        let merged = merge(F.result(tasks: [planned("t", when: .today)]), board)
        let t = try XCTUnwrap(merged.task("t"))
        XCTAssertEqual(t.when, .today)
        XCTAssertFalse(t.pinned.contains(.when))
        XCTAssertEqual(t.plannedFor, today)
        XCTAssertEqual(t.todaySince, today, "off Today before the run: a new stretch starts")
    }

    func testTodaysChoiceHoldsBothWays() throws {
        var board = F.board(tasks: [task("on"), task("off", when: .today)])
        board.setWhen("on", .today, now: F.now - 60)
        board.setWhen("off", .week, now: F.now - 60)
        let merged = merge(F.result(tasks: [planned("on", when: .week), planned("off", when: .today)]), board)
        let on = try XCTUnwrap(merged.task("on"))
        XCTAssertEqual(on.when, .today)
        XCTAssertTrue(on.pinned.contains(.when))
        XCTAssertEqual(on.whenSetOn, today)
        XCTAssertEqual(on.plannedFor, today, "the owner's own dates stay")
        XCTAssertEqual(on.todaySince, today)
        let off = try XCTUnwrap(merged.task("off"))
        XCTAssertEqual(off.when, .week)
        XCTAssertTrue(off.pinned.contains(.when))
        XCTAssertNil(off.plannedFor)
    }

    func testLaterSticksAndAPinWithoutADayHolds() throws {
        var board = F.board(tasks: [task("later"), F.task("legacy", "Legacy task", when: .week, pinned: [.when])])
        board.setWhen("later", .later, now: F.now - 3 * F.day)
        let merged = merge(F.result(tasks: [planned("later"), planned("legacy")]), board)
        XCTAssertEqual(merged.task("later")?.when, .later)
        XCTAssertEqual(merged.task("later")?.pinned, [.when])
        XCTAssertEqual(merged.task("legacy")?.when, .week)
        XCTAssertNil(merged.task("legacy")?.plannedFor)
    }

    func testExpiredPinsAreReleasedOnTasksTheRunDoesNotMention() throws {
        var board = F.board(tasks: [task("on"), task("off", when: .today), task("later"), task("fresh"),
                                    F.task("legacy", "Legacy task", when: .week, pinned: [.when, .priority])])
        board.setWhen("on", .today, now: F.now - F.day)
        board.setWhen("off", .week, now: F.now - F.day)
        board.setWhen("later", .later, now: F.now - 3 * F.day)
        board.setWhen("fresh", .today, now: F.now - 60)
        let merged = merge(F.result(tasks: [planned("other", when: .week)]), board)

        let on = try XCTUnwrap(merged.task("on"))
        XCTAssertFalse(on.pinned.contains(.when), "yesterday's choice no longer binds")
        XCTAssertNil(on.whenSetOn)
        XCTAssertEqual(on.when, .today, "unmentioned: nothing else changes")
        XCTAssertEqual(on.plannedFor, yesterday)
        XCTAssertTrue(merged.isCarriedOver(on, now: F.now))
        XCTAssertEqual(on.updatedAt, board.task("on")?.updatedAt, "bookkeeping, not an edit")
        let off = try XCTUnwrap(merged.task("off"))
        XCTAssertFalse(off.pinned.contains(.when))
        XCTAssertNil(off.whenSetOn)
        XCTAssertEqual(off.when, .week)

        XCTAssertEqual(merged.task("later")?.pinned, [.when], "Later sticks")
        XCTAssertEqual(merged.task("fresh")?.pinned, [.when], "today's choice holds")
        XCTAssertEqual(merged.task("fresh")?.whenSetOn, today)
        XCTAssertEqual(merged.task("legacy")?.pinned, [.when, .priority], "a pin without a day holds")
    }

    func testASnoozeIsTheOwnersAndSurvivesTheMerge() throws {
        var board = F.board(tasks: [task("parcel"), task("permit")])
        board.tasks[0].due = today
        board.tasks[1].due = today
        board.notToday("parcel", now: F.now - 60)
        board.notToday("permit", now: F.now - 60)
        XCTAssertFalse(board.isOnToday(board.tasks[0], now: F.now))
        let merged = merge(F.result(tasks: [planned("parcel", when: .week, due: today)]), board)
        XCTAssertEqual(merged.task("parcel")?.snoozedUntil, today.adding(days: 1))
        XCTAssertEqual(merged.task("parcel")?.due, today, "the deadline is the plan's to keep")
        XCTAssertEqual(merged.task("permit")?.snoozedUntil, today.adding(days: 1))
        XCTAssertFalse(merged.isOnToday(try XCTUnwrap(merged.task("parcel")), now: F.now))
        XCTAssertTrue(merged.isOnToday(try XCTUnwrap(merged.task("parcel")), now: F.now + F.day))
    }

    // MARK: Today stretches

    func testACarriedTaskThePlanKeepsOnTodayKeepsItsFirstDay() throws {
        var board = F.board(tasks: [task("t", when: .today), task("undated", when: .today)])
        board.tasks[0].plannedFor = yesterday
        board.tasks[0].todaySince = today.adding(days: -4)
        XCTAssertTrue(board.isCarriedOver(board.tasks[0], now: F.now))

        let merged = merge(F.result(tasks: [planned("t"), planned("undated")]), board)
        let t = try XCTUnwrap(merged.task("t"))
        XCTAssertEqual(t.plannedFor, today)
        XCTAssertEqual(t.todaySince, today.adding(days: -4))
        XCTAssertFalse(merged.isCarriedOver(t, now: F.now))
        XCTAssertEqual(merged.daysOnToday(t, now: F.now), 4)

        // An undated task has no stretch on record: it starts with the old plan's day.
        let undated = try XCTUnwrap(merged.task("undated"))
        XCTAssertEqual(undated.plannedFor, today)
        XCTAssertEqual(undated.todaySince, yesterday)
    }

    func testATaskThePlanMovesOffTodayLosesItsDays() throws {
        var board = F.board(tasks: [task("t", when: .today)])
        board.tasks[0].plannedFor = yesterday
        board.tasks[0].todaySince = today.adding(days: -3)
        let merged = merge(F.result(tasks: [planned("t", when: .later)]), board)
        let t = try XCTUnwrap(merged.task("t"))
        XCTAssertNil(t.plannedFor)
        XCTAssertNil(t.todaySince)
        XCTAssertFalse(merged.isOnToday(t, now: F.now))
    }

    func testAnUndatedTodayTaskTheRunDoesNotMentionStaysCarriedOver() throws {
        let board = F.board(tasks: [task("old", when: .today)])
        XCTAssertTrue(board.isCarriedOver(board.tasks[0], now: F.now))
        let merged = merge(F.result(tasks: [planned("other")]), board)
        let old = try XCTUnwrap(merged.task("old"))
        XCTAssertEqual(old.plannedFor, yesterday, "the old plan's day is written down before the plan day moves")
        XCTAssertTrue(merged.isCarriedOver(old, now: F.now))
        XCTAssertEqual(old.updatedAt, board.tasks[0].updatedAt)
    }

    // MARK: Areas and sessions

    func testAttentionIsClampedAndAnAreaTheRunDropsLosesIt() throws {
        var atlas = F.atlas, move = F.move, garden = F.garden
        atlas.attention = 140
        move.attention = -5
        garden.attention = 30
        let board = F.board(areas: [atlas, move, garden], tasks: [F.task("level", "Level", area: "garden")])
        let merged = merge(F.result(areas: [atlas, move]), board)
        XCTAssertEqual(merged.area("atlas")?.attention, 100)
        XCTAssertEqual(merged.area("move")?.attention, 0)
        XCTAssertEqual(merged.area("garden")?.weight, .parked)
        XCTAssertNil(merged.area("garden")?.attention, "the run gave it no share of the week")
    }

    func testAShortSessionIdKeepsTheKnownLink() throws {
        let full = "5e55a0c1-0000-4000-8000-000000000001"
        let board = F.board(tasks: [F.task("t", "Task t", sessionId: full, cwd: "/Users/me/dev/atlas/api")])
        var p = planned("t", when: .week)
        p.sessionId = "5e55a0c1"
        let merged = merge(F.result(tasks: [p]), board)
        XCTAssertEqual(merged.task("t")?.sessionId, full)
        XCTAssertEqual(merged.task("t")?.cwd, "/Users/me/dev/atlas/api")
    }
}
