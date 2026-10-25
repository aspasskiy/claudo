@testable import ClaudoCore
import XCTest

/// Compaction without the CLI: the summarizer's answers come from canned `claude -p` stdout, and the
/// pipeline runs on closures.
final class CompactTests: XCTestCase {
    // MARK: Builders

    private func session(_ id: String, daysAgo: Double, prompts: Int = 2, awaiting: Bool = false,
                         cwd: String = "/Users/me/dev/garden/web", title: String? = "A session") -> SessionDigest {
        // A fraction of a second, like real transcript times, so cache round trips are tested honestly.
        let end = F.now - daysAgo * F.day + 0.437
        return SessionDigest(id: id, cwd: cwd, folder: FileManager.default.temporaryDirectory, title: title,
                             start: end - 600, end: end, prompts: (1...prompts).map { "prompt \($0) about \(id)" },
                             lastReply: "Done: all of it for \(id)", awaitingReply: awaiting)
    }

    private func note(_ text: String, open: [String] = []) -> SessionSummary {
        SessionSummary(summary: text, state: .inProgress, importance: 3, open: open)
    }

    private var tempDir: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claudo-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Cache

    func testCacheEntriesStandWhileTheSessionIsUnchanged() throws {
        let s = session("c", daysAgo: 10, prompts: 3)
        var cache = SessionCache()
        cache.setSummary(note("A note"), for: s)
        XCTAssertEqual(cache.summary(for: s)?.summary, "A note")

        // Survives a save/load round trip with its fractional-second end time.
        let url = tempDir.appendingPathComponent("sessions-cache.json")
        try cache.save(to: url)
        let loaded = try XCTUnwrap(SessionCache.load(from: url))
        XCTAssertNotNil(loaded.summary(for: s))

        let later = SessionDigest(id: s.id, cwd: s.cwd, folder: s.folder, title: s.title, start: s.start,
                                  end: s.end + 60, prompts: s.prompts, lastReply: s.lastReply, awaitingReply: false)
        XCTAssertNil(loaded.summary(for: later), "a newer last record invalidates")
        let longer = SessionDigest(id: s.id, cwd: s.cwd, folder: s.folder, title: s.title, start: s.start,
                                   end: s.end, prompts: s.prompts + ["more"], lastReply: s.lastReply, awaitingReply: false)
        XCTAssertNil(loaded.summary(for: longer), "another prompt invalidates")
        var queued = SessionDigest(id: s.id, cwd: s.cwd, folder: s.folder, title: s.title, start: s.start,
                                   end: s.end, prompts: s.prompts + ["stop"], lastReply: s.lastReply, awaitingReply: false)
        queued.queuedCount = 1
        XCTAssertNotNil(loaded.summary(for: queued), "words queued mid-turn don't send a cached session back")

        var outdated = loaded
        outdated.entries[s.id]?.summaryVersion = "haiku-s0"
        XCTAssertNil(outdated.summary(for: s), "an older prompt is summarized again")
    }

