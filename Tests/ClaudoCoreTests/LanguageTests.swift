@testable import ClaudoCore
import XCTest

/// Prompts and the digest are English; what the model writes is in the owner's language. The prompts name
/// the digest's markers word for word, so a marker renamed on one side only is caught here.
final class LanguageTests: XCTestCase {
    private func hasCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) }
    }

    // MARK: The output language

    func testCodesAndNamesBecomeEnglishNames() {
        for text in ["ru", "ru-US", "ru_RU", "Russian", "russian", "русский", " ru "] {
            XCTAssertEqual(PlanLanguage.name(text), "Russian", text)
        }
        XCTAssertEqual(PlanLanguage.name("en"), "English")
        XCTAssertEqual(PlanLanguage.name("Deutsch"), "German", "a language's own name works too")
        XCTAssertEqual(PlanLanguage.name("pt-BR"), "Portuguese", "the region is the device's, not the language's")
        XCTAssertEqual(PlanLanguage.name("en-US"), "English")
        // A script other than the language's usual one changes what gets written, so it stays.
        XCTAssertEqual(PlanLanguage.name("zh-Hant-TW"), "Chinese, Traditional")
        XCTAssertEqual(PlanLanguage.name("zh-TW"), "Chinese, Traditional", "Taiwan implies Traditional")
        XCTAssertEqual(PlanLanguage.name("zh-Hans"), "Chinese")
        XCTAssertEqual(PlanLanguage.name("sr-Latn"), "Serbian (Latin)")
        XCTAssertEqual(PlanLanguage.name("sr"), "Serbian")
        XCTAssertEqual(PlanLanguage.name("Brazilian Portuguese"), "Brazilian Portuguese", "an unknown name is kept")
        XCTAssertEqual(PlanLanguage.name(""), PlanLanguage.system)
    }

    func testTheSystemLanguageIsTheDefault() {
        // The first preferred language by name, or English when there is none it knows.
        let first = Locale.preferredLanguages.first.map(PlanLanguage.name)
        XCTAssertTrue(PlanLanguage.system == first || PlanLanguage.system == "English", PlanLanguage.system)
        XCTAssertFalse(PlanLanguage.system.isEmpty)
        XCTAssertEqual(Planner().language, PlanLanguage.system)
        XCTAssertEqual(SessionSummarizer().language, PlanLanguage.system)
        XCTAssertEqual(SessionSummarizer(model: "sonnet", language: "ru").language, "ru")
    }

    /// The app's Language setting, which the CLI follows too: system | english | russian.
    func testTheAppSettingNamesTheLanguage() {
        XCTAssertEqual(PlanLanguage.forSetting("english"), "English")
        XCTAssertEqual(PlanLanguage.forSetting("russian"), "Russian")
        XCTAssertEqual(PlanLanguage.forSetting("system"), PlanLanguage.system)
        XCTAssertEqual(PlanLanguage.forSetting(nil), PlanLanguage.system, "never set")
        XCTAssertEqual(PlanLanguage.forSetting("klingon"), PlanLanguage.system)
    }

    // MARK: Prompts

    func testThePromptsAreEnglishAndAskForTheLanguage() {
        for language in ["ru", "русский", "pt-BR", "English"] {
            let name = PlanLanguage.name(language)
            let planner = Planner.systemPrompt(language: language)
            let summarizer = SessionSummarizer.systemPrompt(language: language)
            XCTAssertFalse(hasCyrillic(planner), language)
            XCTAssertFalse(hasCyrillic(summarizer), language)
            XCTAssertTrue(planner.contains("closing reason) in \(name), strictly within the lengths"), language)
            XCTAssertTrue(planner.contains("sample titles and reasons) are written in \(name) too."), language)
            XCTAssertTrue(summarizer.contains("Write summary and open in \(name)."), language)
        }
        XCTAssertFalse(hasCyrillic(Planner.answerSchema))
        XCTAssertFalse(hasCyrillic(SessionSummarizer.answerSchema))
    }

    func testOwnerTitlesAreNeverTranslated() {
        let prompt = Planner.systemPrompt(language: "Russian")
        XCTAssertTrue(prompt.contains("in a language other than Russian may be translated into it, except a starred "
                                      + "field and the title of a task \"from the owner\"."))
    }

    // MARK: The digest

    /// A board and sessions in English that reach every part of the digest.
    private func englishDigest() throws -> String {
        let now = F.now
        let memory = FileManager.default.temporaryDirectory.appendingPathComponent("claudo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: memory.appendingPathComponent("memory"),
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: memory) }
        try "- Recheck the signup rate around 20.10".write(to: memory.appendingPathComponent("memory/MEMORY.md"),
                                                         atomically: true, encoding: .utf8)

        func session(_ id: String, hoursAgo: Double, prompts: Int = 2, awaiting: Bool = false,
                     cwd: String = "/Users/me/dev/app", recap: String? = nil, folder: URL? = nil) -> SessionDigest {
            let end = now - hoursAgo * 3600
            var s = SessionDigest(id: id, cwd: cwd, folder: folder ?? FileManager.default.temporaryDirectory,
                                  title: "Session \(id)", start: end - 600, end: end,
                                  prompts: (1...prompts).map { "prompt \($0) about \(id)" },
                                  lastReply: awaiting ? "" : "Done: the fix is pushed", awaitingReply: awaiting,
                                  lastRecord: end, turnOpen: awaiting)
            s.recap = recap
            return s
        }
        let sessions = [
            session("live0000-1", hoursAgo: 0.5, awaiting: true, folder: memory),
            session("dead0000-2", hoursAgo: 5, prompts: 14, awaiting: true),
            session("noted000-3", hoursAgo: 30, prompts: 3, recap: "The checkout works; the key is yours to set."),
            session("oldnote0-4", hoursAgo: 12 * 24, prompts: 3, awaiting: true),
            session("oldraw00-5", hoursAgo: 13 * 24, recap: "Drafted the release notes."),
            session("olderrnd-6", hoursAgo: 14 * 24, prompts: 1),
        ] + (0..<16).map { session("folder\($0)-7", hoursAgo: 40 + Double($0), cwd: "/Users/me/dev/p\($0)") }

        var report = CompactReport()
        report.summaries["noted000-3"] = SessionSummary(summary: "Fixed the checkout", state: .inProgress,
                                                        importance: 3, open: ["Set the key", "Reply to support"])
        report.summaries["oldnote0-4"] = SessionSummary(summary: "Started the migration", state: .blocked,
                                                        importance: 2, open: ["Ask the host about limits"])

        let area = Area(id: "app", name: "App", symbol: "iphone", color: .blue, weight: .focus,
                        status: "Checkout fixed", outcome: "Release 2.0")
        var carried = F.task("carried", "Merge the fix into main?", area: "app", when: .today,
                             createdAt: now - 6 * F.day, sessionId: "noted000-3")
        carried.note = "Branch fix/checkout"
        carried.kind = .decision
        carried.why = "Paying users can't check out"
        carried.plannedFor = Day(now).adding(days: -1)
        carried.todaySince = Day(now).adding(days: -3)
        carried.due = Day(now).adding(days: 2)
        carried.pinned = [.due, .priority]
        var mine = F.task("mine", "Buy tickets", area: Area.inboxID, origin: .user, pinned: [.title])
        mine.note = ""
        var snoozed = F.task("snoozed", "Send the documents", area: "app", sessionId: "live0000-1")
        snoozed.note = "To the bank"
        snoozed.due = Day(now)
        snoozed.snoozedUntil = Day(now).adding(days: 1)
        var advised = F.task("advised", "Fix the quota", area: "app", status: .doing, pinned: [.status],
                             advice: Advice(status: .done, reason: "merged into main"))
        advised.note = "Incoming count"
        var closed = F.task("closed", "Email the landlord", area: "app", status: .done, pinned: [.status],
                            completedAt: now - F.day)
        closed.closedReason = "email sent"
        var board = Board(focus: "App: ship 2.0", areas: [area], tasks: [carried, mine, snoozed, advised, closed],
                          plannedAt: now - F.day, model: "sonnet", sessionCount: 22, costUSD: 1)
        board.tasks[0].pinned.insert(.when)

        let repos = [RepoState(root: "/Users/me/dev/app", branch: "main", dirty: 2, unpushed: 5,
                               unpushedCommits: ["a1b2c3d Fix checkout", "e4f5a6b Add the key", "c0c0c0c Docs"],
                               lastCommit: now - 3600, lastSubject: "Fix checkout"),
                     RepoState(root: "/Users/me/dev/site", branch: nil, dirty: 0, unpushed: nil,
                               lastCommit: now - 7200, lastSubject: "Landing copy"),
                     RepoState(root: "/Users/me/dev/api", branch: "dev", dirty: 0, unpushed: 0)]
        return Planner(days: 30).digest(sessions: sessions, board: board, now: now, compact: report, repos: repos)
    }

    func testTheDigestOfAnEnglishBoardIsAllEnglish() throws {
        let text = try englishDigest()
        XCTAssertFalse(hasCyrillic(text), text)
        for part in ["# Current board — update it", "## Areas", "## Open tasks", "## Closed in the last 30 days",
                     "# Repository state", "# Activity by launch folder", "more folders", "# Project memory",
                     "# Sessions of the last 7 days", "# Sessions older than 7 days", "prompts skipped",
                     "Assistant's last reply:", "Result (Claude Code recap):", "· importance 3/4",
                     "· blocked · 2/4 · CUT OFF · session=oldnote0",
                     "  …2 more", "no upstream"] {
            XCTAssertTrue(text.contains(part), part)
        }
        XCTAssertTrue(DigestFormat.weekday(F.now).allSatisfy(\.isASCII), "weekdays are English")
    }

    func testTheDigestSaysInEnglishWhenOldSessionsDontFit() {
        let now = F.now
        let long = String(repeating: "a long prompt ", count: 30)
        let sessions = (0..<150).map { i in
            SessionDigest(id: "big\(i)", cwd: "/Users/me/dev/app", folder: FileManager.default.temporaryDirectory,
                          title: "Big \(i)", start: now - 3600, end: now - Double(i) * 60,
                          prompts: Array(repeating: long, count: 14), lastReply: long, awaitingReply: false)
        }
        let text = Planner(days: 30).digest(sessions: sessions, board: .empty, now: now)
        XCTAssertTrue(text.hasSuffix("\n…older sessions didn't fit in the limit…\n"))
        XCTAssertFalse(hasCyrillic(text))
    }

    /// Whatever a prompt quotes from the digest is printed by the digest exactly so.
    func testThePromptsNameTheDigestsMarkersVerbatim() throws {
        let digest = try englishDigest()
        let prompt = Planner.systemPrompt(language: "English")
        for marker in ["from the owner", "on Today since", "(day ", "carried over from the plan of",
                       "snoozed by the owner until", "Repository state", "Activity by launch folder", "Project memory",
                       "running now", "CUT OFF", "Owner's last words", "Claude Code recap", "done by the owner",
                       "Closed", "Summary:", "Open:", "session=", "why"] {
            XCTAssertTrue(prompt.contains(marker), "prompt: \(marker)")
            XCTAssertTrue(digest.contains(marker), "digest: \(marker)")
        }

        let raw = SessionDigest(id: "raw", cwd: "/Users/me/dev/app", folder: FileManager.default.temporaryDirectory,
                                title: "Raw", start: F.now - 600, end: F.now, prompts: ["fix it"],
                                lastReply: "Fixed.", awaitingReply: false, recap: "Fixed it.")
        let summarizer = SessionSummarizer.systemPrompt(language: "English")
        for marker in ["## session=", "Claude Code recap"] {
            XCTAssertTrue(summarizer.contains(marker), "summarizer prompt: \(marker)")
            XCTAssertTrue(raw.rawBlock.contains(marker), "raw block: \(marker)")
        }
        XCTAssertTrue(summarizer.contains("(lines starting with \">\")"))
        XCTAssertTrue(raw.rawBlock.contains("\n> fix it\n"))
        XCTAssertTrue(summarizer.contains("the assistant's last reply"))
        XCTAssertTrue(raw.rawBlock.contains("Assistant's last reply: Fixed."))
        XCTAssertFalse(hasCyrillic(raw.rawBlock))
    }
}
