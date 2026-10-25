@testable import ClaudoCore
import XCTest

/// Today · This week · Later: dated Today, carry-over, due dates, and the split of open tasks.
final class ViewTests: XCTestCase {
    /// F.now is Sunday 18.10, 09:00 UTC; the tests run in the machine's zone, so days are taken from F.now
    /// itself rather than written out.
    let today = Day(F.now)
    var yesterday: Day { today.adding(days: -1) }
    var tomorrow: Day { today.adding(days: 1) }

    // MARK: Day

    func testDayParsesFormatsAndCompares() throws {
        let d = try XCTUnwrap(Day("2026-10-26"))
        XCTAssertEqual(d, Day(year: 2026, month: 10, day: 26))
        XCTAssertEqual(d.description, "2026-10-26")
        XCTAssertNil(Day(""))
        XCTAssertNil(Day("26.10"))
        XCTAssertNil(Day("2026-13-01"))
        XCTAssertLessThan(Day(year: 2026, month: 10, day: 31), Day(year: 2026, month: 11, day: 1))
        XCTAssertEqual(Day(year: 2026, month: 10, day: 31).adding(days: 1), Day(year: 2026, month: 11, day: 1))
        XCTAssertEqual(Day(year: 2026, month: 10, day: 24).days(to: Day(year: 2026, month: 12, day: 31)), 68)
        XCTAssertEqual(Day(year: 2026, month: 10, day: 26).days(to: Day(year: 2026, month: 10, day: 24)), -2)
    }

