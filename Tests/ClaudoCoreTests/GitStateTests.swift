@testable import ClaudoCore
import XCTest

/// Git state from canned git output: no real repo is ever read.
final class GitStateTests: XCTestCase {
    /// What a fake git was asked, from whatever thread.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [[String]] = []
        func add(_ args: [String]) { lock.lock(); list.append(args); lock.unlock() }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return list }
    }

    func testStatusGivesBranchUnpushedAndChanges() {
        let status = """
        # branch.oid e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 3b18e512 3b18e512 src/net/checkout.js
        2 R. N... 100644 100644 100644 9c1d2e3f 9c1d2e3f R100 worker/index.js\tworker.js
        ? notes/
        ! dist/
        """
        let repo = GitState.parseStatus(status, root: "/Users/me/dev/site")
        XCTAssertEqual(repo.branch, "main")
        XCTAssertEqual(repo.unpushed, 2)
        XCTAssertEqual(repo.dirty, 3, "changed, renamed and untracked count; ignored doesn't")
    }

    func testNoUpstreamOrADetachedHeadSayNothingAboutPushing() {
        let local = GitState.parseStatus("# branch.oid abc\n# branch.head firmware\n", root: "/r")
        XCTAssertEqual(local.branch, "firmware")
        XCTAssertNil(local.unpushed)
        XCTAssertEqual(local.dirty, 0)
        let gone = GitState.parseStatus("# branch.oid abc\n# branch.head fix\n# branch.upstream origin/fix\n", root: "/r")
        XCTAssertNil(gone.unpushed, "an upstream that is gone has no ahead count")
        XCTAssertNil(GitState.parseStatus("# branch.oid abc\n# branch.head (detached)\n", root: "/r").branch)
    }

    func testLogGivesTheLastCommit() {
        var repo = RepoState(root: "/r")
        GitState.parseLog("1729700000\tRelease: checkout\twith a tab\n", into: &repo)
        XCTAssertEqual(repo.lastCommit, Date(timeIntervalSince1970: 1_729_700_000))
        XCTAssertEqual(repo.lastSubject, "Release: checkout\twith a tab")
        var untouched = RepoState(root: "/r")
        GitState.parseLog("fatal: your current branch has no commits", into: &untouched)
        XCTAssertNil(untouched.lastCommit)
    }

    func testALinePerRepo() {
        let when = Date(timeIntervalSince1970: 1_729_700_000)
        XCTAssertEqual(GitState.line(RepoState(root: "/Users/me/dev/site", branch: "main", dirty: 3, unpushed: 1,
                                               lastCommit: when, lastSubject: "Fix checkout")),
                       "- /Users/me/dev/site · main · uncommitted: 3 · unpushed: 1 · commit "
                        + "\(DigestFormat.short(when)) \"Fix checkout\"")
        XCTAssertEqual(GitState.line(RepoState(root: "/r", branch: "main", dirty: 0, unpushed: 0)),
                       "- /r · main · clean · pushed")
        XCTAssertEqual(GitState.line(RepoState(root: "/r", branch: nil, dirty: 9, unpushed: nil)),
                       "- /r · detached HEAD · uncommitted: 9 · no upstream")
    }

    func testUnpushedCommitsAreListedWithTheirWholeSubjects() {
        let when = Date(timeIntervalSince1970: 1_729_700_000)
        let subject = "feat(checkout): an embedded checkout on the pricing page, built by the site's worker "
            + "and shared with the app"
        let repo = RepoState(root: "/Users/me/dev/site", branch: "main", dirty: 0, unpushed: 2,
                             unpushedCommits: ["a1b2c3d fix(mobile): keep the phone menu on screen", "e4f5a6b " + subject],
                             lastCommit: when, lastSubject: "fix(mobile): keep the phone menu on screen")
        XCTAssertEqual(GitState.line(repo), """
            - /Users/me/dev/site · main · clean · unpushed: 2 · commit \(DigestFormat.short(when))
              unpushed: a1b2c3d fix(mobile): keep the phone menu on screen
              unpushed: e4f5a6b \(subject)
            """, "the last commit is the first unpushed one: its subject moves down, uncut")

        var many = repo
        many.unpushed = 5
        many.unpushedCommits = ["c1 one", "c2 two", "c3 three"]
        XCTAssertTrue(GitState.line(many).hasSuffix("\n  unpushed: c3 three\n  …2 more"))
    }

    func testUnpushedCommitsComeFromAThirdGitCallOnlyWhenThereAreSome() {
        let calls = Calls()
        let run: GitState.Runner = { args, dir in
            calls.add(args)
            switch args.first {
            case "status": return "# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n"
                + (dir == "/r/ahead" ? "# branch.ab +4 -0\n" : "# branch.ab +0 -0\n")
            case "log" where args.contains("@{u}..HEAD"):
                return "b7c8d9e feat(menu): every item slides in\nf0e1d2c fix(mobile): phones in portrait\n\n"
                    + "e4f5a6b feat(checkout): embedded checkout\nextra line git would never send\n"
            case "log": return "1729700000\tfeat(menu): every item slides in\n"
            default: return nil
            }
        }
        let ahead = GitState.read("/r/ahead", run: run)
        XCTAssertEqual(ahead?.unpushedCommits, ["b7c8d9e feat(menu): every item slides in",
                                                "f0e1d2c fix(mobile): phones in portrait",
                                                "e4f5a6b feat(checkout): embedded checkout"])
        XCTAssertTrue(calls.all.contains(["log", "@{u}..HEAD", "--format=%h %s", "-3"]))
        let before = calls.all.count
        let even = GitState.read("/r/even", run: run)
        XCTAssertEqual(even?.unpushedCommits, [])
        XCTAssertEqual(calls.all.count - before, 2, "status and the last commit only")
    }

    /// A git that knows a few repos: rev-parse answers the toplevel, status and log answer per repo.
    private func fakeGit(tops: [String: String], broken: Set<String> = []) -> GitState.Runner {
        { args, dir in
            switch args.first {
            case "rev-parse": return tops[dir].map { $0 + "\n" }
            case "status": return broken.contains(dir) ? nil : "# branch.oid abc\n# branch.head main\n# branch.ab +0 -0\n"
            case "log" where args.contains("@{u}..HEAD"): return nil
            case "log": return "1729700000\tWork in \(dir)\n"
            default: return nil
            }
        }
    }

    func testEachRepoOnceInTheOrderItWasTouched() {
        let run = fakeGit(tops: ["/r/a/sub/deeper": "/r/a", "/r/a": "/r/a", "/r/b": "/r/b", "/r/c": "/r/c"],
                          broken: ["/r/c"])
        let repos = GitState.collect(cwds: ["/r/a/sub/deeper", "/tmp/not-a-repo", "/r/b", "/r/a", "/r/c"], run: run)
        XCTAssertEqual(repos.map(\.root), ["/r/a", "/r/b"], "subfolders fold into their repo; failures are skipped")
        XCTAssertEqual(repos[0].lastSubject, "Work in /r/a")
        XCTAssertEqual(repos[0].unpushed, 0)
    }

    func testAtMostTwentyRepos() {
        let cwds = (0..<25).map { "/r/\($0)" }
        let run = fakeGit(tops: Dictionary(uniqueKeysWithValues: cwds.map { ($0, $0) }))
        XCTAssertEqual(GitState.collect(cwds: cwds, run: run).map(\.root), Array(cwds.prefix(20)))
    }

    func testOnlyTheWeeksFoldersNewestFirst() {
        func session(_ id: String, _ cwd: String, daysAgo: Double) -> SessionDigest {
            SessionDigest(id: id, cwd: cwd, folder: FileManager.default.temporaryDirectory, title: nil,
                          start: F.now - daysAgo * F.day - 60, end: F.now - daysAgo * F.day, prompts: ["x"],
                          lastReply: "", awaitingReply: false)
        }
        let sessions = [session("1", "/r/a", daysAgo: 2), session("2", "/r/b", daysAgo: 1),
                        session("3", "/r/a", daysAgo: 3), session("4", "/r/old", daysAgo: 10)]
        let run = fakeGit(tops: ["/r/a": "/r/a", "/r/b": "/r/b", "/r/old": "/r/old"])
        XCTAssertEqual(GitState.scan(sessions: sessions, now: F.now, run: run).map(\.root), ["/r/b", "/r/a"])
    }
}
