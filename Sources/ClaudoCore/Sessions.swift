import Foundation

/// What one Claude Code session says about the owner's work: their own prompts, the assistant's last
/// reply and Claude Code's own recap. Tool traffic and subagents are left out.
public struct SessionDigest: Sendable {
    public let id: String
    public let cwd: String
    /// The ~/.claude/projects/<encoded cwd> folder the transcript lives in (holds memory/).
    public let folder: URL
    public let title: String?
    public let start: Date
    public let end: Date
    public let prompts: [String]
    public let lastReply: String
    /// The owner's last prompt got no text reply (interrupted, crashed or still running).
    public let awaitingReply: Bool
    /// The last record of any kind, tool traffic included: a long agent run moves it while `end`, the last
    /// prompt or text reply, stands still.
    public var lastRecord: Date? = nil
    /// When the owner last wrote in it.
    public var lastPrompt: Date? = nil
    /// The turn the owner's last prompt started isn't over: no reply yet, or the agent went on with tools
    /// after its last text (records come a content block each, so a run writes "checking…" and keeps going).
    /// An interrupt or a final text ends it.
    public var turnOpen = false
    /// How many of `prompts` the owner typed while an agent was busy: Claude Code queues those and writes
    /// them as attachments, not user records.
    public var queuedCount = 0
    /// Claude Code's recap of where the session stands ("away summary", written once the owner has left
    /// the terminal), when it came after their last prompt: an older one describes a state they have left.
    public var recap: String? = nil

    /// What the session cache keys on: words queued mid-turn don't send a cached session back to the
    /// summarizer.
    public var typedPromptCount: Int { prompts.count - queuedCount }
}

