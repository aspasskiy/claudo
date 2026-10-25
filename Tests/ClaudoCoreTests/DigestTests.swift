@testable import ClaudoCore
import XCTest

/// The digest and the answer: the owner's day, dated board facts, git, live sessions, slim older notes,
/// and why / due / kind / attention coming back. No model and no git: repos come canned.
final class DigestTests: XCTestCase {
    /// Local wall-clock times on a given day, whatever zone the tests run in.
    private func at(_ day: Day, _ hour: Int, _ minute: Int = 0) -> Date {
        day.date().addingTimeInterval(Double(hour * 3600 + minute * 60))
    }

    private let saturday = Day(year: 2026, month: 10, day: 24)

    /// `working`: the agent went on with tools after its last text (the turn is open without awaiting).
    private func session(_ id: String, end: Date, prompts: [String] = ["do it"], awaiting: Bool = false,
                         cwd: String = "/Users/me/dev/app", title: String? = "A session",
                         lastRecord: Date? = nil, working: Bool = false) -> SessionDigest {
        SessionDigest(id: id, cwd: cwd, folder: FileManager.default.temporaryDirectory, title: title,
                      start: end - 600, end: end, prompts: prompts, lastReply: awaiting ? "" : "finished",
                      awaitingReply: awaiting, lastRecord: lastRecord, turnOpen: awaiting || working)
    }

    // MARK: The owner's day

    func testTheFirstLineSaysTheDayAndTheHoursLeft() {
        let saturdayMorning = at(saturday, 11)
        let first = Planner(days: 30).digest(sessions: [], board: .empty, now: saturdayMorning)
            .split(separator: "\n")[0]
        XCTAssertTrue(first.hasPrefix("Now: 2026-10-24 11:00, Saturday — weekend"), String(first))
        XCTAssertTrue(first.hasSuffix("≈ 12 h left in the owner's day (until ~23:00)."), String(first))

        let monday = Planner(days: 30).digest(sessions: [], board: .empty, now: at(saturday.adding(days: 2), 9))
        XCTAssertTrue(monday.hasPrefix("Now: 2026-10-26 09:00, Monday — workday"))

        XCTAssertEqual(Planner.hoursLeft(at(saturday, 5)), 16, "the day starts ~07:00")
        XCTAssertEqual(Planner.hoursLeft(at(saturday, 20, 30)), 3)
        XCTAssertEqual(Planner.hoursLeft(at(saturday, 22, 50)), 1)
        XCTAssertEqual(Planner.hoursLeft(at(saturday, 23, 40)), 1, "never below one")
    }

    // MARK: Live sessions

    func testASessionThatMovedLessThanTwoHoursAgoIsGoingNotCutOff() {
        let now = at(saturday, 11)
        let sessions = [
            session("asked", end: now - 1800, awaiting: true),
            session("busy", end: now - 5 * 3600, awaiting: true, lastRecord: now - 1200),
            session("dead", end: now - 5 * 3600, awaiting: true, lastRecord: now - 5 * 3600 + 60),
            session("answered", end: now - 1800, lastRecord: now - 1800),
            session("running", end: now - 1800, lastRecord: now - 60, working: true),
        ]
        let text = Planner(days: 30).digest(sessions: sessions, board: .empty, now: now)
        func header(_ id: String) -> Substring {
            text[text.range(of: "## session=\(id)")!.lowerBound...].prefix { $0 != "\n" }
        }
        XCTAssertTrue(header("asked").hasSuffix("· running now"))
        XCTAssertTrue(header("busy").hasSuffix("· running now"), "a long agent run writes no text until done")
        XCTAssertTrue(header("dead").hasSuffix("· CUT OFF: the last prompt got no reply"))
        XCTAssertFalse(header("asked").contains("CUT OFF"))
        XCTAssertTrue(header("answered").hasSuffix("· 1 prompt"), "answered half an hour ago: finished, not going")
        XCTAssertTrue(header("running").hasSuffix("· running now"), "a text on the way doesn't end the run")
    }