    func testDayIsAStringInJSON() throws {
        struct Box: Codable, Equatable { var due: Day? }
        let data = try JSONEncoder().encode(Box(due: Day(year: 2026, month: 10, day: 26)))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"due":"2026-10-26"}"#)
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: data), Box(due: Day(year: 2026, month: 10, day: 26)))
        XCTAssertThrowsError(try JSONDecoder().decode(Box.self, from: Data(#"{"due":"Mon"}"#.utf8)))
    }

    // MARK: Older boards

    /// A version-3 board.json (no why / due / kind / plan days) still loads, and its Today tasks read as
    /// the last plan's: carried over once the day changes.
    func testAnOlderBoardDecodesWithDefaultsAndCarriesItsTodayOver() throws {
        let json = """
        {"version":3,"focus":"Atlas and the move","sessionCount":577,"plannedAt":"2026-10-23T09:12:45Z","model":"sonnet",
         "areas":[{"id":"atlas","name":"Atlas","symbol":"iphone","color":"coral","weight":"focus",
                   "status":"Quota not merged","outcome":""}],
         "tasks":[{"id":"t-quota-fix","title":"Merge and ship the quota fix","note":"Merge c0ffee1","area":"atlas",
                   "status":"todo","priority":"urgent","when":"today","estimate":2,"rank":0,"origin":"claude",
                   "createdAt":"2026-10-18T07:28:34Z","updatedAt":"2026-10-21T12:19:04Z","isNew":false,"pinned":[]},
                  {"id":"t-done","title":"Reply to the tax office","note":"","area":"atlas","status":"done",
                   "priority":"urgent","when":"today","rank":1,"origin":"claude","createdAt":"2026-10-21T03:11:18Z",
                   "updatedAt":"2026-10-23T05:11:28Z","completedAt":"2026-10-23T05:11:28Z","isNew":false,
                   "pinned":["status"]}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let board = try decoder.decode(Board.self, from: Data(json.utf8))
        let t = try XCTUnwrap(board.task("t-quota-fix"))
        XCTAssertEqual(t.why, "")
        XCTAssertNil(t.due)
        XCTAssertEqual(t.kind, .task)
        XCTAssertNil(t.plannedFor)
        XCTAssertNil(board.areas.first?.attention)

        let planned = try XCTUnwrap(board.plannedAt)
        let sameDay = planned.addingTimeInterval(3600)
        let nextDay = planned.addingTimeInterval(86400)
        XCTAssertEqual(board.plannedDay(of: t), Day(planned))
        XCTAssertFalse(board.isCarriedOver(t, now: sameDay))
        XCTAssertFalse(board.planIsStale(now: sameDay))
        XCTAssertTrue(board.isCarriedOver(t, now: nextDay))
        XCTAssertTrue(board.planIsStale(now: nextDay))
        XCTAssertEqual(board.today(now: nextDay).map(\.id), ["t-quota-fix"], "yesterday's done task leaves Today")
        XCTAssertEqual(board.daysOnToday(t, now: nextDay), 1)

        // And it round-trips with the new fields present.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let again = try decoder.decode(Board.self, from: encoder.encode(board))
        XCTAssertEqual(again.tasks, board.tasks)
    }

    func testTheRepoFixtureStillLoads() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/board.json")
        let board = try XCTUnwrap(BoardStore.load(from: url))
        XCTAssertFalse(board.tasks.isEmpty)
    }

    // MARK: The three parts

    /// Every kind of open task, plus closed ones that must stay out of all three parts.
    private func mixedBoard() -> Board {
        var board = F.board(tasks: [
            F.task("fresh", "Add payments to the game", area: "garden", when: .today),
            F.task("carried", "Merge the quota fix", when: .today),
            F.task("due-today", "Send the papers by courier", when: .week),
            F.task("overdue", "Reply to the bank", when: .later),
            F.task("due-later", "Call with Dana", area: "move", when: .week),
            F.task("doing", "Fix the crashes on the phone", area: "garden", status: .doing, when: .week),
            F.task("waiting", "The bank's answer on 31.12", area: "move", status: .waiting, when: .week),
            F.task("waiting-check", "A/B test: first check", status: .waiting, when: .later),
            F.task("decision", "Roll the onboarding out to 100%?", when: .week),
            F.task("decision-doing", "Refactoring: what to do with 142 files", status: .doing, when: .later),
            F.task("week", "Emails about the 80% quota", when: .week),
            F.task("later", "Reissue the keys", area: "garden", priority: .low, when: .later),
            F.task("done-today", "Send the emails", when: .today, completedAt: F.now - 3600),
            F.task("done-earlier", "Put the shortlist together", when: .today, completedAt: F.now - 3 * F.day),
        ])
        board.plannedAt = F.now - 2 * 3600
        // The plan's order is the list's order.
        for i in board.tasks.indices { board.tasks[i].rank = i }
        func set(_ id: String, _ change: (inout TaskItem) -> Void) {
            change(&board.tasks[board.tasks.firstIndex { $0.id == id }!])
        }
        set("fresh") { $0.plannedFor = today }
        set("carried") { $0.plannedFor = yesterday; $0.todaySince = today.adding(days: -6) }
        set("due-today") { $0.due = today }
        set("overdue") { $0.due = today.adding(days: -2) }
        set("due-later") { $0.due = tomorrow.adding(days: 1) }
        set("waiting-check") { $0.due = today }
        set("decision") { $0.kind = .decision }
        set("decision-doing") { $0.kind = .decision }
        set("done-today") { $0.status = .done }
        set("done-earlier") { $0.status = .done }
        return board
    }

    func testEveryOpenTaskIsInExactlyOneOfTodayThisWeekAndLater() {
        let board = mixedBoard()
        let today = board.today(now: F.now).filter(\.status.isOpen).map(\.id)
        let week = board.upcoming(.week, now: F.now).map(\.id)
        let later = board.upcoming(.later, now: F.now).map(\.id)
        let all = today + week + later
        XCTAssertEqual(all.count, Set(all).count, "a task shows in two parts")
        XCTAssertEqual(Set(all), Set(board.openTasks.map(\.id)), "an open task shows in no part")
        XCTAssertTrue(board.upcoming(.today, now: F.now).isEmpty, "a task for today is on Today")
    }

    func testTodayHoldsPlannedDueAndOverdueTasksDueFirst() {
        let board = mixedBoard()
        XCTAssertEqual(board.today(now: F.now).map(\.id),
                       ["overdue", "due-today", "waiting-check", "fresh", "carried", "done-today"])
        XCTAssertTrue(board.isCarriedOver(board.task("carried")!, now: F.now))
        XCTAssertFalse(board.isCarriedOver(board.task("fresh")!, now: F.now))
        XCTAssertFalse(board.isCarriedOver(board.task("due-today")!, now: F.now), "due-promoted isn't carried")
        XCTAssertEqual(board.daysOnToday(board.task("carried")!, now: F.now), 6)
        XCTAssertNil(board.daysOnToday(board.task("due-today")!, now: F.now))
    }

    func testThisWeekAndLaterGoByPriorityThenThePlansOrder() {
        var board = mixedBoard()
        XCTAssertEqual(board.upcoming(.week, now: F.now).map(\.id),
                       ["due-later", "doing", "waiting", "decision", "week"])
        XCTAssertEqual(board.upcoming(.later, now: F.now).map(\.id), ["decision-doing", "later"])
        board.setPriority("week", .urgent, now: F.now)
        XCTAssertEqual(board.upcoming(.week, now: F.now).first?.id, "week")
        // Tomorrow the due-later task is still for this week; the day it falls due it moves to Today.
        let thatDay = F.now + 2 * F.day
        XCTAssertTrue(board.isOnToday(board.task("due-later")!, now: thatDay))
        XCTAssertFalse(board.upcoming(.week, now: thatDay).contains { $0.id == "due-later" })
    }

    func testAWaitingTaskWithAPassedCheckDateComesBackOnToday() {
        var board = F.board(tasks: [F.task("w", "The bank's answer", status: .waiting, when: .week)])
        board.tasks[0].due = today.adding(days: 2)
        XCTAssertEqual(board.upcoming(.week, now: F.now).map(\.id), ["w"])
        XCTAssertEqual(board.today(now: F.now + 2 * F.day).map(\.id), ["w"])
    }

    func testHoursLeftCountOpenTodayTasks() {
        let board = mixedBoard()
        XCTAssertEqual(board.hoursLeftToday(now: F.now), 10)   // five open on Today × 2 h
    }

    // MARK: Owner's when, day-scoped

    func testMovingOntoTodayDatesItAndOffClearsIt() throws {
        var board = F.board(tasks: [F.task("t", "Task", when: .week)])
        board.setWhen("t", .today, now: F.now)
        var t = try XCTUnwrap(board.task("t"))
        XCTAssertEqual(t.plannedFor, today)
        XCTAssertEqual(t.todaySince, today)
        XCTAssertEqual(t.whenSetOn, today)
        XCTAssertTrue(t.pinned.contains(.when))

        board.setWhen("t", .week, now: F.now + 60)
        t = try XCTUnwrap(board.task("t"))
        XCTAssertNil(t.plannedFor)
        XCTAssertNil(t.todaySince)
    }

    func testReconfirmingACarriedTaskKeepsItsFirstDay() throws {
        var board = F.board(tasks: [F.task("t", "Task", when: .today)])
        board.tasks[0].plannedFor = yesterday
        board.tasks[0].todaySince = yesterday.adding(days: -2)
        board.setWhen("t", .today, now: F.now)
        let t = try XCTUnwrap(board.task("t"))
        XCTAssertEqual(t.plannedFor, today)
        XCTAssertEqual(t.todaySince, yesterday.adding(days: -2))
    }

    func testAWhenPinBindsOnlyTheDayItWasSetUnlessLater() throws {
        var board = F.board(tasks: [F.task("on", "For today"), F.task("off", "Not today", when: .today),
                                    F.task("later", "Later")])
        board.setWhen("on", .today, now: F.now)
        board.setWhen("off", .week, now: F.now)
        board.setWhen("later", .later, now: F.now)
        for id in ["on", "off", "later"] {
            XCTAssertTrue(try XCTUnwrap(board.task(id)).holdsWhenPin(on: today), id)
        }
        XCTAssertFalse(try XCTUnwrap(board.task("on")).holdsWhenPin(on: tomorrow))
        XCTAssertFalse(try XCTUnwrap(board.task("off")).holdsWhenPin(on: tomorrow))
        XCTAssertTrue(try XCTUnwrap(board.task("later")).holdsWhenPin(on: tomorrow))

        // A pin without a day (an older board's) keeps holding.
        let legacy = F.task("legacy", "Old", when: .today, pinned: [.when])
        XCTAssertTrue(legacy.holdsWhenPin(on: tomorrow))
        XCTAssertFalse(F.task("free", "No pin").holdsWhenPin(on: today))
    }

    func testAddingToTodayDatesTheOwnerTask() throws {
        var board = F.board()
        let t = try XCTUnwrap(board.add(title: "Buy the tickets", when: .today, now: F.now))
        XCTAssertEqual(t.plannedFor, today)
        XCTAssertEqual(t.whenSetOn, today)
        XCTAssertFalse(board.isCarriedOver(t, now: F.now))
        XCTAssertTrue(board.isCarriedOver(t, now: F.now + F.day))
    }

    func testKeepForTodayReDatesOnlyCarriedTasks() throws {
        var board = mixedBoard()
        board.keepForToday(now: F.now)
        let carried = try XCTUnwrap(board.task("carried"))
        XCTAssertEqual(carried.plannedFor, today)
        XCTAssertEqual(carried.todaySince, today.adding(days: -6))
        XCTAssertTrue(carried.pinned.isEmpty)
        XCTAssertFalse(board.today(now: F.now).contains { board.isCarriedOver($0, now: F.now) })
    }

    func testSetDuePinsIt() throws {
        var board = F.board(tasks: [F.task("t", "Task")])
        board.setDue("t", tomorrow, now: F.now)
        XCTAssertEqual(board.task("t")?.due, tomorrow)
        XCTAssertEqual(board.task("t")?.pinned, [.due])
    }

    // MARK: Snooze, keep, order, day arithmetic

    func testNotTodaySnoozesADueTaskWithoutTouchingItsDeadline() throws {
        var board = F.board(tasks: [F.task("parcel", "Send the papers by courier", when: .week),
                                    F.task("plan", "Add payments", when: .today)])
        board.tasks[0].due = today
        board.tasks[1].plannedFor = today
        board.notToday("parcel", now: F.now)
        board.notToday("plan", now: F.now)
        let parcel = try XCTUnwrap(board.task("parcel"))
        XCTAssertEqual(parcel.due, today, "the deadline stays")
        XCTAssertFalse(parcel.pinned.contains(.due))
        XCTAssertEqual(parcel.snoozedUntil, tomorrow)
        XCTAssertFalse(board.isOnToday(parcel, now: F.now))
        XCTAssertTrue(board.isOnToday(parcel, now: F.now + F.day), "back the next day, overdue")
        XCTAssertEqual(board.upcoming(.week, now: F.now).map(\.id), ["parcel", "plan"])
        let plan = try XCTUnwrap(board.task("plan"))
        XCTAssertEqual(plan.when, .week)
        XCTAssertNil(plan.snoozedUntil)
        XCTAssertTrue(plan.holdsWhenPin(on: today))
    }

    func testKeepMakesAnOlderPlanCurrentForTheDay() throws {
        var board = mixedBoard()
        board.plannedAt = F.now - 2 * F.day
        XCTAssertTrue(board.planIsStale(now: F.now))
        board.keepForToday(now: F.now)
        XCTAssertEqual(board.keptOn, today)
        XCTAssertFalse(board.planIsStale(now: F.now))
        XCTAssertTrue(board.planIsStale(now: F.now + F.day), "kept for one day only")
    }

    /// An older board has no plannedFor / todaySince on its Today tasks.
    func testKeepAndSetWhenKeepAnUndatedTasksFirstDay() throws {
        var board = F.board(tasks: [F.task("a", "Merge the quota fix", when: .today),
                                    F.task("b", "Reply to Dana", when: .today)])
        board.plannedAt = F.now - 2 * F.day
        let planned = Day(F.now - 2 * F.day)
        board.keepForToday(now: F.now)
        XCTAssertEqual(board.task("a")?.todaySince, planned)
        XCTAssertEqual(board.daysOnToday(board.task("a")!, now: F.now), 2)

        var other = F.board(tasks: [F.task("b", "Reply to Dana", when: .today)])
        other.plannedAt = F.now - 2 * F.day
        other.setWhen("b", .today, now: F.now)
        XCTAssertEqual(other.task("b")?.todaySince, planned)
        XCTAssertEqual(other.task("b")?.plannedFor, today)
    }

    func testTodaysPlanKeepsItsRankForATaskThatFallsDue() {
        var board = F.board(tasks: [F.task("first", "Add payments", when: .today),
                                    F.task("call", "Dates to Dana before the call", when: .today),
                                    F.task("promoted", "Courier", when: .week)])
        for i in board.tasks.indices { board.tasks[i].rank = i }
        board.tasks[0].plannedFor = today
        board.tasks[1].plannedFor = today
        board.tasks[1].due = today
        board.tasks[2].due = today
        XCTAssertEqual(board.today(now: F.now).map(\.id), ["promoted", "first", "call"])
    }

    func testDayArithmeticSurvivesADSTGapAtMidnight() {
        // Santiago skipped 00:00 → 01:00 on 06.09.2026; São Paulo did on 04.11.2018.
        XCTAssertEqual(Day(year: 2026, month: 9, day: 6).days(to: Day(year: 2026, month: 9, day: 7)), 1)
        XCTAssertEqual(Day(year: 2018, month: 11, day: 4).adding(days: 1), Day(year: 2018, month: 11, day: 5))
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago")!
        let start = Day(year: 2026, month: 9, day: 6).date(calendar: santiago)
        XCTAssertEqual(Day(start, calendar: santiago), Day(year: 2026, month: 9, day: 6))
        XCTAssertEqual(Day(year: 2026, month: 12, day: 31).adding(days: 1), Day(year: 2027, month: 1, day: 1))
        XCTAssertEqual(Day(year: 2028, month: 2, day: 28).adding(days: 1), Day(year: 2028, month: 2, day: 29))
    }

    func testADayIsGregorianWhateverTheSystemCalendar() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let date = ISO8601DateFormatter().date(from: "2026-10-24T05:00:00Z")!
        XCTAssertEqual(Day(date, calendar: buddhist), Day(year: 2026, month: 10, day: 24))
    }
}
