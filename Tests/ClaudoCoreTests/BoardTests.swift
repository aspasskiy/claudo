@testable import ClaudoCore
import XCTest

/// Owner actions: each pins what it touches, so the next plan run leaves it alone.
final class BoardTests: XCTestCase {
    func testSetStatusPinsAndStampsCompletion() {
        var board = F.board(tasks: [F.task("t", "Task")])
        board.setStatus("t", .done, now: F.now)
        XCTAssertEqual(board.task("t")?.status, .done)
        XCTAssertEqual(board.task("t")?.completedAt, F.now)
        XCTAssertEqual(board.task("t")?.pinned, [.status])
        XCTAssertEqual(board.task("t")?.updatedAt, F.now)

        board.setStatus("t", .doing, now: F.now + 60)
        XCTAssertNil(board.task("t")?.completedAt)
    }

    func testSetStatusClearsAdvice() {
        var board = F.board(tasks: [F.task("t", "Task", pinned: [.status], advice: Advice(status: .done, reason: "x"))])
        board.setStatus("t", .waiting, now: F.now)
        XCTAssertNil(board.task("t")?.advice)
    }

    func testFieldSettersPinTheirField() {
        var board = F.board(tasks: [F.task("t", "Task")])
        board.setPriority("t", .urgent, now: F.now)
        board.setWhen("t", .today, now: F.now)
        board.setArea("t", "garden", now: F.now)
        board.rename("t", "  New name  ", now: F.now)
        board.setNote("t", "The owner's note", now: F.now)
        board.setEstimate("t", 1.5, now: F.now)
        let t = try! XCTUnwrap(board.task("t"))
        XCTAssertEqual(t.pinned, [.priority, .when, .area, .title, .note, .estimate])
        XCTAssertEqual(t.title, "New name")
        XCTAssertEqual(t.area, "garden")
        XCTAssertEqual(t.estimate, 1.5)
    }

    func testRenameToBlankIsIgnored() {
        var board = F.board(tasks: [F.task("t", "Task")])
        board.rename("t", "   ", now: F.now)
        XCTAssertEqual(board.task("t")?.title, "Task")
        XCTAssertEqual(board.task("t")?.pinned, [])
    }

    func testAddPinsTitleAndWhenAndTheAreaOnlyWhenChosen() {
        var board = F.board()
        let inbox = try! XCTUnwrap(board.add(title: "Buy the tickets", when: .today, now: F.now))
        XCTAssertEqual(inbox.origin, .user)
        XCTAssertEqual(inbox.area, Area.inboxID)
        XCTAssertEqual(inbox.pinned, [.title, .when])
        XCTAssertTrue(inbox.id.hasPrefix("u-"))

        let filed = try! XCTUnwrap(board.add(title: "Reply to Dana", area: "move", now: F.now))
        XCTAssertEqual(filed.pinned, [.title, .when, .area])
        XCTAssertNil(board.add(title: "  ", now: F.now))
        XCTAssertEqual(board.tasks.count, 2)
    }

    func testRemoveDeletesOwnerTasksAndDropsClaudes() {
        var board = F.board(tasks: [F.task("mine", "Mine", origin: .user), F.task("claude", "Suggested")])
        board.remove("mine", now: F.now)
        board.remove("claude", now: F.now)
        XCTAssertNil(board.task("mine"))
        XCTAssertEqual(board.task("claude")?.status, .dropped)
        XCTAssertTrue(board.task("claude")!.pinned.contains(.status))
    }

    func testAcceptAdviceAppliesItsStatusAndReason() {
        var board = F.board(tasks: [F.task("t", "Task", status: .doing, pinned: [.status],
                                           advice: Advice(status: .done, reason: "merged"))])
        board.acceptAdvice("t", now: F.now)
        let t = try! XCTUnwrap(board.task("t"))
        XCTAssertEqual(t.status, .done)
        XCTAssertEqual(t.closedReason, "merged")
        XCTAssertEqual(t.completedAt, F.now)
        XCTAssertNil(t.advice)
    }

    func testDismissAdviceKeepsTheStatus() {
        var board = F.board(tasks: [F.task("t", "Task", status: .doing, pinned: [.status],
                                           advice: Advice(status: .done, reason: "x"))])
        board.dismissAdvice("t", now: F.now)
        XCTAssertNil(board.task("t")?.advice)
        XCTAssertEqual(board.task("t")?.status, .doing)
    }

    func testMarkSeenClearsNewFlags() {
        var board = F.board(tasks: [F.task("a", "A", isNew: true), F.task("b", "B", isNew: true)])
        XCTAssertEqual(board.unseenCount, 2)
        board.markSeen()
        XCTAssertEqual(board.unseenCount, 0)
    }

    func testTodayHoldsOpenTodayTasksAndTheOnesClosedToday() {
        let board = F.board(tasks: [
            F.task("open", "Open", when: .today),
            F.task("doneToday", "Done today", status: .done, when: .today, completedAt: F.now - 600),
            F.task("doneYesterday", "Done yesterday", status: .done, when: .today, completedAt: F.now - F.day),
            F.task("week", "For the week", when: .week),
        ])
        XCTAssertEqual(board.today(now: F.now).map(\.id), ["open", "doneToday"])
    }

    func testInboxCollectsUnknownAreas() {
        let board = F.board(tasks: [F.task("a", "A", area: Area.inboxID), F.task("b", "B", area: "gone"),
                                    F.task("c", "C", area: "atlas")])
        XCTAssertEqual(Set(board.tasks(in: Area.inboxID).map(\.id)), ["a", "b"])
        XCTAssertEqual(board.area("gone")?.id, nil)
        XCTAssertEqual(board.area(Area.inboxID)?.name, "Inbox")
    }

    func testDisplayOrderGroupsByStatusThenPriorityThenRank() {
        var urgent = F.task("urgent", "Urgent", priority: .urgent)
        urgent.rank = 5
        var first = F.task("first", "First", priority: .high)
        first.rank = 0
        var second = F.task("second", "Second", priority: .high)
        second.rank = 1
        let doing = F.task("doing", "In progress", status: .doing, priority: .low)
        let waiting = F.task("waiting", "Waiting", status: .waiting, priority: .urgent)
        let done = F.task("done", "Done", status: .done, completedAt: F.now)
        let sorted = [done, second, waiting, first, doing, urgent].sorted(by: TaskItem.displayOrder)
        XCTAssertEqual(sorted.map(\.id), ["doing", "urgent", "first", "second", "waiting", "done"])
    }

    func testOrderedAreasFollowWeightThenRunOrder() {
        let board = F.board(areas: [F.garden, F.atlas, F.area("misc", "Other", weight: .parked), F.move])
        XCTAssertEqual(board.orderedAreas.map(\.id), ["atlas", "move", "garden", "misc"])
    }

    func testDoneThisWeekIsRecentDoneTasksLatestFirst() {
        let board = F.board(tasks: [F.task("a", "A", status: .done, completedAt: F.now - F.day),
                                    F.task("b", "B", status: .done, completedAt: F.now - 8 * F.day),
                                    F.task("c", "C", status: .dropped, completedAt: F.now - 2 * F.day),
                                    F.task("d", "D", status: .done, completedAt: F.now - 3600)])
        XCTAssertEqual(board.doneThisWeek(now: F.now).map(\.id), ["d", "a"])
        XCTAssertEqual(board.closedThisWeek(now: F.now).map(\.id), ["d", "a", "c"], "dropped ones too")
    }
}