    func testAnEntryWithUnknownKeysKeepsItsNote() throws {
        let s = session("extra", daysAgo: 10, prompts: 4)
        let ms = Int64((s.end.timeIntervalSince1970 * 1000).rounded())
        let json = """
        {"entries":{"extra":{"end":\(ms),"promptCount":4,
          "verdict":{"importance":1.69,"model":"classifier-1","state":"blocked_waiting"},
          "verdictVersion":"v1",
          "summary":{"importance":2,"open":["Answer about the force-push"],"state":"blocked",
                     "summary":"Level 3 committed locally, waits for a force-push."},
          "summaryVersion":"haiku-s1"}}}
        """
        let url = tempDir.appendingPathComponent("sessions-cache.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        var cache = try XCTUnwrap(SessionCache.load(from: url))
        XCTAssertEqual(cache.summary(for: s)?.open, ["Answer about the force-push"], "no re-summarizing the month")

        cache.setSummary(note("New"), for: session("other", daysAgo: 3))
        try cache.save(to: url)
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(saved.contains("verdict"), "the next save drops what it doesn't know")
        XCTAssertNotNil(SessionCache.load(from: url)?.summary(for: s))
    }

    func testSummariesOfTheLastPromptVersionStillStand() throws {
        let s = session("v", daysAgo: 10, prompts: 3)
        var cache = SessionCache()
        cache.setSummary(note("A new note"), for: s)
        XCTAssertEqual(cache.entries[s.id]?.summaryVersion, "haiku-s4")
        XCTAssertEqual(SessionSummarizer.version("haiku"), "haiku-s4")

        cache.entries[s.id]?.summaryVersion = "haiku-s1"
        XCTAssertEqual(cache.summary(for: s)?.summary, "A new note", "s1 notes stay: no re-summarizing the month")
        cache.entries[s.id]?.summaryVersion = "haiku-s2"
        XCTAssertNotNil(cache.summary(for: s), "s2 notes stay too")
        cache.entries[s.id]?.summaryVersion = "haiku-s3"
        XCTAssertNotNil(cache.summary(for: s), "so do s3 notes, written from the prompt in another language")
        cache.entries[s.id]?.summaryVersion = nil
        XCTAssertNil(cache.summary(for: s))
        XCTAssertEqual(CompactEstimate.make([s], cache: cache, mode: .haiku, limit: nil).toSummarize, 1)
        cache.entries[s.id]?.summaryVersion = "haiku-s1"
        XCTAssertEqual(CompactEstimate.make([s], cache: cache, mode: .haiku, limit: nil).toSummarize, 0,
                       "a cached s1 note costs no new call")
    }

    func testSonnetKeepsItsOwnNotes() throws {
        let s = session("both", daysAgo: 10, prompts: 3)
        var haiku = SessionCache()
        haiku.setSummary(note("Haiku's note"), for: s)
        var sonnet = SessionCache(model: "sonnet")
        XCTAssertNil(sonnet.summary(for: s), "Haiku's notes don't stand in for Sonnet's")
        sonnet.setSummary(note("Sonnet's note"), for: s)
        XCTAssertEqual(sonnet.entries[s.id]?.summaryVersion, "sonnet-s4")
        sonnet.entries[s.id]?.summaryVersion = "sonnet-s3"
        XCTAssertNotNil(sonnet.summary(for: s), "Sonnet's cached month stands too")
        XCTAssertEqual(haiku.summary(for: s)?.summary, "Haiku's note", "switching back sends nothing again")

        // A Haiku note that found its way into Sonnet's cache is summarized again.
        var mixed = sonnet
        mixed.entries[s.id]?.summaryVersion = "haiku-s3"
        XCTAssertNil(mixed.summary(for: s))
        XCTAssertEqual(CompactEstimate.make([s], cache: mixed, mode: .sonnet, limit: nil).toSummarize, 1)

        // A file per model; Haiku's has no suffix.
        XCTAssertEqual(SessionCache.url(model: "haiku").lastPathComponent, "sessions-cache.json")
        XCTAssertEqual(SessionCache.url(model: "sonnet").lastPathComponent, "sessions-cache-sonnet.json")
        let url = tempDir.appendingPathComponent("sessions-cache-sonnet.json")
        try sonnet.save(to: url)
        XCTAssertEqual(SessionCache.load(from: url, model: "sonnet")?.summary(for: s)?.summary, "Sonnet's note")
        XCTAssertNil(SessionCache.load(from: url)?.summary(for: s), "read as Haiku's, Sonnet's notes don't count")
    }

    func testANewSessionStateReplacesTheEntry() {
        let s = session("f", daysAgo: 10)
        var cache = SessionCache()
        cache.setSummary(note("Old"), for: s)
        let moved = SessionDigest(id: s.id, cwd: s.cwd, folder: s.folder, title: s.title, start: s.start,
                                  end: s.end + 3600, prompts: s.prompts + ["go on"], lastReply: "", awaitingReply: true)
        cache.setSummary(note("New"), for: moved)
        XCTAssertNil(cache.summary(for: s))
        XCTAssertEqual(cache.summary(for: moved)?.summary, "New")
        XCTAssertEqual(cache.entries[s.id]?.promptCount, 3)
    }

    func testPruneDropsLongGoneSessions() {
        var cache = SessionCache()
        cache.setSummary(note("Long ago"), for: session("old", daysAgo: 90))
        cache.setSummary(note("Recently"), for: session("new", daysAgo: 5))
        cache.prune(endedBefore: F.now - 60 * F.day)
        XCTAssertEqual(Set(cache.entries.keys), ["new"])
    }

    // MARK: Summarizer

    func testSummarizerAnswerDecodesLeniently() throws {
        let long = String(repeating: "a very long note ", count: 30)
        let stdout = """
        {"type":"result","is_error":false,"total_cost_usd":0.031,
         "structured_output":{"summaries":[
           {"sessionId":"s1","summary":"Quota bug found: inbound counts toward the limit; branch fix/quota (c0ffee1).",
            "state":"in_progress","importance":"3","open":["Open a PR and ship it","Emails at 80%/100%"]},
           {"sessionId":"s2","summary":"\(long)","state":"weird","importance":7,"open":["a","b","c","d","e"]},
           {"sessionId":"s1","summary":"duplicate","state":"done","importance":0,"open":[]},
           {"sessionId":"ghost","summary":"someone else's","state":"done","importance":1,"open":[]}
         ]}}
        """
        let notes = try SessionSummarizer.decode(stdout: Data(stdout.utf8), ids: ["s1", "s2", "s3"])
        XCTAssertEqual(Set(notes.keys), ["s1", "s2"], "unknown ids ignored, missing ones stay unsummarized")
        XCTAssertEqual(notes["s1"]?.state, .inProgress)
        XCTAssertEqual(notes["s1"]?.importance, 3)
        XCTAssertEqual(notes["s1"]?.open, ["Open a PR and ship it", "Emails at 80%/100%"])
        XCTAssertTrue(notes["s1"]!.summary.hasPrefix("Quota bug found"), "the first answer for an id wins")
        XCTAssertEqual(notes["s2"]?.state, .inProgress, "unknown state degrades to in progress")
        XCTAssertEqual(notes["s2"]?.importance, 4)
        XCTAssertEqual(notes["s2"]?.open.count, 3)
        XCTAssertLessThanOrEqual(notes["s2"]!.summary.count, 300)
        let noSummaries = #"{"is_error":false,"structured_output":{"x":1}}"#
        XCTAssertThrowsError(try SessionSummarizer.decode(stdout: Data(noSummaries.utf8), ids: ["s1"])) {
            XCTAssertEqual($0 as? PlannerError, .noSummaries(model: "haiku"))
        }
    }

    func testSummarizerPromptPutsTheOwnersStepsThenLooseEndsFirstAndKeepsTheirStopWords() {
        let prompt = SessionSummarizer.systemPrompt(language: "English")
        XCTAssertTrue(prompt.contains("List first in open what waits for the owner"))
        XCTAssertTrue(prompt.contains("\"I need you to …\"), those steps; then any loose end"))
        XCTAssertTrue(prompt.contains("(\"stop\", \"drop it\", \"don't do it\"), quote their words in summary "
                                      + "verbatim"))
        XCTAssertTrue(prompt.contains("in the language they wrote them in"), "stop words stay as the owner wrote them")
    }

    func testBatchesPackWholeBlocksUpToTheLimit() {
        let sessions = (0..<10).map { session("b\($0)", daysAgo: Double($0), prompts: 3) }
        let size = sessions[0].rawBlock.count
        let batches = SessionSummarizer.batches(sessions, maxChars: size * 3 + 10)
        XCTAssertEqual(batches.map(\.count), [3, 3, 3, 1])
        XCTAssertEqual(batches.flatMap { $0 }.map(\.id), sessions.map(\.id), "order kept, nothing lost")
        XCTAssertEqual(SessionSummarizer.batches(sessions, maxChars: 10).count, 10, "an oversized block goes alone")
    }

    // MARK: Pipeline

    func testPipelineSummarizesWhatIsNewAndReusesTheCache() throws {
        let fresh = session("fresh", daysAgo: 1)
        let old = session("old", daysAgo: 22)
        let cached = session("cached", daysAgo: 15)
        let sessions = [fresh, cached, old]

        var cache = SessionCache()
        cache.setSummary(note("From the cache"), for: cached)

        let summarized = Recorder()
        var compactor = Compactor(mode: .haiku)
        compactor.summarize = { [self] batch in
            summarized.add(batch.map(\.id))
            return (Dictionary(uniqueKeysWithValues: batch.map { ($0.id, note("Note \($0.id)", open: ["Do it"])) }), 0.02)
        }
        let stages = Recorder()
        let report = try compactor.run(sessions, cache: &cache, progress: { stages.add(["\($0)"]) })

        XCTAssertEqual(Set(summarized.items), ["fresh", "old"], "the cached note isn't asked again")
        XCTAssertEqual(Set(report.summarized), ["fresh", "old"])
        XCTAssertEqual(Set(report.summaries.keys), ["fresh", "old", "cached"])
        XCTAssertEqual(report.costUSD, 0.02, accuracy: 1e-9)
        XCTAssertNotNil(cache.summary(for: old), "fresh notes land in the cache")
        XCTAssertTrue(stages.items.contains { $0.contains("summarizing(done: 1, total: 1)") })

        // A second pass over unchanged sessions asks nothing.
        let again = try compactor.run(sessions, cache: &cache)
        XCTAssertEqual(summarized.items.count, 2)
        XCTAssertEqual(again.summaries.count, 3)
    }

    func testOffDoesNothing() throws {
        var compactor = Compactor(mode: .off)
        compactor.summarize = { _ in XCTFail("off must not summarize"); return ([:], nil) }
        var cache = SessionCache()
        let report = try compactor.run([session("a", daysAgo: 1)], cache: &cache)
        XCTAssertTrue(report.summaries.isEmpty)
    }

    func testLimitTakesTheNewestUncachedSessions() throws {
        let sessions = [session("n1", daysAgo: 1), session("n2", daysAgo: 2), session("n3", daysAgo: 3)]
        let summarized = Recorder()
        var compactor = Compactor(mode: .haiku)
        compactor.limit = 1
        compactor.summarize = { [self] batch in
            summarized.add(batch.map(\.id))
            return (Dictionary(uniqueKeysWithValues: batch.map { ($0.id, note("A note")) }), nil)
        }
        var cache = SessionCache()
        _ = try compactor.run(sessions, cache: &cache)
        XCTAssertEqual(summarized.items, ["n1"])
    }

    func testAFailedBatchIsSkippedAndTheRestKept() throws {
        let sessions = [session("ok", daysAgo: 10), session("bad", daysAgo: 11)]
        var compactor = Compactor(mode: .haiku)
        compactor.batchChars = 1    // a batch per session
        compactor.summarize = { [self] batch in
            if batch.contains(where: { $0.id == "bad" }) { throw PlannerError.timedOut(who: "Haiku", timeout: 300) }
            return (Dictionary(uniqueKeysWithValues: batch.map { ($0.id, note("A note")) }), nil)
        }
        var cache = SessionCache()
        let report = try compactor.run(sessions, cache: &cache)
        XCTAssertEqual(report.summarized, ["ok"])
        XCTAssertEqual(report.batches, 1)
        XCTAssertEqual(report.failures, 1)
    }

    func testEveryBatchFailingIsAnError() {
        var compactor = Compactor(mode: .haiku)
        compactor.summarize = { _ in throw PlannerError.timedOut(who: "Haiku", timeout: 300) }
        var cache = SessionCache()
        XCTAssertThrowsError(try compactor.run([session("a", daysAgo: 1)], cache: &cache))
    }

    // MARK: Digest

    func testDigestShowsNotesAndFoldsOlderOnesIntoALine() {
        let noted = session("noted", daysAgo: 2, prompts: 5, cwd: "/Users/me/dev/atlas/api", title: "Inbound quota")
        let oldDone = session("olddone", daysAgo: 18, prompts: 2, cwd: "/Users/me/dev/atlas", title: "Hosting invoice")
        let raw = session("raw", daysAgo: 12, prompts: 3, cwd: "/Users/me/dev/garden/web", title: "Winter level")

        var report = CompactReport()
        report.summaries["noted"] = SessionSummary(summary: "Quota bug: inbound in the limit; branch c0ffee1",
                                                   state: .inProgress, importance: 3,
                                                   open: ["Open a PR and ship it", "Emails at 80%/100%"])
        report.summaries["olddone"] = SessionSummary(summary: "Discussed hosting costs", state: .done, importance: 2,
                                                     open: ["Pay the hosting invoice by 25.10", "Check the plan"])

        let text = Planner(days: 30).digest(sessions: [noted, raw, oldDone], board: .empty, now: F.now, compact: report)

        XCTAssertTrue(text.contains("Compaction: 2 sessions summarized."))
        XCTAssertTrue(text.contains("· 5 prompts · in progress · importance 3/4"))
        XCTAssertTrue(text.contains("Summary: Quota bug: inbound in the limit; branch c0ffee1"))
        XCTAssertTrue(text.contains("Open: Open a PR and ship it; Emails at 80%/100%"))
        // Older than the detail tier: one line; a done session keeps the first thing it left open.
        XCTAssertTrue(text.contains("- \(DigestFormat.day(oldDone.end)) · dev/atlas · \"Hosting invoice\" · "
                                    + "2 prompts · done · 2/4 · session=olddone\n"
                                    + "  Open: Pay the hosting invoice by 25.10\n"))
        XCTAssertFalse(text.contains("Summary: Discussed hosting costs"))
        XCTAssertTrue(text.contains("> prompt 1 about raw"), "no note → the raw block stays")
        XCTAssertFalse(text.contains("> prompt 1 about noted"), "a note replaces the raw prompts")
    }

    func testRawDigestIsUnchangedWithoutAReport() {
        let s = session("plain", daysAgo: 2)
        let text = Planner(days: 30).digest(sessions: [s], board: .empty, now: F.now)
        XCTAssertFalse(text.contains("Compaction"))
        XCTAssertTrue(text.contains("> prompt 1 about plain"))
    }

    func testPlannerPromptSaysWhatTheNotesAre() {
        XCTAssertTrue(Planner.systemPrompt(language: "English")
            .contains("\"Summary:\" and \"Open:\" are notes by a helper model."))
    }

    // MARK: Run report

    func testTheEnvelopeKeepsClaudesReportWithoutTheAnswer() throws {
        let stdout = #"{"type":"result","is_error":false,"duration_ms":540000,"total_cost_usd":4.17,"result":"…","#
            + #""usage":{"output_tokens_details":{"thinking_tokens":31000}},"structured_output":{"summaries":[]}}"#
        let envelope = try ClaudeCLI.envelope(ExecResult(status: 0, stdout: Data(stdout.utf8), stderr: Data()))
        XCTAssertEqual(envelope.stats["duration_ms"] as? Int, 540000)
        XCTAssertNotNil(envelope.stats["usage"], "thinking tokens show where a slow run went")
        XCTAssertNil(envelope.stats["result"])
        XCTAssertNil(envelope.stats["structured_output"], "last-run.json holds the report, not the answer")
    }

    func testEffortIsPinnedNotInherited() {
        // claude -p would otherwise take the owner's interactive effortLevel from ~/.claude/settings.json.
        XCTAssertEqual(Planner().effort, "xhigh")
        XCTAssertEqual(Planner().compactEffort, "xhigh")
        XCTAssertEqual(SessionSummarizer(model: "sonnet").effort, "xhigh")
        XCTAssertEqual(SessionSummarizer(model: "sonnet", effort: "low").effort, "low")
    }

    // MARK: Estimate and modes

    func testEstimateCountsUncachedSessionsUpToTheLimit() {
        let sessions = [session("e1", daysAgo: 1), session("e2", daysAgo: 20), session("e3", daysAgo: 21)]
        var cache = SessionCache()
        cache.setSummary(note("cached"), for: sessions[0])
        XCTAssertEqual(CompactEstimate.make(sessions, cache: cache, mode: .haiku, limit: nil).toSummarize, 2)
        XCTAssertEqual(CompactEstimate.make(sessions, cache: cache, mode: .haiku, limit: 1).toSummarize, 1)
        XCTAssertEqual(CompactEstimate.make(sessions, cache: cache, mode: .off, limit: nil).toSummarize, 0)
        XCTAssertEqual(CompactEstimate.make(sessions, cache: cache, mode: .haiku, limit: nil).batches, 1)
    }

    func testModes() {
        XCTAssertEqual(CompactMode.allCases.map(\.model), [nil, "haiku", "sonnet"])
        XCTAssertEqual(CompactMode.allCases.map(\.name), ["Off", "Haiku", "Sonnet"])
        XCTAssertEqual(SessionSummarizer(model: "sonnet").timeout, 600, "Sonnet gets longer per batch")
        XCTAssertEqual(SessionSummarizer().timeout, 300)
    }
}

// MARK: - Test doubles

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var items: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ new: [String]) { lock.lock(); stored += new; lock.unlock() }
}
