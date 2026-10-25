import Foundation

/// The summarizer's note on one session.
public struct SessionSummary: Codable, Sendable, Equatable {
    public enum State: String, Codable, CaseIterable, Sendable {
        case done
        case inProgress = "in_progress"
        case blocked
        case abandoned
        case noWork = "no_work"
    }

    public var summary: String
    public var state: State
    /// 0 trivial … 4 critical.
    public var importance: Int
    /// What is left for the owner, a loose end first; at most 3.
    public var open: [String]

    public init(summary: String, state: State, importance: Int, open: [String]) {
        self.summary = summary
        self.state = state
        self.importance = importance
        self.open = open
    }
}

/// The summarizer's notes per session id, so a compaction pass only sends new or changed sessions. An entry
/// stands while the session's last record time and typed prompt count are unchanged and an accepted prompt
/// version wrote it. A file per model, so switching between them sends nothing again: sessions-cache.json
/// for Haiku, sessions-cache-<model>.json for another. Unknown keys in a saved entry are skipped on load and
/// dropped by the next save.
public struct SessionCache: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var end: Date
        public var promptCount: Int
        public var summary: SessionSummary?
        public var summaryVersion: String?

        func matches(_ s: SessionDigest) -> Bool {
            promptCount == s.typedPromptCount && abs(end.timeIntervalSince(s.end)) < 0.002
        }
    }

    public var entries: [String: Entry] = [:]
    /// Whose notes these are (`CompactMode.model`); picks the file, not saved in it.
    public var model = "haiku"

    private enum CodingKeys: String, CodingKey { case entries }

    public init(model: String = "haiku") {
        self.model = model
    }

    static func url(model: String) -> URL {
        let name = model == "haiku" ? "sessions-cache.json" : "sessions-cache-\(model).json"
        return BoardStore.directory.appendingPathComponent(name)
    }

    // Milliseconds, not ISO 8601: transcript times carry fractions of a second, and an entry
    // whose end lost them would never match its session again.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public static func load(model: String = "haiku") -> SessionCache {
        load(from: url(model: model), model: model) ?? SessionCache(model: model)
    }

    public static func load(from url: URL, model: String = "haiku") -> SessionCache? {
        guard let data = try? Data(contentsOf: url),
              var cache = try? decoder.decode(SessionCache.self, from: data) else { return nil }
        cache.model = model
        return cache
    }

    public func save() throws { try save(to: Self.url(model: model)) }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Lookups

    public func summary(for s: SessionDigest) -> SessionSummary? {
        guard let e = entries[s.id], e.matches(s), let version = e.summaryVersion,
              SessionSummarizer.acceptedVersions(model).contains(version) else { return nil }
        return e.summary
    }

    /// A session that has moved on since gets a new entry: the old one described an earlier state.
    mutating func setSummary(_ summary: SessionSummary, for s: SessionDigest) {
        entries[s.id] = Entry(end: s.end, promptCount: s.typedPromptCount, summary: summary,
                              summaryVersion: SessionSummarizer.version(model))
    }

    /// Entries for sessions that ended before `date` can't come back into a window; drop them.
    mutating func prune(endedBefore date: Date) {
        entries = entries.filter { $0.value.end >= date }
    }
}
