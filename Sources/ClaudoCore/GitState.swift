import Foundation

/// Where a repo the owner worked in this week stands. Uncommitted and unpushed work is started work the
/// sessions alone don't show; a push or a merge closes tasks.
public struct RepoState: Sendable, Equatable {
    /// `git rev-parse --show-toplevel`.
    public var root: String
    /// nil when HEAD is detached.
    public var branch: String?
    /// Changed and untracked entries, as `git status --porcelain` lists them.
    public var dirty: Int
    /// Commits ahead of the upstream (`@{u}..HEAD`); nil without an upstream.
    public var unpushed: Int?
    /// The newest unpushed commits, "e4f5a6b Embedded checkout on the pricing page…", whole subjects: their
    /// own words are what ties a commit that isn't live to what is broken in prod.
    public var unpushedCommits: [String]
    public var lastCommit: Date?
    public var lastSubject: String

    public init(root: String, branch: String? = nil, dirty: Int = 0, unpushed: Int? = nil,
                unpushedCommits: [String] = [], lastCommit: Date? = nil, lastSubject: String = "") {
        self.root = root
        self.branch = branch
        self.dirty = dirty
        self.unpushed = unpushed
        self.unpushedCommits = unpushedCommits
        self.lastCommit = lastCommit
        self.lastSubject = lastSubject
    }
}

/// Reads the git state of the folders the week's sessions ran in, for the digest. Read-only:
/// `--no-optional-locks` (= GIT_OPTIONAL_LOCKS=0) keeps even `status` from refreshing the index, so a
/// session's own git never runs into a lock of ours. Non-repos and git failures are skipped silently.
public enum GitState {
    static let git = "/usr/bin/git"
    /// Per git call; a repo takes two (`status`, `log`), three with unpushed commits.
    static let timeout: TimeInterval = 3
    static let maxRepos = 20
    /// Unpushed commits listed under a repo, newest first.
    static let maxUnpushedShown = 3
    /// Their subjects go in whole; this only stops a runaway one-line message.
    static let maxSubject = 300

    /// Runs git with `args` in `dir`: its stdout, or nil when it can't run or exits non-zero.
    public typealias Runner = @Sendable (_ args: [String], _ dir: String) -> String?

    /// Repos of the folders worked in during the last `days`, most recently touched first, each repo once
    /// (sessions often start in a subfolder).
    public static func scan(sessions: [SessionDigest], now: Date = Date(), days: Int = Planner.detailDays,
                            run: Runner = live) -> [RepoState] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        var cwds: [String] = []
        var seen = Set<String>()
        for s in sessions.sorted(by: { $0.end > $1.end }) where s.end >= cutoff && seen.insert(s.cwd).inserted {
            cwds.append(s.cwd)
        }
        return collect(cwds: cwds, run: run)
    }

    /// `cwds` in priority order → their toplevels, deduped in that order and capped, each read.
    static func collect(cwds: [String], run: Runner) -> [RepoState] {
        let tops = parallelMap(cwds) { cwd in
            run(["rev-parse", "--show-toplevel"], cwd)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var roots: [String] = []
        for top in tops.compactMap({ $0 }) where !top.isEmpty && !roots.contains(top) { roots.append(top) }
        return parallelMap(Array(roots.prefix(maxRepos))) { read($0, run: run) }.compactMap { $0 }
    }

    /// Branch, upstream and changes come from one `status --porcelain=v2 --branch`; `branch.ab` is the
    /// same count as `rev-list --count @{u}..HEAD` and is missing without an upstream.
    static func read(_ root: String, run: Runner) -> RepoState? {
        guard let status = run(["status", "--porcelain=v2", "--branch"], root) else { return nil }
        var repo = parseStatus(status, root: root)
        if let log = run(["log", "-1", "--format=%ct%x09%s"], root) { parseLog(log, into: &repo) }
        if (repo.unpushed ?? 0) > 0,
           let log = run(["log", "@{u}..HEAD", "--format=%h %s", "-\(maxUnpushedShown)"], root) {
            repo.unpushedCommits = parseCommits(log)
        }
        return repo
    }

    static func parseStatus(_ text: String, root: String) -> RepoState {
        var repo = RepoState(root: root)
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                repo.branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.ab ") {
                // "+2 -0": ahead, behind.
                let ahead = line.dropFirst("# branch.ab ".count).split(separator: " ").first
                repo.unpushed = ahead.flatMap { Int($0.dropFirst()) }
            } else if !line.hasPrefix("#"), !line.hasPrefix("!") {
                repo.dirty += 1
            }
        }
        return repo
    }

    /// `%h %s` lines: "e4f5a6b Embedded checkout…", one per commit.
    static func parseCommits(_ text: String) -> [String] {
        Array(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(maxUnpushedShown))
    }

    /// `%ct<TAB>%s`: commit time (Unix seconds) and subject.
    static func parseLog(_ text: String, into repo: inout RepoState) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tab = line.firstIndex(of: "\t"), let seconds = TimeInterval(line[..<tab]) else { return }
        repo.lastCommit = Date(timeIntervalSince1970: seconds)
        repo.lastSubject = String(line[line.index(after: tab)...])
    }

    /// `- ~/dev/app · main · uncommitted: 3 · unpushed: 1 · commit 23.10 21:20 "Fix checkout"`; with
    /// unpushed commits read, the subject moves to their lines below, in full (HEAD is the first of them):
    /// `  unpushed: e4f5a6b Fix checkout`, and `  …N more` when there are more.
    static func line(_ r: RepoState) -> String {
        var parts = [Paths.tilde(r.root), r.branch ?? "detached HEAD"]
        parts.append(r.dirty > 0 ? "uncommitted: \(r.dirty)" : "clean")
        switch r.unpushed {
        case nil: parts.append("no upstream")
        case 0?: parts.append("pushed")
        case let n?: parts.append("unpushed: \(n)")
        }
        let listed = r.unpushedCommits.map { $0.oneLine.clipped(maxSubject) }
        if let date = r.lastCommit {
            parts.append(listed.isEmpty
                ? "commit \(DigestFormat.short(date)) \"\(r.lastSubject.oneLine.clipped(70))\""
                : "commit \(DigestFormat.short(date))")
        }
        var out = "- " + parts.joined(separator: " · ")
        for commit in listed { out += "\n  unpushed: \(commit)" }
        if !listed.isEmpty, let n = r.unpushed, n > listed.count { out += "\n  …\(n - listed.count) more" }
        return out
    }

    public static let live: Runner = { args, dir in
        guard FileManager.default.fileExists(atPath: dir),
              let result = try? execRun(git, ["--no-optional-locks", "-C", dir] + args, timeout: timeout),
              result.status == 0 else { return nil }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private static func parallelMap<T, R>(_ items: [T], _ transform: (T) -> R) -> [R] {
        var out = [R?](repeating: nil, count: items.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            let value = transform(items[i])
            lock.lock(); out[i] = value; lock.unlock()
        }
        return out.map { $0! }
    }
}
