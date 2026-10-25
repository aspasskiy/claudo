@testable import ClaudoCore
import XCTest

/// The answer decoding and the board section of the prompt — no model is ever called.
final class PlannerTests: XCTestCase {
    /// A trimmed `claude -p --output-format json --json-schema …` stdout, with the kinds of
    /// slips a tool-call answer can make: odd enums, a string estimate, a duplicate id, a stray "done".
    private let stdout = """
    {"type":"result","subtype":"success","is_error":false,"stop_reason":"tool_use","num_turns":2,
     "result":"{}","total_cost_usd":0.4512,
     "structured_output":{
      "focus":"Atlas and the move: release 2.0 and the quota, emails by 31.12. Garden with what's left.",
      "areas":[
        {"id":"atlas","name":"Atlas","symbol":"iphone","color":"coral","weight":"focus",
         "status":"Release 2.0 stuck","outcome":"A release without regressions"},
        {"id":"Move","name":"The move","symbol":"no.such.symbol","color":"turquoise","weight":"urgent",
         "status":"Emails not sent","outcome":"The bank answered on 31.12"},
        {"id":"","name":"Other","symbol":"tray.fill","color":"graphite","weight":"parked","status":"","outcome":""}
      ],
      "tasks":[
        {"id":"release","title":"Settle what goes into release 2.0","note":"Sort 50 files",
         "area":"atlas","status":"doing","priority":"urgent","when":"today","estimate":2.5,"sessionId":"5e55a0c1"},
        {"id":"move-mail","title":"Send the move's loose ends","note":"Dana, the landlord, the movers",
         "area":"Move","status":"waiting","priority":"P0","when":"today","estimate":"1,5","sessionId":"gone-session"},
        {"id":"release","title":"Duplicate","note":"","area":"atlas","status":"todo","priority":"high",
         "when":"week","estimate":1,"sessionId":""},
        {"id":"atlas-pr","title":"Merge the PR into atlas","note":"","area":"atlas","status":"done","priority":"high",
         "when":"today","estimate":1,"sessionId":""},
        {"id":"weird","title":"Odd fields","note":"","area":"misc","status":"blocked","priority":"whatever",
         "when":"someday","sessionId":""}
      ],
      "closed":[
        {"id":"old-ads","status":"dropped","reason":"no longer relevant"},
        {"id":"atlas-pr","status":"done","reason":"merged"},
        {"id":"landlord","status":"finished","reason":"email sent"}
      ]}}
    """

    private var sessions: [SessionDigest] {
        [F.session("5e55a0c1", cwd: "/Users/me/dev/atlas/app")]
    }

    func testDecodesAClaudeAnswerLeniently() throws {
        let result = try Planner.decode(stdout: Data(stdout.utf8), sessions: sessions, model: "sonnet", now: F.now)

        XCTAssertEqual(result.costUSD, 0.4512)
        XCTAssertEqual(result.model, "sonnet")
        XCTAssertEqual(result.sessionCount, 1)
        XCTAssertEqual(result.generatedAt, F.now)

        XCTAssertEqual(result.areas.map(\.id), ["atlas", "move", "other"])
        let move = result.areas[1]
        XCTAssertEqual(move.symbol, Merge.placeholderSymbol)
        XCTAssertNotNil(AreaColor(rawValue: move.color.rawValue))
        XCTAssertEqual(move.weight, .active)

        XCTAssertEqual(result.tasks.map(\.id), ["release", "move-mail", "weird"])
        let release = result.tasks[0]
        XCTAssertEqual(release.status, .doing)
        XCTAssertEqual(release.sessionId, "5e55a0c1")
        XCTAssertEqual(release.cwd, "/Users/me/dev/atlas/app")
        let mail = result.tasks[1]
        XCTAssertEqual(mail.area, "move")
        XCTAssertEqual(mail.priority, .urgent)
        XCTAssertEqual(mail.estimate, 1.5)
        XCTAssertEqual(mail.status, .waiting)
        XCTAssertEqual(mail.sessionId, "", "unknown sessions are dropped")
        XCTAssertNil(mail.cwd)
        let weird = result.tasks[2]
        XCTAssertEqual(weird.status, .todo)
        XCTAssertEqual(weird.priority, .medium)
        XCTAssertEqual(weird.when, .week)
        XCTAssertEqual(weird.estimate, 0)

        // The "done" task in the open list adds no second closing: the explicit one carries a reason.
        XCTAssertEqual(result.closed.map(\.id), ["old-ads", "atlas-pr", "landlord"])
        XCTAssertEqual(result.closed.map(\.status), [.dropped, .done, .done])
        XCTAssertEqual(result.closed[1].reason, "merged")
    }

