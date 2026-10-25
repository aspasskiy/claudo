import Foundation

/// The local `claude` CLI, which every model call goes through: the Claude subscription pays, no API key.
public enum ClaudeCLI {
    /// GUI apps don't inherit the shell PATH, so look in the usual install spots.
    public static var path: String? {
        candidates.map { $0 + "/claude" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The folders `path` looks in, in order; `PlannerError.cliNotFound` names them.
    static let candidates = [
        "\(Paths.home.path)/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(Paths.home.path)/.claude/local",
    ]

    /// What `claude -p --output-format json` printed: the structured answer and what the call cost.
    struct Envelope {
        let answer: Data
        let costUSD: Double?
        /// The rest of claude's report: duration, turns, usage with thinking tokens, per-model cost.
        var stats: [String: Any] = [:]
    }

    /// One `claude -p` call whose answer must match `schema`, with `input` on stdin. Blocking: call off the
    /// main thread. The call runs in its own folder in the data dir, which keeps project CLAUDE.md files out,
    /// and leaves no session behind, so it never shows up in the next digest; no tools, MCP servers or slash
    /// commands load. `what` names the answer and `who` the one that might not answer, for the errors.
    static func ask(_ input: String, model: String, effort: String, system: String, schema: String,
                    timeout: TimeInterval, expecting what: String, who: String = "claude") throws -> Envelope {
        guard let claude = path else { throw PlannerError.cliNotFound }
        let work = BoardStore.directory.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let args = [
            "-p", "--model", model, "--effort", effort,
            "--no-session-persistence", "--strict-mcp-config", "--tools", "", "--disable-slash-commands",
            "--system-prompt", system,
            "--output-format", "json", "--json-schema", schema,
        ]
        let output: ExecResult
        do {
            output = try execRun(claude, args, stdin: Data(input.utf8), cwd: work, timeout: timeout)
        } catch is ExecTimeout {
            throw PlannerError.timedOut(who: who, timeout: timeout)
        }
        return try envelope(output, what: what)
    }

    static func envelope(_ output: ExecResult, what: String = "plan") throws -> Envelope {
        guard let obj = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
            let tail = output.err.isEmpty ? String(decoding: output.stdout.suffix(400), as: UTF8.self) : output.err
            throw PlannerError.exited(status: output.status, output: tail)
        }
        if obj["is_error"] as? Bool == true {
            throw PlannerError.failed(obj["result"] as? String ?? "error")
        }
        guard let structured = obj["structured_output"] as? [String: Any],
              let answer = try? JSONSerialization.data(withJSONObject: structured) else {
            throw PlannerError.noAnswer(what: what, result: obj["result"] as? String ?? "")
        }
        let stats = obj.filter { $0.key != "result" && $0.key != "structured_output" }
        return Envelope(answer: answer, costUSD: obj["total_cost_usd"] as? Double, stats: stats)
    }
}
