@testable import ClaudoCore
import XCTest

final class MergeTests: XCTestCase {
    private func merge(_ result: PlanResult, _ board: Board) -> (board: Board, summary: Merge.Summary) {
        Merge.merge(result, into: board, now: F.now)
    }

    // MARK: Rule 1 — new tasks and dedupe

    func testNewTaskIsInsertedAsUnseenClaudeTask() {
        let (board, summary) = merge(F.result(tasks: [F.planned("release", "Settle what goes into release 2.0",
                                                                 status: .doing, priority: .urgent, estimate: 2.5)]),
                                     F.board())
        let t = try! XCTUnwrap(board.task("release"))
        XCTAssertEqual(t.origin, .claude)
        XCTAssertTrue(t.isNew)
        XCTAssertEqual(t.createdAt, F.now)
        XCTAssertEqual(t.status, .doing)
        XCTAssertEqual(t.priority, .urgent)
        XCTAssertEqual(t.when, .today)
        XCTAssertEqual(t.estimate, 2.5)
        XCTAssertEqual(t.area, "atlas")
        XCTAssertTrue(t.pinned.isEmpty)
        XCTAssertEqual(summary.added, 1)
    }

    func testNewTaskWithUnknownAreaLandsInInbox() {
        let (board, _) = merge(F.result(tasks: [F.planned("x", "Go through the mail", area: "nowhere")]), F.board())
        XCTAssertEqual(board.task("x")?.area, Area.inboxID)
    }

    func testNewIdWithSameNormalizedTitleUpdatesTheExistingTask() {
        let board = F.board(tasks: [F.task("atlas-pr", "Merge PR fix/quota into atlas", priority: .high)])
        let (merged, summary) = merge(F.result(tasks: [
            F.planned("merge-atlas-pr", "merge  PR fix/quota into Atlas!", priority: .urgent),
        ]), board)
        XCTAssertEqual(merged.tasks.count, 1)
        XCTAssertEqual(merged.tasks[0].id, "atlas-pr")
        XCTAssertEqual(merged.tasks[0].priority, .urgent)
        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(summary.updated, 1)
    }

    func testResuggestionOfARecentlyClosedTaskIsSwallowed() {
        let board = F.board(tasks: [F.task("movers", "Email the movers", area: "move",
                                           status: .done, completedAt: F.now - 2 * F.day)])
        let (merged, summary) = merge(F.result(tasks: [F.planned("movers-2", "Email the movers",
                                                                  area: "move")]), board)
        XCTAssertEqual(merged.tasks.count, 1)
        XCTAssertEqual(merged.tasks[0].status, .done)
        XCTAssertEqual(summary.added, 0)
    }

    func testTaskClosedLongAgoIsPrunedAndCanComeBack() {
        let board = F.board(tasks: [F.task("movers", "Email the movers", area: "move",
                                           status: .done, createdAt: F.now - 50 * F.day, completedAt: F.now - 40 * F.day)])
        let (merged, _) = merge(F.result(tasks: [F.planned("movers-2", "Email the movers",
                                                            area: "move")]), board)
        XCTAssertEqual(merged.tasks.map(\.id), ["movers-2"])
        XCTAssertTrue(merged.tasks[0].status.isOpen)
    }

    func testIdOfATaskClosedLongAgoIsFreeAgain() {
        let board = F.board(tasks: [F.task("quota", "Fix the quota", status: .done, createdAt: F.now - 50 * F.day,
                                           completedAt: F.now - 40 * F.day)])
        let (merged, summary) = merge(F.result(tasks: [F.planned("quota", "Fix the quota again")]), board)
        XCTAssertEqual(merged.tasks.count, 1)
        XCTAssertEqual(merged.task("quota")?.status, .todo)
        XCTAssertEqual(merged.task("quota")?.isNew, true)
        XCTAssertEqual(summary.added, 1)
    }

    func testDuplicateSuggestionsInOneRunMergeOnce() {
        let (merged, summary) = merge(F.result(tasks: [
            F.planned("a", "Fix the inbound quota"),
            F.planned("b", "Fix the inbound quota."),
        ]), F.board())
        XCTAssertEqual(merged.tasks.map(\.id), ["a"])
        XCTAssertEqual(summary.added, 1)
    }

    // MARK: Rule 2–3 — updates, pins, owner titles, no reopening