public enum Sessions {
    /// Top-level transcripts under ~/.claude/projects touched in the last `days`.
    public static func scan(days: Int, now: Date = Date()) -> [SessionDigest] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let files = transcripts { $0 >= cutoff }
        var result = [SessionDigest?](repeating: nil, count: files.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let d = parse(files[i], since: cutoff)
            lock.lock(); result[i] = d; lock.unlock()
        }
        return result.compactMap { $0 }.sorted { $0.end > $1.end }
    }

    /// Sessions the owner wrote in after `date`: what a plan made then hasn't seen. Agents still busy with
    /// older prompts don't count, and only transcripts written to since are read.
    public static func promptedSince(_ date: Date) -> Int {
        transcripts { $0 > date }
            .filter { url in parse(url, since: date)?.lastPrompt.map { $0 > date } ?? false }.count
    }

    /// The .jsonl files directly in each project folder whose modification date passes `keep`.
    private static func transcripts(modified keep: (Date) -> Bool) -> [URL] {
        let fm = FileManager.default
        let key = URLResourceKey.contentModificationDateKey
        var files: [URL] = []
        for dir in (try? fm.contentsOfDirectory(at: Paths.projects, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [key])) ?? []
            where f.pathExtension == "jsonl" {
                if let m = (try? f.resourceValues(forKeys: [key]))?.contentModificationDate, keep(m) { files.append(f) }
            }
        }
        return files
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Lines bigger than this are tool output or pasted blobs, never a prompt worth reading.
    private static let maxLine = 256 * 1024

    static func parse(_ url: URL, since cutoff: Date) -> SessionDigest? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var title: String?
        var prompts: [(at: Date, text: String, queued: Bool)] = []
        var lastReply = ""
        var awaiting = false
        var turnOpen = false
        var cwd: String?
        var first: Date?, last: Date?, lastRecord: Date?
        var recap: (at: Date?, text: String)?

        func took(_ text: String, at ts: Date?, cwd recordCwd: String?, queued: Bool) {
            cwd = recordCwd ?? cwd
            if let ts {
                first = first ?? ts
                last = ts
                prompts.append((ts, text, queued))
            }
            awaiting = true
            turnOpen = true
        }

        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var lineStart = 0
            let bytes = buf.bindMemory(to: UInt8.self)
            for i in 0...bytes.count {
                guard i == bytes.count || bytes[i] == 0x0A else { continue }
                defer { lineStart = i + 1 }
                let len = i - lineStart
                guard len > 2, len < maxLine else { continue }
                let line = Data(bytes: buf.baseAddress! + lineStart, count: len)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                if type == "ai-title", let t = obj["aiTitle"] as? String { title = t; continue }
                if obj["isSidechain"] as? Bool == true { continue }
                let ts = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }
                if type == "system", obj["subtype"] as? String == "away_summary", let text = obj["content"] as? String {
                    recap = (ts, text)
                    continue
                }
                // What the owner types while an agent works; other sessions' messages come the same way, as "peer".
                if type == "attachment" {
                    guard let a = obj["attachment"] as? [String: Any], a["type"] as? String == "queued_command",
                          a["commandMode"] as? String == "prompt",
                          (a["origin"] as? [String: Any])?["kind"] as? String == "human",
                          let text = textContent(a["prompt"]).flatMap(prompt) else { continue }
                    if let ts { lastRecord = max(lastRecord ?? ts, ts) }
                    took(text, at: ts, cwd: obj["cwd"] as? String, queued: true)
                    continue
                }
                guard type == "user" || type == "assistant" else { continue }
                if obj["isMeta"] as? Bool == true || obj["isCompactSummary"] as? Bool == true { continue }
                if let ts { lastRecord = max(lastRecord ?? ts, ts) }
                let message = obj["message"] as? [String: Any]
                let text = textContent(message?["content"])
                if type == "user" {
                    if text?.hasPrefix("[Request interrupted") == true { turnOpen = false }
                    // tool_result lists carry no text blocks and fall out here.
                    guard let text = text.flatMap(prompt) else { continue }
                    took(text, at: ts, cwd: obj["cwd"] as? String, queued: false)
                } else {
                    if let text, !text.isEmpty {
                        lastReply = text
                        if let ts { last = max(last ?? ts, ts) }
                        awaiting = false
                        turnOpen = false
                    }
                    if callsTools(message?["content"]) { turnOpen = true }
                }
            }
        }

        // A queued prompt that was then sent the ordinary way is there twice.
        let typed = Set(prompts.filter { !$0.queued }.map(\.text))
        prompts.removeAll { $0.queued && typed.contains($0.text) }
        guard let cwd, let first, let last, last >= cutoff, !prompts.isEmpty else { return nil }
        let lastPrompt = prompts.last?.at
        var fresh: String?
        if let recap, let at = recap.at, let lastPrompt, at >= lastPrompt { fresh = cleanRecap(recap.text) }
        return SessionDigest(
            id: url.deletingPathExtension().lastPathComponent,
            cwd: cwd, folder: url.deletingLastPathComponent(), title: title, start: first, end: last,
            prompts: prompts.map(\.text), lastReply: lastReply, awaitingReply: awaiting, lastRecord: lastRecord,
            lastPrompt: lastPrompt, turnOpen: turnOpen, queuedCount: prompts.filter(\.queued).count, recap: fresh
        )
    }

    /// One line, without the "(disable recaps in /config)" every recap ends with.
    static func cleanRecap(_ text: String) -> String? {
        let line = text.replacingOccurrences(of: #"\s*\(disable recaps[^)]*\)\s*$"#, with: "",
                                             options: .regularExpression).oneLine
        return line.isEmpty ? nil : line
    }

    /// An assistant record that calls a tool (the client's or the server's).
    private static func callsTools(_ content: Any?) -> Bool {
        (content as? [[String: Any]])?.contains { ($0["type"] as? String)?.hasSuffix("tool_use") == true } ?? false
    }

    private static func textContent(_ content: Any?) -> String? {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The owner's words in a user record, or nil for what isn't a prompt: slash-command echoes, task
    /// notifications and hook output all start with a tag. A paste is a prompt too (`unwrapPastes`).
    static func prompt(_ text: String) -> String? {
        if text.hasPrefix("<pasted_content") {
            let unwrapped = unwrapPastes(text)
            return unwrapped.isEmpty ? nil : unwrapped
        }
        guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("[Request interrupted"),
              !text.hasPrefix("Caveat:") else { return nil }
        return text
    }

    /// `<pasted_content id="b313">\n…\n</pasted_content id="b313">\n\n what does this mean?` → the owner's own
    /// words first, then what they pasted, without the tags: the question survives the digest's clip.
    static func unwrapPastes(_ text: String) -> String {
        var own: [String] = [], pasted: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: #"<pasted_content[^>]*>"#, options: .regularExpression) {
            own.append(String(rest[..<open.lowerBound]))
            rest = rest[open.upperBound...]
            if let close = rest.range(of: #"</pasted_content[^>]*>"#, options: .regularExpression) {
                pasted.append(String(rest[..<close.lowerBound]))
                rest = rest[close.upperBound...]
            } else {
                pasted.append(String(rest))
                rest = ""
            }
        }
        own.append(String(rest))
        let parts = own + pasted
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