    func testOfflineReplayKeepsSessionIdsAsGiven() throws {
        let answer = try JSONSerialization.data(withJSONObject:
            (JSONSerialization.jsonObject(with: Data(stdout.utf8)) as! [String: Any])["structured_output"]!)
        let result = try Planner.decode(answer: answer, sessions: nil, model: "opus", costUSD: nil, now: F.now)
        XCTAssertEqual(result.tasks[1].sessionId, "gone-session")
        XCTAssertNil(result.tasks[1].cwd)
    }

    func testErrorsAreReportedNotSwallowed() {
        func error(_ stdout: String) -> PlannerError? {
            do {
                _ = try Planner.decode(stdout: Data(stdout.utf8), sessions: [], model: "sonnet", now: F.now)
                return nil
            } catch {
                return error as? PlannerError
            }
        }
        XCTAssertEqual(error(#"{"type":"result","is_error":true,"result":"Usage limit reached"}"#),
                       .failed("Usage limit reached"))
        XCTAssertEqual(error(#"{"type":"result","is_error":false,"result":"I can't"}"#),
                       .noAnswer(what: "plan", result: "I can't"))
        let noAreas = #"{"is_error":false,"structured_output":{"focus":"x","areas":[],"tasks":[],"closed":[]}}"#
        XCTAssertEqual(error(noAreas), .emptyPlan)
        XCTAssertEqual(error("not json"), .exited(status: 0, output: "not json"))
    }

    /// The app words its error line by matching these texts (`Fmt.failure`).
    func testErrorTextsStayAsTheAppReadsThem() {
        let texts: [(PlannerError, String)] = [
            (.cliNotFound,
             "claude CLI not found (looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, ~/.claude/local)"),
            (.timedOut(who: "claude", timeout: 900), "claude didn't answer in 15 min"),
            (.timedOut(who: "Sonnet", timeout: 600), "Sonnet didn't answer in 10 min"),
            (.exited(status: 1, output: "Claude usage limit reached"), "claude exited 1: Claude usage limit reached"),
            (.failed("overloaded"), "claude: overloaded"),
            (.noAnswer(what: "summaries", result: "I can't"), "claude returned no summaries: I can't"),
            (.unreadablePlan("bad JSON"), "claude's plan didn't parse: bad JSON"),
            (.emptyPlan, "claude's plan has no areas"),
            (.noSummaries(model: "haiku"), "Haiku returned no summaries"),
            (.noSessions(days: 30), "No Claude sessions in the last 30 days"),
        ]
        for (error, text) in texts { XCTAssertEqual(error.localizedDescription, text) }
        XCTAssertEqual(PlannerError.failed(String(repeating: "x", count: 500)).localizedDescription.count,
                       "claude: ".count + 400 + 1, "long reports are clipped")
    }

    func testDecodedAnswerMergesCleanly() throws {
        let result = try Planner.decode(stdout: Data(stdout.utf8), sessions: sessions, model: "sonnet", now: F.now)
        let board = F.board(tasks: [F.task("atlas-pr", "Merge the PR into atlas", status: .doing),
                                    F.task("old-ads", "Reconcile the ads")])
        let (merged, summary) = Merge.merge(result, into: board, now: F.now)
        XCTAssertEqual(merged.task("atlas-pr")?.status, .done)
        XCTAssertEqual(merged.task("atlas-pr")?.closedReason, "merged")
        XCTAssertEqual(merged.task("old-ads")?.status, .dropped)
        XCTAssertEqual(merged.task("weird")?.area, Area.inboxID, "misc isn't an area id here: the slug is other")
        XCTAssertEqual(summary.added, 3)
        XCTAssertEqual(summary.closed, 2)
    }

    // MARK: Prompt

    func testBoardSectionShowsWhatTheModelMustRespect() {
        var board = F.board(tasks: [
            F.task("release", "Settle what goes into release 2.0", status: .doing, priority: .urgent, when: .today,
                   estimate: 2.5, pinned: [.status, .when], sessionId: "5e55a0c1"),
            F.task("u-1", "buy tickets", area: Area.inboxID, origin: .user, pinned: [.title, .when]),
            F.task("advised", "Fix the quota", status: .doing, pinned: [.status],
                   advice: Advice(status: .done, reason: "merged")),
            F.task("closed-owner", "Email Dana", status: .done, pinned: [.status],
                   completedAt: F.now - F.day),
            F.task("dropped-owner", "Check the ads", status: .dropped, pinned: [.status], completedAt: F.now - 2 * F.day),
            F.task("ancient", "Very old", status: .done, completedAt: F.now - 35 * F.day),
        ])
        board.tasks[3].closedReason = "email sent"
        let text = Planner.boardSection(board, now: F.now)

        XCTAssertTrue(text.contains("Focus: The old focus"))
        XCTAssertTrue(text.contains("- id=atlas \"Atlas\" symbol=iphone color=coral weight=focus"))
        XCTAssertTrue(text.contains("by the end of the week: Release 2.0 without regressions"))
        XCTAssertTrue(text.contains("- id=release [doing*] when=today* priority=urgent 2.5h area=atlas "
                                    + "\"Settle what goes into release 2.0\""))
        XCTAssertTrue(text.contains("session=5e55a0c1"))
        XCTAssertTrue(text.contains("area=inbox from the owner \"buy tickets\""))
        XCTAssertTrue(text.contains("advice \"done\" awaits the owner's decision: merged"))
        XCTAssertTrue(text.contains("## Closed in the last 30 days — don't suggest again"))
        XCTAssertTrue(text.contains("id=closed-owner [done by the owner"))
        XCTAssertTrue(text.contains("\"Email Dana\" — email sent"))
        XCTAssertTrue(text.contains("id=dropped-owner [dropped by the owner"))
        XCTAssertFalse(text.contains("Very old"))
    }

    func testOldSessionsAreBriefRecentOnesInFull() {
        let now = F.now
        func session(_ id: String, daysAgo: Double, prompts: [String]) -> SessionDigest {
            let end = now - daysAgo * 86400
            return SessionDigest(id: id, cwd: "/Users/me/dev/atlas", folder: FileManager.default.temporaryDirectory,
                                 title: "Session \(id)", start: end - 3600, end: end, prompts: prompts,
                                 lastReply: String(repeating: "done ", count: 200), awaitingReply: false)
        }
        let sessions = [
            session("recent", daysAgo: 2, prompts: ["first", "second", "third"]),
            session("old", daysAgo: 20, prompts: ["the old goal", "after that", "more"]),
            session("errand", daysAgo: 25, prompts: ["a quick question"]),
        ]
        let text = Planner(days: 30).digest(sessions: sessions, board: .empty, now: now)

        XCTAssertTrue(text.contains("the last 30 days, 3 sessions: 1 from the last 7 days in full, 2 older in brief."))
        XCTAssertTrue(text.contains("(sessions / prompts over 7 days · over 30 days; last session)"))
        // Recent: every prompt and the long reply. Old: the goal and a short outcome only.
        let recent = text.range(of: "session=recent")!, old = text.range(of: "session=old")!
        XCTAssertLessThan(recent.lowerBound, text.range(of: "# Sessions older than 7 days")!.lowerBound)
        XCTAssertTrue(text.contains("> second"))
        XCTAssertTrue(text.contains("> the old goal"))
        XCTAssertFalse(text.contains("> after that"))
        let oldBlock = text[old.lowerBound...].prefix { $0 != "#" }
        XCTAssertTrue(oldBlock.contains("· 3 prompts"))
        XCTAssertLessThan(oldBlock.count, 450)
        let errand = text[text.range(of: "session=errand")!.lowerBound...]
        XCTAssertLessThan(errand.count, 300)
    }

    func testEmptyBoardAsksForAFirstPlan() {
        XCTAssertTrue(Planner.boardSection(.empty, now: F.now).contains("The board is empty"))
    }

    func testSchemaIsValidJSONAndListsTheContractEnums() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Planner.answerSchema.utf8)) as? [String: Any])
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(props.keys), ["focus", "areas", "tasks", "closed"])
        let area = ((props["areas"] as! [String: Any])["items"] as! [String: Any])["properties"] as! [String: Any]
        XCTAssertEqual((area["symbol"] as! [String: Any])["enum"] as! [String], Area.symbols)
        XCTAssertEqual((area["color"] as! [String: Any])["enum"] as! [String], AreaColor.allCases.map(\.rawValue))
    }

    /// Russian on purpose: a name in another script still gets a Latin id.
    func testSlugMakesLatinIds() {
        XCTAssertEqual(Planner.slug("Переезд на море"), "pereezd-na-more")
        XCTAssertEqual(Planner.slug("Move"), "move")
        XCTAssertEqual(Planner.slug("atlas_web v2"), "atlas_web-v2")
    }
}
