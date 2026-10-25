import Foundation

/// Why a plan run or a summarizer call failed. The app reads these texts to word its error line, so they
/// stay as they are.
public enum PlannerError: LocalizedError, Equatable {
    /// No `claude` executable in the usual install spots (`ClaudeCLI.path`).
    case cliNotFound
    /// `who` (claude, or the summarizer's model) didn't answer within `timeout` seconds.
    case timedOut(who: String, timeout: TimeInterval)
    /// claude printed no JSON report; `output` is its stderr, or the last 400 bytes of its stdout when stderr
    /// is empty. The message shows the first 400 characters.
    case exited(status: Int32, output: String)
    /// claude's report says it failed (a usage limit, an overload…); `result` says why.
    case failed(String)
    /// A report without the structured answer: `what` is "plan" or "summaries".
    case noAnswer(what: String, result: String)
    /// The plan isn't the JSON the schema asks for.
    case unreadablePlan(String)
    case emptyPlan
    case noSummaries(model: String)
    case noSessions(days: Int)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "claude CLI not found (looked in \(ClaudeCLI.candidates.map(Paths.tilde).joined(separator: ", ")))"
        case .timedOut(let who, let timeout): "\(who) didn't answer in \(Int(timeout / 60)) min"
        case .exited(let status, let output): "claude exited \(status): \(output.clipped(400))"
        case .failed(let result): "claude: \(result.clipped(400))"
        case .noAnswer(let what, let result): "claude returned no \(what): \(result.clipped(300))"
        case .unreadablePlan(let reason): "claude's plan didn't parse: \(reason)"
        case .emptyPlan: "claude's plan has no areas"
        case .noSummaries(let model): "\(model.capitalized) returned no summaries"
        case .noSessions(let days): "No Claude sessions in the last \(days) days"
        }
    }
}

/// Builds the digest from the board, sessions, git and project memory, and asks the local `claude` CLI
/// for a plan (`ClaudeCLI`). The digest is in Digest.swift, the prompt in PlanPrompt.swift, and reading
/// the answer in PlanDecoding.swift.
public struct Planner {
    public var model = "sonnet"
    public var days = 30
    /// Opus at xhigh takes ~9 min over a 30-day digest.
    public var timeout: TimeInterval = 900
    /// Summarize sessions first (DESIGN.md › Compaction). Off by default: it spends subscription quota in a loop.
    public var compact: CompactMode = .off
    /// `claude --effort` for the plan call. Pinned: `claude -p` otherwise takes the owner's interactive
    /// effortLevel from ~/.claude/settings.json.
    public var effort = "xhigh"
    /// The same for the compaction calls.
    public var compactEffort = "xhigh"
    /// What the model writes the board and the session notes in: a code or a name (`PlanLanguage.name`).
    /// The prompts and the digest are English whatever it is.
    public var language = PlanLanguage.system

    public init(model: String = "sonnet", days: Int = 30) {
        self.model = model
        self.days = days
    }

    /// Scans, asks Claude and returns its answer for `Merge.merge`. Blocking: call off the main thread.
    /// Leaves what it sent and what came back in the data dir (`lastDigestURL`, `lastResultURL`,
    /// `lastRunURL`). `progress` may be called from worker threads.
    public func run(board: Board, now: Date = Date(),
                    progress: @escaping @Sendable (PlanStage) -> Void = { _ in }) throws -> PlanResult {
        let started = Date()
        progress(.scanning)
        let sessions = Sessions.scan(days: days, now: now)
        guard !sessions.isEmpty else { throw PlannerError.noSessions(days: days) }
        let repos = GitState.scan(sessions: sessions, now: now)
        let scanned = Date()
        var report: CompactReport?
        if let model = compact.model {
            let compactor = Compactor.live(mode: compact, effort: compactEffort, language: language)
            var cache = SessionCache.load(model: model)
            // Whatever the pass managed is kept, even if it stops half-way.
            defer {
                cache.prune(endedBefore: now.addingTimeInterval(-60 * 86400))
                try? cache.save()
            }
            report = try compactor.run(sessions, cache: &cache, progress: progress)
        }
        let input = digest(sessions: sessions, board: board, now: now, compact: report, repos: repos)
        let compacted = Date()
        progress(.planning(sessions: sessions.count))
        // Before the call: a run that fails or times out still leaves what it sent.
        Self.saveDigest(input)
        let envelope = try ClaudeCLI.ask(input, model: model, effort: effort,
                                         system: Self.systemPrompt(language: language), schema: Self.answerSchema,
                                         timeout: timeout, expecting: "plan")
        var stats: [String: Any] = [
            "startedAt": DigestFormat.full(started), "model": model, "effort": effort, "sessions": sessions.count,
            "digestChars": input.count, "scanSeconds": Self.seconds(started, scanned),
            "compactSeconds": Self.seconds(scanned, compacted), "planSeconds": Self.seconds(compacted, Date()),
            "claude": envelope.stats,
        ]
        if let report {
            stats["compact"] = ["mode": compact.rawValue, "effort": compactEffort,
                                "summarized": report.summarized.count, "calls": report.batches,
                                "failed": report.failures, "costUSD": report.costUSD]
        }
        Self.save(stats, to: Self.lastRunURL)
        if let answer = try? JSONSerialization.jsonObject(with: envelope.answer) {
            Self.save(answer, to: Self.lastResultURL)
        }
        var result = try Self.decode(answer: envelope.answer, sessions: sessions, model: model,
                                     costUSD: envelope.costUSD, now: now)
        result.days = days
        return result
    }

    // MARK: Run files (best effort, for debugging and offline replays; the app never reads them)

    /// Exactly what the model read.
    static var lastDigestURL: URL { BoardStore.directory.appendingPathComponent("last-digest.txt") }
    /// What the model said, before merging.
    static var lastResultURL: URL { BoardStore.directory.appendingPathComponent("last-result.json") }
    /// Where the time went: seconds per stage and claude's own report.
    static var lastRunURL: URL { BoardStore.directory.appendingPathComponent("last-run.json") }

    static func saveDigest(_ text: String) {
        try? FileManager.default.createDirectory(at: BoardStore.directory, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: lastDigestURL, options: .atomic)
    }

    private static func save(_ json: Any, to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: json,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func seconds(_ from: Date, _ to: Date) -> Double {
        (to.timeIntervalSince(from) * 10).rounded() / 10
    }
}
