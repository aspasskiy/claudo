import Foundation

/// What boils sessions down before the plan run reads them.
public enum CompactMode: String, Codable, CaseIterable, Sendable {
    case off, haiku, sonnet

    /// The `claude --model` that writes the notes; nil when nothing does.
    public var model: String? {
        switch self {
        case .off: nil
        case .haiku: "haiku"
        case .sonnet: "sonnet"
        }
    }

    /// "Haiku", for progress lines.
    public var name: String { (model ?? rawValue).capitalized }
}

/// What a plan run is busy with, for the running banner and the CLI.
public enum PlanStage: Sendable, Equatable {
    case scanning
    case summarizing(done: Int, total: Int)
    case planning(sessions: Int)
}

/// What the compaction pass produced for one plan run.
public struct CompactReport: Sendable {
    /// Valid summaries for the scanned sessions, cached and fresh, by session id.
    public var summaries: [String: SessionSummary] = [:]
    /// Summarized in this pass (not served from the cache).
    public var summarized: [String] = []
    /// Summarizer calls that answered, and the ones that failed.
    public var batches = 0
    public var failures = 0
    /// The list-price equivalent `claude -p` reports for those calls (paid from the subscription).
    public var costUSD = 0.0

    public init() {}
}

/// Runs the pipeline: the summarizer writes notes on the uncached sessions. The engine is a closure so tests
/// run it without the CLI.
public struct Compactor {
    public typealias Summarize = @Sendable ([SessionDigest]) throws
        -> (summaries: [String: SessionSummary], costUSD: Double?)

    public var mode: CompactMode
    /// One summarizer call per batch.
    public var summarize: Summarize?
    public var batchChars = SessionSummarizer.batchChars
    /// Summarizer calls in flight at once.
    var concurrency = 3
    /// Caps how many uncached sessions it takes (newest first), for trial runs.
    public var limit: Int?

    public init(mode: CompactMode) {
        self.mode = mode
    }

    /// The real engine: the mode's model through the local CLI, writing its notes in `language`.
    public static func live(mode: CompactMode, limit: Int? = nil, effort: String = "xhigh",
                            language: String = PlanLanguage.system) -> Compactor {
        var compactor = Compactor(mode: mode)
        compactor.limit = limit
        if let model = mode.model {
            let summarizer = SessionSummarizer(model: model, effort: effort, language: language)
            compactor.summarize = { try summarizer.summarize($0) }
        }
        return compactor
    }

