@testable import ClaudoCore
@testable import Claudo
import SwiftUI
import XCTest

/// The popover's one list and its filters: every open task sits in one horizon (Today, This week, Later) by
/// when it is for, the filter picks horizons, and areas, kinds, statuses and priority narrow the rows.
final class FilterTests: XCTestCase {
    let now = Date()
    let known: Set<String> = ["atlas", "lumen"]

    private func task(_ id: String, area: String = "atlas", kind: TaskKind = .task, status: TaskStatus = .todo,
                      priority: Priority = .medium, when: When = .week, due: Day? = nil, rank: Int = 0) -> TaskItem {
        var t = TaskItem(id: id, title: id, area: area, status: status, origin: .claude, createdAt: now, kind: kind)
        t.priority = priority
        t.when = when
        t.due = due
        t.rank = rank
        return t
    }

    func testEmptyFilterKeepsEverything() {
        let filter = BoardFilter()
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.passes(task("a"), areas: known))
        XCTAssertTrue(filter.passes(task("b", area: "gone", kind: .decision), areas: known))
    }

    func testAreasKeepTheirRowsAndTheInboxTakesVanishedAreas() {
        let filter = BoardFilter(areas: ["atlas", Area.inboxID])
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.passes(task("a", area: "atlas"), areas: known))
        XCTAssertFalse(filter.passes(task("b", area: "lumen"), areas: known))
        XCTAssertTrue(filter.passes(task("c", area: Area.inboxID), areas: known))
        XCTAssertTrue(filter.passes(task("d", area: "gone"), areas: known), "an unknown area files under the inbox")
    }

    func testEveryPartCombines() {
        let filter = BoardFilter(areas: ["lumen"], kind: .task, statuses: [.doing, .waiting], important: true)
        XCTAssertTrue(filter.passes(task("a", area: "lumen", status: .doing, priority: .high), areas: known))
        XCTAssertTrue(filter.passes(task("b", area: "lumen", status: .waiting, priority: .urgent), areas: known))
        XCTAssertFalse(filter.passes(task("c", area: "lumen", status: .todo, priority: .high), areas: known), "not started")
        XCTAssertFalse(filter.passes(task("d", area: "lumen", status: .doing, priority: .medium), areas: known), "not important")
        XCTAssertFalse(filter.passes(task("e", area: "lumen", kind: .decision, status: .doing, priority: .high), areas: known))
        XCTAssertFalse(filter.passes(task("f", area: "atlas", status: .doing, priority: .high), areas: known))
    }

    func testRoundTripsThroughJSON() throws {
        let filter = BoardFilter(areas: ["atlas"], kind: .task, statuses: [.waiting], important: true)
        let decoded = try JSONDecoder().decode(BoardFilter.self, from: JSONEncoder().encode(filter))
        XCTAssertEqual(decoded, filter)
    }

    /// Today, This week and Later are part of the filter: they make it active and are saved with it, but they
    /// don't narrow the rows inside a horizon (Today keeps its lead card).
    func testHorizonsAreAFilterPartThatDoesntNarrowTheRows() throws {
        let filter = BoardFilter(when: [.today])
        XCTAssertTrue(filter.isActive)
        XCTAssertFalse(filter.narrows)
        XCTAssertTrue(filter.passes(task("a", when: .week), areas: known), "the store, not `passes`, places a row")
        let decoded = try JSONDecoder().decode(BoardFilter.self, from: JSONEncoder().encode(filter))
        XCTAssertEqual(decoded, filter)
    }

    /// The build before statuses and priority saved only areas and kind: it still reads, keeping the rest open.
    func testAnOlderSavedFilterStillReads() throws {
        let old = Data(#"{"areas":["atlas"],"kind":"decision"}"#.utf8)
        let decoded = try JSONDecoder().decode(BoardFilter.self, from: old)
        XCTAssertEqual(decoded, BoardFilter(areas: ["atlas"], kind: .decision))
        XCTAssertEqual(try JSONDecoder().decode(BoardFilter.self, from: Data("{}".utf8)), BoardFilter())
    }

    /// Where a task sits depends on when it is for, never on its status or kind: a decision, work under way
    /// and work on someone else sit in This week or Later like the rest; due today puts anything on Today.
    @MainActor
    func testEveryOpenTaskSitsInOneHorizonByWhenItIsFor() {
        let store = Store(fixture: URL(fileURLWithPath: "/dev/null"))
        let today = Day(Date())
        var board = Board()
        board.tasks = [
            task("plan", when: .today),
            task("due", when: .later, due: today),
            task("call", kind: .decision, when: .week),
            task("doing", status: .doing, when: .week),
            task("waiting", status: .waiting, when: .week, due: today.adding(days: 2)),
            task("someday", when: .later),
            task("closed", status: .done, when: .week),
        ]
        store.replaceBoard(board)
        XCTAssertEqual(Set(store.openToday.map(\.id)), ["plan", "due"])
        XCTAssertEqual(Set(store.weekTasks.map(\.id)), ["call", "doing", "waiting"])
        XCTAssertEqual(store.laterTasks.map(\.id), ["someday"])
    }

    @MainActor
    func testThisWeekPutsTheMostImportantFirstThenThePlansOrder() {
        let store = Store(fixture: URL(fileURLWithPath: "/dev/null"))
        var board = Board()
        board.tasks = [
            task("low", priority: .low, rank: 0),
            task("high-2", priority: .high, rank: 2),
            task("urgent", priority: .urgent, rank: 9),
            task("high-1", priority: .high, rank: 1),
        ]
        store.replaceBoard(board)
        XCTAssertEqual(store.weekTasks.map(\.id), ["urgent", "high-1", "high-2", "low"])
    }

    @MainActor
    func testHorizonsInTheFilterToggleAndTheLastOneOffShowsEverything() {
        let store = Store(fixture: URL(fileURLWithPath: "/dev/null"))
        XCTAssertTrue(Store.Horizon.allCases.allSatisfy(store.shows), "no horizon picked: the whole list")
        store.toggleHorizon(.today)
        XCTAssertEqual(store.horizons, [.today])
        XCTAssertFalse(store.shows(.later))
        store.toggleHorizon(.week)
        XCTAssertTrue(store.shows(.today) && store.shows(.week) && !store.shows(.later))
        store.toggleHorizon(.later)
        XCTAssertEqual(store.horizons, [], "all three on is no filter at all")
        store.toggleHorizon(.later)
        store.toggleHorizon(.later)
        XCTAssertEqual(store.horizons, [], "the last one off shows everything again")
    }

    @MainActor
    func testQuickAddGoesOnTopOfTheFirstGroupListedInTheOneAreaFiltered() {
        let store = Store(fixture: URL(fileURLWithPath: "/dev/null"))
        store.startAdding()
        XCTAssertEqual(store.adding, Store.AddTarget(area: nil, when: .today))
        store.toggleHorizon(.week)
        store.startAdding()
        XCTAssertEqual(store.adding, Store.AddTarget(area: nil, when: .week))
        store.toggleHorizon(.week)
        store.toggleHorizon(.later)
        store.toggleFilterArea("atlas")
        store.startAdding()
        XCTAssertEqual(store.adding, Store.AddTarget(area: "atlas", when: .later))
        XCTAssertTrue(store.showLater, "Later opens to show the new row")
        store.toggleFilterArea("lumen")
        store.startAdding()
        XCTAssertEqual(store.adding?.area, nil, "two areas named: the inbox")
    }

    /// The chip line's layouts each have an id of their own: ViewThatFits traps on a repeat, and it reaches the
    /// compact ones exactly when an area chip and every flag chip overflow the line.
    func testTheChipLinesLayoutsNeverShareAnID() {
        for (areas, flags) in [(0, 0), (1, 0), (0, 3), (1, 4), (2, 4), (5, 1)] {
            let fits = FilterChips.fits(areas: areas, flags: flags)
            XCTAssertEqual(Set(fits).count, fits.count, "\(areas) areas, \(flags) flags")
            XCTAssertEqual(fits.first, .areas(areas), "every area chip shown comes first")
        }
    }

    /// One area, a horizon and every flag chip on: too long for the line in either language, so the line ends
    /// up on its compact layouts. It draws instead of trapping.
    @MainActor
    func testAnOverflowingChipLineDraws() {
        let store = Store(fixture: URL(fileURLWithPath: "/dev/null"))
        store.replaceBoard(Board(areas: [Area(id: "atlas", name: "Atlas", symbol: "folder.fill", color: .blue,
                                              weight: .focus, status: "", outcome: "")]))
        store.toggleHorizon(.today)
        store.toggleFilterArea("atlas")
        store.setFilterKind(.decision)
        store.toggleFilterStatus(.doing)
        store.toggleFilterStatus(.waiting)
        store.setFilterImportant(true)
        for language in [AppLanguage.english, .russian] {
            store.language = language
            let line = FilterChips().environmentObject(store).frame(width: Metrics.popoverWidth)
            XCTAssertNotNil(ImageRenderer(content: line).cgImage, "\(language)")
        }
        store.language = .english
    }
}
