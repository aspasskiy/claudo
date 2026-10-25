@testable import ClaudoCore
@testable import Claudo
import XCTest

/// The list's three views: Schedule, Projects, Priority. The same rows in each, in the list's own order inside
/// every group (Today's first), and the filter — horizons included — narrows them all alike.
final class GroupingTests: XCTestCase {
    let now = Date()

    private func area(_ id: String, weight: Weight = .active) -> Area {
        Area(id: id, name: id.capitalized, symbol: "folder.fill", color: .blue, weight: weight, status: "", outcome: "")
    }

    private func task(_ id: String, area: String = "atlas", priority: Priority = .medium, when: When = .week,
                      kind: TaskKind = .task, rank: Int = 0) -> TaskItem {
        var t = TaskItem(id: id, title: id, area: area, status: .todo, origin: .claude, createdAt: now, kind: kind)
        t.priority = priority
        t.when = when
        t.rank = rank
        return t
    }

    private func row(_ t: TaskItem, _ horizon: Store.Horizon) -> ListGroups.Row {
        ListGroups.Row(task: t, horizon: horizon)
    }

    func testByAreaFollowsTheAreasWithTheInboxLastAndKeepsTheRowsOrder() {
        let rows = [
            row(task("a", area: "lumen"), .today),
            row(task("b", area: "atlas"), .today),
            row(task("c", area: "gone"), .week),
            row(task("d", area: "lumen"), .week),
            row(task("e", area: Area.inboxID), .later),
            row(task("f", area: "lumen"), .later),
        ]
        let groups = ListGroups.byArea(rows, areas: [area("atlas", weight: .focus), area("lumen"), area("mosaic")])
        XCTAssertEqual(groups.map(\.id), ["area-atlas", "area-lumen", "area-inbox"], "an area with nothing listed steps aside")
        XCTAssertEqual(groups[1].rows.map(\.id), ["a", "d", "f"], "today's, then this week's, then later's")
        XCTAssertEqual(groups[2].rows.map(\.id), ["c", "e"], "the inbox takes the rows of areas the board no longer has")
    }

    func testByPriorityGoesUrgentToLowAndKeepsTodayFirstInEach() {
        let rows = [
            row(task("a", priority: .high, when: .today), .today),
            row(task("b", priority: .low, when: .today), .today),
            row(task("c", priority: .high), .week),
            row(task("d", priority: .urgent), .week),
            row(task("e", priority: .high, when: .later), .later),
        ]
        let groups = ListGroups.byPriority(rows)
        XCTAssertEqual(groups.map(\.id), ["priority-urgent", "priority-high", "priority-low"])
        XCTAssertEqual(groups[1].rows.map(\.id), ["a", "c", "e"])
        XCTAssertEqual(groups[1].rows.map(\.horizon), [.today, .week, .later])
    }

    @MainActor
    private func store(_ tasks: [TaskItem]) -> Store {
        let store = Store(fixture: URL(fileURLWithPath: "/nonexistent/board.json"))
        store.replaceBoard(Board(areas: [area("atlas", weight: .focus), area("lumen")], tasks: tasks, plannedAt: now))
        return store
    }

    @MainActor
    func testEveryViewListsTheSameRowsAndTheChipsAndFilterNarrowThemAll() {
        let store = store([
            task("today-lumen", area: "lumen", priority: .high, when: .today),
            task("week-atlas", priority: .high),
            task("later-lumen", area: "lumen", priority: .low, when: .later),
            task("call-atlas", priority: .medium, kind: .decision),
        ])
        XCTAssertEqual(store.grouping, .date, "a fixture store opens by date")
        XCTAssertEqual(store.listedGroups, [], "the date view doesn't regroup")
        let all = Set(store.listedRows.map(\.id))
        XCTAssertEqual(all.count, 4)

        store.setGrouping(.project)
        XCTAssertEqual(store.listedGroups.map(\.id), ["area-atlas", "area-lumen"])
        XCTAssertEqual(Set(store.listedGroups.flatMap(\.rows).map(\.id)), all)
        XCTAssertEqual(store.listedGroups[1].rows.map(\.horizon), [.today, .later])

        store.setGrouping(.priority)
        XCTAssertEqual(store.listedGroups.map(\.id), ["priority-high", "priority-medium", "priority-low"])
        XCTAssertEqual(store.listedGroups[0].rows.map(\.id), ["today-lumen", "week-atlas"])

        store.toggleHorizon(.today)
        XCTAssertEqual(store.listedGroups.flatMap(\.rows).map(\.id), ["today-lumen"], "picking Today in the filter narrows this view too")
        store.showAllHorizons()
        store.setFilterKind(.decision)
        XCTAssertEqual(store.listedGroups.flatMap(\.rows).map(\.id), ["call-atlas"], "and so does the filter")
        store.setFilterKind(nil)
        store.toggleFilterArea("lumen")
        store.setGrouping(.project)
        XCTAssertEqual(store.listedGroups.map(\.id), ["area-lumen"])
    }

    @MainActor
    func testSwitchingViewsClosesWhatWasOpenAndKeepsTheFilter() {
        let store = store([task("a")])
        store.toggleHorizon(.week)
        store.expanded = "a"
        store.startAdding()
        store.setGrouping(.project)
        XCTAssertEqual(store.grouping, .project)
        XCTAssertNil(store.expanded)
        XCTAssertNil(store.adding)
        XCTAssertEqual(store.horizons, [.week], "This week stays picked in the next view")
    }
}