    func testTheBoardSaysGoingOnlyWhileAnAgentWorksOnTheOwnersLastPrompt() {
        let now = at(saturday, 11)
        let ids = ["aaaaaaaa-1", "bbbbbbbb-2"]
        let sessions = [session(ids[0], end: now - 1800, awaiting: true),
                        session(ids[1], end: now - 1800, lastRecord: now - 1800)]
        let board = F.board(tasks: [F.task("busy", "Going", sessionId: ids[0]), F.task("done", "Done", sessionId: ids[1])])
        let text = Planner.boardSection(board, now: now, sessions: sessions)
        XCTAssertTrue(text.contains("session=aaaaaaaa (running now)"))
        XCTAssertTrue(text.contains("session=bbbbbbbb (last active \(DigestFormat.short(now - 1800)))"))
    }

    // MARK: Board

    func testEveryTaskCarriesItsAgeItsStretchOnTodayAndItsSession() {
        let now = at(saturday, 11)
        let today = saturday
        let sourceID = "abcdef12-3456-7890-abcd-ef1234567890"
        let source = session(sourceID, end: at(today.adding(days: -3), 14, 5))
        var carried = F.task("carried", "Merge the fix into main?", when: .today,
                             createdAt: at(today.adding(days: -6), 10), sessionId: sourceID)
        carried.kind = .decision
        carried.why = "Branch idle a week"
        carried.plannedFor = today.adding(days: -1)
        carried.todaySince = today.adding(days: -5)
        carried.due = today.adding(days: 2)
        carried.pinned = [.due]
        var fresh = F.task("fresh", "Walk the path from an ad to payment", when: .today, createdAt: at(today, 9))
        fresh.plannedFor = today
        fresh.todaySince = today
        var board = F.board(tasks: [carried, fresh])
        board.plannedAt = at(today.adding(days: -1), 16, 12)

        let text = Planner.boardSection(board, now: now, sessions: [source])
        XCTAssertTrue(text.contains("Last run: 2026-10-23 16:12, Friday. The focus, the areas' statuses and outcomes, "
                                    + "the notes and \"why\" below are its text: recheck"))
        XCTAssertTrue(text.contains("## Areas (status and outcome from the last run)"))
        XCTAssertTrue(text.contains("area=atlas kind=decision \"Merge the fix into main?\" — A note"
                                    + " · why: Branch idle a week · created 18.10 · on Today since 19.10 (day 6),"
                                    + " carried over from the plan of 23.10 · due* 2026-10-26"
                                    + " · session=abcdef12 (last active 21.10 14:05)\n"), text)
        XCTAssertTrue(text.contains("\"Walk the path from an ad to payment\" — A note · created 24.10"
                                    + " · on Today since 24.10 (day 1)\n"), text)
        XCTAssertFalse(text.contains(sourceID), "the digest names sessions by their short id")
    }

    func testAWaitingTaskOnTodayByItsDueSaysSo() {
        var waiting = F.task("w", "Wait for the bank's answer", status: .waiting, when: .week)
        waiting.due = saturday
        let text = Planner.boardSection(F.board(tasks: [waiting]), now: at(saturday, 11))
        XCTAssertTrue(text.contains("[waiting] when=week"))
        XCTAssertTrue(text.contains("· due 2026-10-24"), "the year rides along, so the model can write it back")
        XCTAssertFalse(text.contains("on Today since"), "due-promoted isn't a stretch on Today")
    }

    func testAWhenChoiceIsStarredOnlyOnTheDayItBinds() {
        let now = at(saturday, 11)
        var board = F.board(tasks: [F.task("yesterday-on", "Onto Today yesterday"),
                                    F.task("yesterday-off", "Not today, yesterday", when: .today),
                                    F.task("now-on", "Onto Today today"), F.task("later", "Later"),
                                    F.task("legacy", "An old pin", pinned: [.when])])
        board.setWhen("yesterday-on", .today, now: now - F.day)
        board.setWhen("yesterday-off", .week, now: now - F.day)
        board.setWhen("now-on", .today, now: now - 60)
        board.setWhen("later", .later, now: now - 3 * F.day)
        let text = Planner.boardSection(board, now: now)
        func line(_ id: String) -> Substring {
            text[text.range(of: "- id=\(id) ")!.lowerBound...].prefix { $0 != "\n" }
        }
        XCTAssertTrue(line("yesterday-on").contains("when=today priority"), "yesterday's choice is the plan's to redo")
        XCTAssertTrue(line("yesterday-off").contains("when=week priority"))
        XCTAssertTrue(line("now-on").contains("when=today* priority"))
        XCTAssertTrue(line("later").contains("when=later* priority"), "Later sticks")
        XCTAssertTrue(line("legacy").contains("when=week* priority"), "a pin without a day holds")
    }

