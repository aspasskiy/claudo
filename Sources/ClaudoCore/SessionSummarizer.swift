import Foundation

/// Short notes on sessions from Haiku or Sonnet through the local `claude` CLI, so the plan call reads less.
/// Several sessions per call; each comes back with its own state, importance and what's left open.
public struct SessionSummarizer: Sendable {
    /// Bump when the prompt or schema changes: summaries of other revisions are written again.
    static let revision = "s4"
    /// What a note's `summaryVersion` says: the model that wrote it and the prompt revision.
    static func version(_ model: String) -> String { "\(model)-\(revision)" }
    /// Versions whose notes still stand. s1 differs from s4 in emphasis, s1–s2 in not reading Claude Code's
    /// recap, s1–s3 in the prompt's language; notes are only the planner's input, so the language they are in
    /// doesn't matter, and none of it is worth summarizing a month again. Another model's notes never stand in
    /// for this one's.
    static func acceptedVersions(_ model: String) -> Set<String> {
        Set(["s1", "s2", "s3", revision].map { "\(model)-\($0)" })
    }
    /// Raw blocks per call; a block bigger than this goes alone.
    public static let batchChars = 40_000

    public var model = "haiku"
    /// `claude --effort`, pinned like the plan call's (`Planner.effort`).
    public var effort = "xhigh"
    public var timeout: TimeInterval = 300
    /// What the notes are written in: a code or a name (`PlanLanguage.name`).
    public var language = PlanLanguage.system

    public init(model: String = "haiku", effort: String = "xhigh", language: String = PlanLanguage.system) {
        self.model = model
        self.effort = effort
        self.language = language
        // More room for a bigger model.
        if model != "haiku" { timeout = 600 }
    }

    /// The rules in English; the notes in `language`.
    static func systemPrompt(language: String) -> String {
        let language = PlanLanguage.name(language)
        return """
        You write short notes on Claude Code sessions for the owner's task planner. The input holds several \
        sessions: a "## session=…" header, the owner's prompts (lines starting with ">"), sometimes a \
        "Claude Code recap" (the agent's own summary after the owner's last prompt: not a fact, check it against \
        the reply) and the assistant's last reply.

        For each session return exactly one object:
        - sessionId: the id from the session=… header, unchanged;
        - summary: up to 300 characters: what the goal was and what was done, with specifics (numbers, amounts, \
        dates, files, ids, commit hashes, people's names); no filler, no preamble;
        - state: done (the goal was reached), in_progress (work started and not finished, or next steps were \
        proposed), blocked (stuck, or waiting for someone else's answer, a review, a payment, a deploy), \
        abandoned (started and dropped), no_work (a question, a lookup, small talk: there was no work);
        - importance: 0 trivial, 1 minor, 2 ordinary, 3 important, 4 critical (money, prod, customers, legal, \
        deadlines);
        - open: up to 3 items of up to 120 characters each: what is left for the owner to do, decide or check, \
        specific, in the imperative; empty when nothing is left.

        List first in open what waits for the owner: if the assistant ended with steps only the owner can take \
        (a key, a login, a push, a payment, a signature, "I need you to …"), those steps; then any loose end: a \
        promise to someone, a payment or an invoice, a deadline, a reply to send, a check left for later, an idea \
        they wanted to keep. Be specific. A short session can hide an important loose end too.

        If the owner stopped the work ("stop", "drop it", "don't do it"), quote their words in summary verbatim, \
        in quotation marks, in the language they wrote them in.

        Only facts from the blocks, invent nothing. Write summary and open in \(language).
        """
    }

    static let answerSchema = """
    {"type":"object","additionalProperties":false,"required":["summaries"],"properties":{
      "summaries":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["sessionId","summary","state","importance","open"],
        "properties":{
          "sessionId":{"type":"string"},
          "summary":{"type":"string","description":"≤ 300 characters"},
          "state":{"type":"string","enum":["done","in_progress","blocked","abandoned","no_work"]},
          "importance":{"type":"integer","minimum":0,"maximum":4},
          "open":{"type":"array","items":{"type":"string","description":"≤ 120 characters"}}}}}}}
    """

    /// Whole raw blocks, in the given (newest-first) order, packed up to `maxChars` per batch.
    public static func batches(_ sessions: [SessionDigest], maxChars: Int = batchChars) -> [[SessionDigest]] {
        var out: [[SessionDigest]] = []
        var current: [SessionDigest] = []
        var size = 0
        for s in sessions {
            let n = s.rawBlock.count
            if !current.isEmpty, size + n > maxChars {
                out.append(current)
                current = []
                size = 0
            }
            current.append(s)
            size += n
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// One `claude -p` call. Blocking: call off the main thread.
    public func summarize(_ batch: [SessionDigest]) throws -> (summaries: [String: SessionSummary], costUSD: Double?) {
        let input = "Sessions: \(batch.count)\n" + batch.map(\.rawBlock).joined()
        let envelope = try ClaudeCLI.ask(input, model: model, effort: effort,
                                         system: Self.systemPrompt(language: language), schema: Self.answerSchema,
                                         timeout: timeout, expecting: "summaries", who: model.capitalized)
        return (try Self.decode(answer: envelope.answer, ids: Set(batch.map(\.id)), model: model), envelope.costUSD)
    }

    /// `claude -p` stdout → summaries by session id; for tests and replays.
    static func decode(stdout: Data, ids: Set<String>) throws -> [String: SessionSummary] {
        let envelope = try ClaudeCLI.envelope(ExecResult(status: 0, stdout: stdout, stderr: Data()), what: "summaries")
        return try decode(answer: envelope.answer, ids: ids)
    }

    /// Lenient like the plan decoder: odd enums and over-long text degrade, unknown or repeated
    /// session ids are ignored, and a session missing from the answer simply stays unsummarized.
    static func decode(answer: Data, ids: Set<String>, model: String = "haiku") throws -> [String: SessionSummary] {
        guard let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
              let items = object["summaries"] as? [[String: Any]] else {
            throw PlannerError.noSummaries(model: model)
        }
        var out: [String: SessionSummary] = [:]
        for item in items {
            let id = (item["sessionId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = Merge.cap(item["summary"] as? String ?? "", 300)
            guard ids.contains(id), out[id] == nil, !text.isEmpty else { continue }
            let open = (item["open"] as? [Any] ?? []).compactMap { $0 as? String }
                .map { Merge.cap($0, 120) }.filter { !$0.isEmpty }
            let state = (item["state"] as? String).flatMap(SessionSummary.State.init(rawValue:)) ?? .inProgress
            out[id] = SessionSummary(summary: text, state: state, importance: importance(item["importance"]),
                                     open: Array(open.prefix(3)))
        }
        return out
    }

    private static func importance(_ value: Any?) -> Int {
        let raw: Double? = switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
        return min(4, max(0, Int((raw ?? 2).rounded())))
    }
}