    func testUpdateTouchesOnlyUnpinnedFields() {
        let board = F.board(tasks: [F.task("quota", "Fix the quota", priority: .low, when: .later, estimate: 1,
                                           pinned: [.priority, .when])])
        let (merged, _) = merge(F.result(tasks: [F.planned("quota", "Fix the inbound quota", priority: .urgent,
                                                            when: .today, estimate: 3, note: "Leave inbound out")]),
                                board)
        let t = try! XCTUnwrap(merged.task("quota"))
        XCTAssertEqual(t.priority, .low)
        XCTAssertEqual(t.when, .later)
        XCTAssertEqual(t.title, "Fix the inbound quota")
        XCTAssertEqual(t.note, "Leave inbound out")
        XCTAssertEqual(t.estimate, 3)
        XCTAssertEqual(t.updatedAt, F.now)
        XCTAssertFalse(t.isNew)
    }

    func testOwnerTitleNeverChangesButInboxTaskGetsFiled() {
        // No .title pin on purpose: the origin alone protects the owner's wording.
        let board = F.board(tasks: [F.task("u-1", "buy tickets", area: Area.inboxID, origin: .user)])
        let (merged, _) = merge(F.result(tasks: [F.planned("u-1", "Buy train tickets", area: "move")]), board)
        let t = try! XCTUnwrap(merged.task("u-1"))
        XCTAssertEqual(t.title, "buy tickets")
        XCTAssertEqual(t.area, "move")
        XCTAssertEqual(t.origin, .user)
    }

    func testPinnedTitleOfClaudeTaskIsKept() {
        let board = F.board(tasks: [F.task("t", "My title", pinned: [.title])])
        let (merged, _) = merge(F.result(tasks: [F.planned("t", "Another title")]), board)
        XCTAssertEqual(merged.task("t")?.title, "My title")
    }

    func testClosedTaskIsNeverReopened() {
        let board = F.board(tasks: [F.task("done-1", "Email Dana", status: .done,
                                           completedAt: F.now - F.day),
                                    F.task("drop-1", "Reconcile the ads", status: .dropped, pinned: [.status],
                                           completedAt: F.now - F.day)])
        let (merged, summary) = merge(F.result(tasks: [F.planned("done-1", "Email Dana", status: .doing),
                                                       F.planned("drop-1", "Reconcile the ads")]), board)
        XCTAssertEqual(merged.task("done-1")?.status, .done)
        XCTAssertEqual(merged.task("done-1")?.completedAt, F.now - F.day)
        XCTAssertEqual(merged.task("drop-1")?.status, .dropped)
        XCTAssertEqual(summary.updated, 0)
    }

    func testStatusAppliesOnlyWhenNotPinned() {
        let board = F.board(tasks: [F.task("pinned", "Task one", pinned: [.status]),
                                    F.task("free", "Task two")])
        let (merged, _) = merge(F.result(tasks: [F.planned("pinned", "Task one", status: .doing),
                                                 F.planned("free", "Task two", status: .waiting)]), board)
        XCTAssertEqual(merged.task("pinned")?.status, .todo)
        XCTAssertEqual(merged.task("free")?.status, .waiting)
    }

    func testKnownSessionLinkSurvivesARunThatNamesNone() {
        let board = F.board(tasks: [F.task("t", "Task", sessionId: "s1", cwd: "/Users/me/dev/atlas")])
        let (merged, _) = merge(F.result(tasks: [F.planned("t", "Task", sessionId: "")]), board)
        XCTAssertEqual(merged.task("t")?.sessionId, "s1")
        XCTAssertEqual(merged.task("t")?.cwd, "/Users/me/dev/atlas")

        let (relinked, _) = merge(F.result(tasks: [F.planned("t", "Task", sessionId: "s2", cwd: "/tmp")]), board)
        XCTAssertEqual(relinked.task("t")?.sessionId, "s2")
        XCTAssertEqual(relinked.task("t")?.cwd, "/tmp")
    }

    func testAdviceIsClearedWhenClaudeListsTheTaskAsOpenAgain() {
        let board = F.board(tasks: [F.task("t", "Task", status: .doing, pinned: [.status],
                                           advice: Advice(status: .done, reason: "looks done"))])
        let (merged, _) = merge(F.result(tasks: [F.planned("t", "Task", status: .doing)]), board)
        XCTAssertNil(merged.task("t")?.advice)
    }

    // MARK: Rule 4 — closings