    /// `sessions` newest first. Fresh results land in `cache` even when a step fails half-way.
    /// `progress` may be called from worker threads.
    public func run(_ sessions: [SessionDigest], cache: inout SessionCache,
                    progress: @escaping @Sendable (PlanStage) -> Void = { _ in }) throws -> CompactReport {
        var report = CompactReport()
        guard mode != .off else { return report }

        if let summarize {
            let need = capped(sessions.filter { cache.summary(for: $0) == nil })
            let batches = SessionSummarizer.batches(need, maxChars: batchChars)
            let outcome = Self.parallel(batches, width: concurrency,
                                        stage: { .summarizing(done: $0, total: $1) }, progress: progress,
                                        work: { try summarize($0) })
            let byID = Dictionary(need.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (_, answer) in outcome.results {
                for (id, summary) in answer.summaries {
                    guard let s = byID[id] else { continue }
                    cache.setSummary(summary, for: s)
                    report.summarized.append(id)
                }
                report.costUSD += answer.costUSD ?? 0
            }
            report.batches = outcome.results.count
            report.failures = outcome.failures
            if outcome.results.isEmpty, let error = outcome.firstError { throw error }
            for s in sessions {
                if let summary = cache.summary(for: s) { report.summaries[s.id] = summary }
            }
        }
        return report
    }

    private func capped(_ sessions: [SessionDigest]) -> [SessionDigest] {
        limit.map { Array(sessions.prefix(max(0, $0))) } ?? sessions
    }

    /// What the cache alone says, calling nothing: previews (`claudo-cli digest --compact`).
    public static func cachedReport(_ sessions: [SessionDigest], cache: SessionCache,
                                    mode: CompactMode) -> CompactReport {
        var report = CompactReport()
        guard mode != .off else { return report }
        for s in sessions {
            if let summary = cache.summary(for: s) { report.summaries[s.id] = summary }
        }
        return report
    }

    private struct Outcome<Item, Value> {
        var results: [(Item, Value)] = []
        var failures = 0
        var firstError: Error?
    }

    /// Shared by the worker operations; every access goes through `lock`.
    private final class Collector<Item, Value>: @unchecked Sendable {
        let lock = NSLock()
        var outcome = Outcome<Item, Value>()
        var done = 0
    }

    /// Runs `work` over `items`, `width` at a time. Failures are counted and skipped.
    private static func parallel<Item, Value>(_ items: [Item], width: Int,
                                              stage: @escaping @Sendable (Int, Int) -> PlanStage,
                                              progress: @escaping @Sendable (PlanStage) -> Void,
                                              work: @escaping @Sendable (Item) throws -> Value)
        -> Outcome<Item, Value> {
        guard !items.isEmpty else { return Outcome() }
        let collector = Collector<Item, Value>()
        progress(stage(0, items.count))
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, width)
        for item in items {
            let box = UncheckedBox(item)
            queue.addOperation {
                let result = Result { try work(box.value) }
                collector.lock.lock()
                switch result {
                case .success(let value):
                    collector.outcome.results.append((box.value, value))
                case .failure(let error):
                    collector.outcome.failures += 1
                    if collector.outcome.firstError == nil { collector.outcome.firstError = error }
                }
                collector.done += 1
                let count = collector.done
                collector.lock.unlock()
                progress(stage(count, items.count))
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return collector.outcome
    }
}

/// Carries a value into a worker operation; the value is only read there.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// What a compaction pass would cost before running it — `claudo-cli compact --dry-run`.
public struct CompactEstimate: Sendable, Equatable {
    /// Scanned in the window.
    public var sessions = 0
    /// Not in the cache (up to the limit): what the pass would send.
    public var toSummarize = 0
    /// The calls they take.
    public var batches = 0

    public init() {}

    public static func make(_ sessions: [SessionDigest], cache: SessionCache, mode: CompactMode,
                            limit: Int?) -> CompactEstimate {
        var e = CompactEstimate()
        e.sessions = sessions.count
        if mode != .off {
            let uncached = sessions.filter { cache.summary(for: $0) == nil }
            let need = limit.map { Array(uncached.prefix(max(0, $0))) } ?? uncached
            e.toSummarize = need.count
            e.batches = SessionSummarizer.batches(need).count
        }
        return e
    }
}

// MARK: - What the engines read

extension SessionDigest {
    /// The first prompt states the goal, the last 15 show where it went.
    var pickedPrompts: [String] {
        prompts.count > 16 ? [prompts[0]] + prompts.suffix(15) : prompts
    }

    /// One session for the summarizer, worded like the digest's blocks: title, folder, dates, first + last
    /// 15 prompts (≤ 400 chars each), Claude Code's recap, the last reply (≤ 1500).
    public var rawBlock: String {
        var block = "\n## session=\(id) · \(Paths.tilde(cwd))"
        if let title { block += " · \"\(title)\"" }
        block += " · \(DigestFormat.short(start)) → \(DigestFormat.short(end))"
        block += " · \(DigestFormat.count(prompts.count, "prompt"))"
        if awaitingReply { block += Planner.cutOff }
        block += "\n"
        let picked = pickedPrompts
        for (i, p) in picked.enumerated() {
            block += "> \(p.clipped(400).oneLine)\n"
            if i == 0, prompts.count > picked.count { block += "> \(Planner.skipped(prompts.count - picked.count))\n" }
        }
        if let recap { block += "Claude Code recap: \(recap)\n" }
        if !lastReply.isEmpty {
            block += "Assistant's last reply: \(lastReply.headTail(1500).oneLine)\n"
        }
        return block
    }
}
