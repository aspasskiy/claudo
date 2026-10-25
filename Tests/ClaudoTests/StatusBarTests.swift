@testable import ClaudoCore
@testable import Claudo
import XCTest

/// The status bar says one thing at a time: error › undo › running › result › stale › idle › never planned.
final class StatusBarTests: XCTestCase {
    let now = Date()

    private func state(error: String? = nil, removed: String? = nil, running: Bool = false, notice: String? = nil,
                       stale: Bool = false, carried: Int = 0, planned: Bool = true) -> BarState {
        BarState.resolve(error: error, removed: removed, runStarted: running ? now : nil, stage: nil, notice: notice,
                         planIsStale: stale, carried: carried, plannedAt: planned ? now : nil)
    }

    func testEachStateWinsOverEveryOneBelowIt() {
        XCTAssertEqual(state(error: "x", removed: "t", running: true, notice: "n", stale: true).key, BarState.error("x").key)
        XCTAssertEqual(state(removed: "t", running: true, notice: "n", stale: true), .undo(title: "t"))
        XCTAssertEqual(state(running: true, notice: "n", stale: true), .running(stage: nil, started: now))
        XCTAssertEqual(state(notice: "n", stale: true), .result("n"))
        XCTAssertEqual(state(stale: true, carried: 3), .stale(planDay: Day(now), carried: 3))
        XCTAssertEqual(state(), .idle(planned: now))
        XCTAssertEqual(state(planned: false), .never)
    }

    func testAnOlderPlanWithNothingLeftIsStillStale() {
        // Today's rows of an earlier plan are all done or moved: the bar still offers today's plan, without Keep.
        XCTAssertEqual(state(stale: true, carried: 0), .stale(planDay: Day(now), carried: 0))
    }

    func testNoPlanIsNeverStaleAndARunOrAnErrorStillShows() {
        XCTAssertEqual(state(stale: true, planned: false), .never)
        XCTAssertEqual(state(running: true, planned: false).key, 2)
        XCTAssertEqual(state(error: "boom", planned: false), .error("boom"))
    }
}

/// The bar's words: when the plan is from, and a failed run in plain English.
final class StatusBarWordsTests: XCTestCase {
    /// The words below are the English ones, whatever the Mac's language.
    override func setUp() {
        super.setUp()
        Loc.russian = false
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testPlannedIsRelativeTodayAndADayAndTimeBefore() {
        let now = date(25, 14, 30)
        XCTAssertEqual(Fmt.planned(date(25, 14, 30), now: now), "Planned just now")
        XCTAssertEqual(Fmt.planned(date(25, 14, 5), now: now), "Planned 25 min ago")
        XCTAssertEqual(Fmt.planned(date(25, 3, 20), now: now), "Planned 11h ago")
        XCTAssertEqual(Fmt.planned(date(24, 16, 12), now: now), "Planned yesterday 16:12")
        XCTAssertEqual(Fmt.planned(date(23, 16, 12), now: now), "Planned Fri 16:12")
        XCTAssertEqual(Fmt.planned(date(16, 9, 0), now: now), "Planned 16 Oct")
    }

    func testFailuresDropTheExitCodeAndSayTheUsageLimitPlainly() {
        XCTAssertEqual(Fmt.failure("claude exited 1: Claude usage limit reached — your limit resets at 18:00. Try later."),
                       "Claude usage limit reached · resets 18:00")
        XCTAssertEqual(Fmt.failure("claude exited 1: 5-hour limit reached ∙ resets 6pm"),
                       "Claude usage limit reached · resets 6pm")
        XCTAssertEqual(Fmt.failure("claude exited 1: Claude AI usage limit reached"), "Claude usage limit reached")
        XCTAssertEqual(Fmt.failure("claude exited 2: network unreachable\nat line 3"), "Network unreachable")
        XCTAssertEqual(Fmt.failure("claude: overloaded"), "Overloaded")
        XCTAssertEqual(Fmt.failure("No Claude sessions in the last 30 days"), "No Claude sessions in the last 30 days")
        XCTAssertEqual(Fmt.failure("claude exited 1: "), "Claude stopped with an error")
    }
}