    func testClosingAnUnpinnedTaskClosesIt() {
        let board = F.board(tasks: [F.task("atlas-pr", "Merge the PR into atlas", status: .doing)])
        let (merged, summary) = merge(F.result(closed: [.init(id: "atlas-pr", status: .done,
                                                              reason: "merged in c0ffee1")]), board)
        let t = try! XCTUnwrap(merged.task("atlas-pr"))
        XCTAssertEqual(t.status, .done)
        XCTAssertEqual(t.completedAt, F.now)
        XCTAssertEqual(t.closedReason, "merged in c0ffee1")
        XCTAssertNil(t.advice)
        XCTAssertEqual(summary.closed, 1)
    }

    func testClosingAsDroppedKeepsDropped() {
        let board = F.board(tasks: [F.task("ads", "Reconcile the Android ads")])
        let (merged, _) = merge(F.result(closed: [.init(id: "ads", status: .dropped, reason: "stale")]), board)
        XCTAssertEqual(merged.task("ads")?.status, .dropped)
    }

    func testClosingAPinnedTaskBecomesAdvice() {
        let board = F.board(tasks: [F.task("release", "Release 2.0", status: .doing, pinned: [.status])])
        let (merged, summary) = merge(F.result(closed: [.init(id: "release", status: .done, reason: "in the store")]),
                                      board)
        let t = try! XCTUnwrap(merged.task("release"))
        XCTAssertEqual(t.status, .doing)
        XCTAssertNil(t.completedAt)
        XCTAssertEqual(t.advice, Advice(status: .done, reason: "in the store"))
        XCTAssertEqual(summary.advised, 1)
        XCTAssertEqual(summary.closed, 0)
    }

    func testClosingUnknownOrClosedIdsIsIgnored() {
        let board = F.board(tasks: [F.task("old", "Old", status: .done, completedAt: F.now - F.day)])
        let (merged, summary) = merge(F.result(closed: [.init(id: "old", status: .dropped, reason: "x"),
                                                        .init(id: "ghost", status: .done, reason: "y")]), board)
        XCTAssertEqual(merged.task("old")?.status, .done)
        XCTAssertEqual(summary.closed, 0)
    }

    // MARK: Rule 5 — silence keeps things

    func testOpenTasksTheRunDoesNotMentionStayUnchanged() {
        var kept = F.task("kept", "The owner's task", area: "garden", when: .today, origin: .user, pinned: [.title])
        kept.plannedFor = Day(F.now - F.day)
        let (merged, _) = merge(F.result(tasks: [F.planned("other", "Another task")]), F.board(tasks: [kept]))
        XCTAssertEqual(merged.task("kept"), kept)
    }

    // MARK: Rule 6 — areas

    func testExistingAreaKeepsColorAndSymbolButTakesNewWeightAndStatus() {
        var changed = F.atlas
        changed.color = .blue
        changed.symbol = "globe"
        changed.weight = .background
        changed.status = "Waiting for review"
        let (merged, _) = merge(F.result(areas: [changed]), F.board())
        let a = try! XCTUnwrap(merged.area("atlas"))
        XCTAssertEqual(a.color, .coral)
        XCTAssertEqual(a.symbol, "iphone")
        XCTAssertEqual(a.weight, .background)
        XCTAssertEqual(a.status, "Waiting for review")
    }

    func testPlaceholderSymbolIsReplacedByTheRunsChoice() {
        var placeholder = F.move
        placeholder.symbol = Merge.placeholderSymbol
        let (merged, _) = merge(F.result(areas: [F.move]), F.board(areas: [placeholder]))
        XCTAssertEqual(merged.area("move")?.symbol, "airplane")
    }

    func testAreaMissingFromTheRunSurvivesParkedWhileItHasOpenTasks() {
        let board = F.board(tasks: [F.task("level", "Accept the winter level", area: "garden"),
                                    F.task("old", "Old", area: "move", status: .done, completedAt: F.now - F.day)])
        let (merged, _) = merge(F.result(areas: [F.atlas]), board)
        XCTAssertEqual(merged.areas.map(\.id), ["atlas", "garden"])
        XCTAssertEqual(merged.area("garden")?.weight, .parked)
        XCTAssertNil(merged.area("move"))
    }