    func testASnoozeIsShownUntilItsDay() {
        let now = at(saturday, 11)
        var board = F.board(tasks: [F.task("parcel", "Send the papers", when: .week),
                                    F.task("old", "Old", when: .week)])
        board.tasks[0].due = saturday
        board.tasks[1].due = saturday.adding(days: -2)
        board.notToday("parcel", now: now)
        board.tasks[1].snoozedUntil = saturday
        let text = Planner.boardSection(board, now: now)
        XCTAssertTrue(text.contains(" · due 2026-10-24 · snoozed by the owner until 25.10\n"), text)
        XCTAssertEqual(text.components(separatedBy: "snoozed").count, 2, "a snooze that ran out says nothing")
    }

    // MARK: Activity, git, older notes

    func testActivityIsByLaunchFolderAndCapped() {
        let now = at(saturday, 11)
        let sessions = (0..<20).map { session("s\($0)", end: now - Double($0 + 3) * 3600, cwd: "/Users/me/dev/p\($0)") }
        let text = Planner(days: 30).digest(sessions: sessions, board: .empty, now: now)
        XCTAssertTrue(text.contains("# Activity by launch folder — the topic may differ"))
        let rows = text.split(separator: "\n").filter { $0.hasPrefix("- /Users/me/dev/p") }
        XCTAssertEqual(rows.count, 15)
        XCTAssertTrue(text.contains("- …5 more folders: 5 / 5\n"))
    }

    func testReposComeAsALineEach() {
        let repo = RepoState(root: "/Users/me/dev/app", branch: "main", dirty: 3, unpushed: 1,
                             lastCommit: at(saturday, 9, 30), lastSubject: "Fix checkout")
        let text = Planner(days: 30).digest(sessions: [], board: .empty, now: at(saturday, 11), repos: [repo])
        XCTAssertTrue(text.contains("# Repository state"))
        XCTAssertTrue(text.contains("- /Users/me/dev/app · main · uncommitted: 3 · unpushed: 1 · commit 24.10 09:30 "
                                    + "\"Fix checkout\"\n"))
        XCTAssertFalse(Planner(days: 30).digest(sessions: [], board: .empty, now: at(saturday, 11))
            .contains("# Repository state"))
    }

    func testOlderNotesShrinkToOneLineAndKeepOnlyWhatStillMatters() {
        let now = at(saturday, 11)
        let old = now - 12 * F.day
        let sessions = [
            session("recent", end: now - F.day, prompts: ["a", "b"], title: "Fresh"),
            session("done", end: old, title: "Finished"),
            session("open", end: old - 3600, prompts: ["a", "b", "c"], awaiting: true, title: "Unfinished"),
            session("minor", end: old - 7200, title: "Minor"),
            session("bill", end: old - 9000, title: "Invoice"),
            session("trivial", end: old - 9600, title: "Trifle"),
        ]
        var report = CompactReport()
        report.summaries["recent"] = SessionSummary(summary: "Fresh work", state: .inProgress, importance: 3,
                                                    open: ["Finish it off"])
        report.summaries["done"] = SessionSummary(summary: "All finished", state: .done, importance: 4,
                                                  open: ["Answer the ticket.", "Proofread the FAQ"])
        report.summaries["trivial"] = SessionSummary(summary: "A trifle finished", state: .done, importance: 1,
                                                     open: ["Glance at the logo again"])
        report.summaries["open"] = SessionSummary(summary: "Started", state: .inProgress, importance: 3,
                                                  open: ["Send the email.", "Check the totals"])
        report.summaries["minor"] = SessionSummary(summary: "A trifle", state: .inProgress, importance: 1,
                                                   open: ["Rename the tiny icon"])
        report.summaries["bill"] = SessionSummary(summary: "Invoice", state: .done, importance: 2,
                                                  open: ["Pay the invoice"])
        let text = Planner(days: 30).digest(sessions: sessions, board: .empty, now: now, compact: report)

        XCTAssertTrue(text.contains("Summary: Fresh work\nOpen: Finish it off\n"), "the week keeps full notes")
        XCTAssertTrue(text.contains("- \(DigestFormat.day(old)) · dev/app · \"Finished\" · 1 prompt · done · 4/4"
                                    + " · session=done\n  Open: Answer the ticket\n"),
                      "a finished goal can leave something owed: the summarizer puts it first")
        XCTAssertFalse(text.contains("Proofread the FAQ"), "a done session shows only its first item")
        XCTAssertFalse(text.contains("Glance at the logo again"), "a trivial done session shows nothing")
        XCTAssertTrue(text.contains("\"Open\" at importance 2+, for a done one only its first item"))
        XCTAssertTrue(text.contains("\"Unfinished\" · 3 prompts · in progress · 3/4 · CUT OFF · session=open\n"
                                    + "  Open: Send the email; Check the totals\n"))
        XCTAssertFalse(text.contains("Rename the tiny icon"), "importance below 2 stays out")
        XCTAssertTrue(text.contains("\"Invoice\" · 1 prompt · done · 2/4 · session=bill\n  Open: Pay the invoice\n"))
        XCTAssertFalse(text.contains("Summary: All finished"))
    }

