@testable import ClaudoCore
import XCTest

/// Runs against a temp dir: the real data dir is never touched.
final class BoardStoreTests: XCTestCase {
    private var dir: URL!
    private var saved: URL!

    override func setUp() {
        saved = BoardStore.directory
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudo-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BoardStore.directory = dir
    }

    override func tearDown() {
        BoardStore.directory = saved
        try? FileManager.default.removeItem(at: dir)
    }

    func testEmptyDataDirGivesAnEmptyBoard() {
        let board = BoardStore.load()
        XCTAssertTrue(board.areas.isEmpty)
        XCTAssertTrue(board.tasks.isEmpty)
    }

    func testUnreadableBoardIsKeptAsideAndNotLost() throws {
        try "{ not json".write(to: dir.appendingPathComponent("board.json"), atomically: true, encoding: .utf8)
        let board = BoardStore.load()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("board.unreadable-") })
        XCTAssertTrue(board.tasks.isEmpty, "the app starts empty")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("board.json"), encoding: .utf8), "{ not json",
                       "loading never writes")
    }

    func testSaveAndLoadRoundTrip() throws {
        var board = F.board(tasks: [F.task("a", "A", pinned: [.status, .when], sessionId: "s", cwd: "/x",
                                           advice: Advice(status: .done, reason: "done"))])
        board.add(title: "The owner's own task", when: .today, now: F.now)
        try BoardStore.save(board)
        let loaded = BoardStore.load()
        XCTAssertEqual(loaded.tasks, board.tasks)
        XCTAssertEqual(loaded.areas, board.areas)
        XCTAssertEqual(loaded.focus, board.focus)
    }
}