    func testNewAreaGetsAColorNoOtherAreaUses() {
        let newcomer = F.area("studio", "Studio", color: .coral, symbol: "paintbrush.fill")
        let (merged, _) = merge(F.result(areas: [F.atlas, newcomer]), F.board(areas: [F.atlas]))
        XCTAssertEqual(merged.area("atlas")?.color, .coral)
        XCTAssertNotEqual(merged.area("studio")?.color, .coral)
    }

    func testInboxIsNeverStoredAsAnArea() {
        let (merged, _) = merge(F.result(areas: [F.atlas, Area.inbox]), F.board())
        XCTAssertFalse(merged.areas.contains { $0.id == Area.inboxID })
    }

    // MARK: Rule 7 — caps

    func testEveryTextIsClippedToItsCap() {
        let long = String(repeating: "a very long text ", count: 30)
        var area = F.atlas
        area.status = long
        area.outcome = long
        let board = F.board(tasks: [F.task("t", "Task")])
        let (merged, _) = merge(F.result(areas: [area],
                                         tasks: [F.planned("new", long, note: long)],
                                         closed: [.init(id: "t", status: .done, reason: long)],
                                         focus: long), board)
        let t = try! XCTUnwrap(merged.task("new"))
        XCTAssertLessThanOrEqual(t.title.count, 50)
        XCTAssertLessThanOrEqual(t.note.count, 140)
        XCTAssertLessThanOrEqual(merged.area("atlas")!.status.count, 80)
        XCTAssertLessThanOrEqual(merged.area("atlas")!.outcome.count, 70)
        XCTAssertLessThanOrEqual(merged.focus.count, 140)
        XCTAssertLessThanOrEqual(merged.task("t")!.closedReason!.count, 60)
        XCTAssertTrue(t.title.hasSuffix("…"))
    }

    func testCapCutsAtAWordBoundaryAndFlattensLines() {
        let text = "Tie up the move's loose ends: emails to the movers, Dana and the landlord, the bank"
        let capped = Merge.cap(text, 50)
        XCTAssertLessThanOrEqual(capped.count, 50)
        XCTAssertTrue(capped.hasSuffix("…"))
        let body = String(capped.dropLast())
        XCTAssertTrue(text.hasPrefix(body))
        XCTAssertEqual(text[text.index(text.startIndex, offsetBy: body.count)...].first.map { " ,".contains($0) }, true)
        XCTAssertEqual(Merge.cap("a line\nanother   line", 50), "a line another line")
    }

    /// Russian on purpose: ё and е are one letter to a reader, so a title differing only in it is the same task.
    func testNormalizedTitleIgnoresCasePunctuationAndYo() {
        XCTAssertEqual(Merge.normalizedTitle("Ещё раз: Влить PR!"), Merge.normalizedTitle("еще раз влить pr"))
    }

    // MARK: Rule 8–9 — pruning, ranks, metadata

    /// As long as the longest lookback: a task dropped 20 days ago is still swallowed when its sessions are read.
    func testClosedTasksOlderThanTheLookbackArePruned() {
        let board = F.board(tasks: [F.task("old", "Old", status: .done, completedAt: F.now - 31 * F.day),
                                    F.task("fresh", "Fresh", status: .dropped, completedAt: F.now - 20 * F.day),
                                    F.task("open", "Open", createdAt: F.now - 40 * F.day)])
        let (merged, _) = merge(F.result(), board)
        XCTAssertEqual(Set(merged.tasks.map(\.id)), ["fresh", "open"])
    }

    func testRanksFollowTheRunsOrder() {
        let board = F.board(tasks: [F.task("b", "Task B")])
        let (merged, _) = merge(F.result(tasks: [F.planned("a", "Task A"), F.planned("b", "Task B"),
                                                 F.planned("c", "Task C")]), board)
        XCTAssertEqual(merged.task("a")?.rank, 0)
        XCTAssertEqual(merged.task("b")?.rank, 1)
        XCTAssertEqual(merged.task("c")?.rank, 2)
    }

    func testBoardMetadataComesFromTheRun() {
        let (merged, _) = merge(F.result(focus: "The week's focus"), F.board())
        XCTAssertEqual(merged.focus, "The week's focus")
        XCTAssertEqual(merged.plannedAt, F.now)
        XCTAssertEqual(merged.model, "sonnet")
        XCTAssertEqual(merged.sessionCount, 119)
        XCTAssertEqual(merged.costUSD, 0.45)
        XCTAssertEqual(merged.version, Board.currentVersion)
    }
}