    // MARK: The answer

    private func answer(tasks: String, areas: String? = nil) -> Data {
        let areaList = areas ?? #"[{"id":"app","name":"App","symbol":"cube.fill","color":"blue","weight":"focus","status":"","outcome":"","attention":52}]"#
        return Data(#"{"focus":"Focus","areas":\#(areaList),"tasks":\#(tasks),"closed":[]}"#.utf8)
    }

    func testTheAnswerCarriesWhyDueKindAndAttention() throws {
        let now = at(saturday, 11)
        let data = answer(tasks: #"""
        [{"id":"a","title":"Merge the fix into main?","note":"","area":"app","status":"todo","priority":"high","when":"today",
          "estimate":0.1,"sessionId":"","why":"  Branch idle a week  ","due":"2026-10-26","kind":"decision"},
         {"id":"b","title":"B","note":"","area":"app","status":"todo","priority":"high","when":"week",
          "estimate":1,"sessionId":"","why":"","due":"26.10","kind":"question"},
         {"id":"c","title":"C","note":"","area":"app","status":"todo","priority":"high","when":"week",
          "estimate":1,"sessionId":"","due":"Mon"}]
        """#, areas: #"""
        [{"id":"a1","name":"A1","symbol":"cube.fill","color":"blue","weight":"focus","status":"","outcome":"","attention":"14"},
         {"id":"a2","name":"A2","symbol":"cube.fill","color":"teal","weight":"active","status":"","outcome":"","attention":140},
         {"id":"a3","name":"A3","symbol":"cube.fill","color":"pink","weight":"active","status":"","outcome":"","attention":-3},
         {"id":"a4","name":"A4","symbol":"cube.fill","color":"mint","weight":"parked","status":"","outcome":""}]
        """#)
        let result = try Planner.decode(answer: data, sessions: nil, model: "sonnet", costUSD: nil, now: now)
        XCTAssertEqual(result.tasks[0].why, "Branch idle a week")
        XCTAssertEqual(result.tasks[0].due, Day(year: 2026, month: 10, day: 26))
        XCTAssertEqual(result.tasks[0].kind, .decision)
        XCTAssertEqual(result.tasks[1].due, Day(year: 2026, month: 10, day: 26))
        XCTAssertEqual(result.tasks[1].kind, .task, "an unknown kind is a task")
        XCTAssertNil(result.tasks[2].due)
        XCTAssertEqual(result.tasks[2].kind, .task)
        XCTAssertEqual(result.areas.map(\.attention), [14, 100, 0, nil])
    }

    func testNumbersOutOfRangeAreClampedOrDropped() throws {
        let now = at(saturday, 11)
        func task(_ id: String, estimate: String) -> String {
            #"{"id":"\#(id)","title":"T \#(id)","note":"","area":"app","status":"todo","priority":"high","when":"week","estimate":\#(estimate),"sessionId":"","why":"","due":"","kind":"task"}"#
        }
        let data = answer(tasks: "[" + [task("huge", estimate: "1e300"), task("inf", estimate: #""inf""#),
                                        task("nan", estimate: #""nan""#), task("negative", estimate: "-2"),
                                        task("text", estimate: #""1,5""#)].joined(separator: ",") + "]",
                          areas: #"""
        [{"id":"a1","name":"A1","symbol":"cube.fill","color":"blue","weight":"focus","status":"","outcome":"","attention":1e300},
         {"id":"a2","name":"A2","symbol":"cube.fill","color":"teal","weight":"active","status":"","outcome":"","attention":"nan"},
         {"id":"a3","name":"A3","symbol":"cube.fill","color":"pink","weight":"active","status":"","outcome":"","attention":"-inf"}]
        """#)
        let result = try Planner.decode(answer: data, sessions: nil, model: "sonnet", costUSD: nil, now: now)
        XCTAssertEqual(result.tasks.map(\.estimate), [24, 0, 0, 0, 1.5], "≤ 24 h, and nothing that isn't a number")
        XCTAssertEqual(result.areas.map(\.attention), [100, nil, nil])
        XCTAssertEqual([2, 0.5, 1e300, .nan, -.infinity].map(\.hoursText).prefix(2), ["2", "0.5"], "and none traps")
    }

    func testDueDaysAreReadLeniently() {
        let now = at(saturday, 12)
        func due(_ s: String) -> Day? { Planner.dueDay(s, now: now) }
        let monday = Day(year: 2026, month: 10, day: 26)
        XCTAssertEqual(due("2026-10-26"), monday)
        XCTAssertEqual(due("2026-10-26T10:00:00Z"), monday)
        XCTAssertEqual(due("26.10.2026"), monday)
        XCTAssertEqual(due("26.10.26"), monday)
        XCTAssertEqual(due("26.10"), monday)
        XCTAssertEqual(due("26.10 (Mon)"), monday)
        XCTAssertEqual(due("5.1"), Day(year: 2027, month: 1, day: 5), "dd.mm: the nearest year")
        XCTAssertEqual(due("20.04"), Day(year: 2027, month: 4, day: 20))
        XCTAssertEqual(due("01.05"), Day(year: 2026, month: 5, day: 1))
        XCTAssertEqual(due("2026-05-01"), Day(year: 2026, month: 5, day: 1))
        XCTAssertNil(due("2025-10-26"), "a wrong year would pin it to Today as overdue")
        XCTAssertNil(due("30.02"))
        XCTAssertNil(due("2026-02-30"))
        XCTAssertNil(due(""))
        XCTAssertNil(due("soon"))
        XCTAssertNil(due("v1.2.16"))
        // Digits Int() can't read: nil, never a crash.
        XCTAssertNil(due("２０２６-１０-２６"))
        XCTAssertNil(due("2026-１０-26"))
        XCTAssertNil(due("٢٠٢٦-١٠-٢٦"))
        XCTAssertNil(due("１２.１０"))
        XCTAssertNil(due("12.１０.2026"))
        // 02.03 is 183 days either side of 01.09.2027 (2028 is a leap year): the later one wins.
        XCTAssertEqual(Planner.dueDay("02.03", now: at(Day(year: 2027, month: 9, day: 1), 12)),
                       Day(year: 2028, month: 3, day: 2))
    }

    func testShortSessionIdsResolveToTheirSession() throws {
        let full = "4f4b09d0-0000-4000-8000-00000000000a"
        let sessions = [session(full, end: at(saturday, 10), cwd: "/Users/me/dev/site"),
                        session("abc12345-0000", end: at(saturday, 9)), session("abc12345-1111", end: at(saturday, 8))]
        func resolved(_ id: String) throws -> PlanResult.PlannedTask {
            let data = answer(tasks: #"[{"id":"t","title":"T","note":"","area":"app","status":"todo","priority":"high","when":"week","estimate":1,"sessionId":"\#(id)","why":"","due":"","kind":"task"}]"#)
            return try XCTUnwrap(Planner.decode(answer: data, sessions: sessions, model: "sonnet", costUSD: nil,
                                                now: at(saturday, 11)).tasks.first)
        }
        XCTAssertEqual(try resolved("4f4b09d0").sessionId, full)
        XCTAssertEqual(try resolved("4f4b09d0").cwd, "/Users/me/dev/site")
        XCTAssertEqual(try resolved("session=4f4b09d0").sessionId, full)
        XCTAssertEqual(try resolved(full).sessionId, full)
        XCTAssertEqual(try resolved("abc12345").sessionId, "", "two sessions share it")
        XCTAssertEqual(try resolved("4f4b").sessionId, "", "too short to trust")
    }

    func testTheDigestARunSendsIsKeptInTheDataDir() throws {
        let saved = BoardStore.directory
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BoardStore.directory = dir
        defer {
            BoardStore.directory = saved
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertEqual(Planner.lastDigestURL, dir.appendingPathComponent("last-digest.txt"))
        Planner.saveDigest("Now: the first run\n")
        Planner.saveDigest("Now: the second run\n")
        XCTAssertEqual(try String(contentsOf: Planner.lastDigestURL, encoding: .utf8), "Now: the second run\n")
    }

    // MARK: Prompt and schema

    func testTheSchemaAsksForTheNewFields() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Planner.answerSchema.utf8)) as? [String: Any])
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        let task = try XCTUnwrap((props["tasks"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertTrue(Set(task["required"] as! [String]).isSuperset(of: ["why", "due", "kind"]))
        let taskProps = try XCTUnwrap(task["properties"] as? [String: Any])
        XCTAssertEqual((taskProps["kind"] as? [String: Any])?["enum"] as? [String], ["task", "decision"])
        let area = try XCTUnwrap((props["areas"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertTrue((area["required"] as! [String]).contains("attention"))
        XCTAssertEqual(((area["properties"] as? [String: Any])?["attention"] as? [String: Any])?["type"] as? String,
                       "integer")
    }

    func testThePromptIsAboutTodayAndWhatComesNextAndNamesNoProject() {
        let prompt = Planner.systemPrompt(language: "English")
        for phrase in ["what to do today and what comes next", "launch folder ≠ topic",
                       "urgent — only if", "kind: task — work; decision —", "\"running now\"",
                       "carried over from the plan of", "the last run's text", "up to 5 quick decisions", "attention",
                       // One list by `when`; decisions, doing and waiting are marks on its rows.
                       "The app shows one list, in sections by the when field", "are marks on rows, not separate lists",
                       // Reconcile first, "Other" small, the owner's last words, one person under several names.
                       "0. Reconcile the board first", "\"Other\" (id misc) stays at ~10% at most",
                       "\"Owner's last words\"", "under several names",
                       // The stake orders Today; nothing stays on it by inertia; checks before answering.
                       "Today first, ordered by stake: losing money or customers right now → a blocker of the "
                        + "focus goal",
                       "check what's unpushed against where the links lead",
                       "the first line of Today, as a task with the owner's steps", "kind=decision, when=week",
                       "Being carried over is not a reason",
                       "don't take a task already on Today off it just for the hours limit",
                       "The folder table is not the answer", "Money without the owner's attention is active, not focus",
                       "only with evidence that the ball is in someone else's court",
                       "the owner's tick on a batch is not proof", "\"Keep on a branch or discard?\"",
                       "a decision \"… sent?\"", "\"left over from …\"", "no count of days on Today",
                       "A number dates from its measurement", "\"check → decide\"", "snoozed by the owner until",
                       "Before answering, check:"] {
            XCTAssertTrue(prompt.contains(phrase), phrase)
        }
        XCTAssertFalse(prompt.contains("day 5"), "a carried task becoming a decision was an escape hatch")
        // The names the tests use: real ones would be the owner's projects and people.
        for name in ["Atlas", "atlas", "Garden", "garden", "Studio", "Dana", "Acme", "c0ffee1"] {
            XCTAssertFalse(prompt.contains(name), "the prompt must stay generic: \(name)")
        }
        XCTAssertLessThanOrEqual(prompt.count, 11_500, "rules replace rules: the prompt doesn't just grow")
    }
}
