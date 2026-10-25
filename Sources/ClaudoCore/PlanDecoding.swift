import Foundation

/// The plan call's answer → `PlanResult`.
extension Planner {
    /// `claude -p` stdout → PlanResult, for tests and offline replays.
    static func decode(stdout: Data, sessions: [SessionDigest]?, model: String, now: Date) throws -> PlanResult {
        let envelope = try ClaudeCLI.envelope(ExecResult(status: 0, stdout: stdout, stderr: Data()))
        return try decode(answer: envelope.answer, sessions: sessions, model: model, costUSD: envelope.costUSD,
                          now: now)
    }

    /// The model's answer → PlanResult. Lenient: the schema reaches the model as a tool definition,
    /// so an odd enum value or a missing field must degrade gracefully, not sink the whole run.
    /// `sessions == nil` skips session validation (replaying a saved answer offline).
    public static func decode(answer: Data, sessions: [SessionDigest]?, model: String, costUSD: Double?,
                              now: Date) throws -> PlanResult {
        let raw: RawAnswer
        do {
            raw = try JSONDecoder().decode(RawAnswer.self, from: answer)
        } catch {
            throw PlannerError.unreadablePlan(error.localizedDescription)
        }
        guard !raw.areas.isEmpty else { throw PlannerError.emptyPlan }

        let palette = AreaColor.allCases.filter { $0 != .graphite }
        var areaIDs = Set<String>()
        let areas: [Area] = raw.areas.enumerated().compactMap { i, a in
            let name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = slug(a.id.isEmpty ? name : a.id)
            guard !id.isEmpty, !name.isEmpty, areaIDs.insert(id).inserted else { return nil }
            // Clamped before Int(): a huge value would trap in the conversion.
            return Area(id: id, name: name,
                        symbol: Area.symbols.contains(a.symbol) ? a.symbol : Merge.placeholderSymbol,
                        color: AreaColor(rawValue: a.color) ?? palette[i % palette.count],
                        weight: Weight(rawValue: a.weight) ?? .active, status: a.status, outcome: a.outcome,
                        attention: a.attention.map { Int(min(100, max(0, $0.rounded()))) })
        }

        // Explicit closings first: their reasons beat a bare "done" left among the open tasks.
        var closedIDs = Set<String>()
        var closed: [PlanResult.ClosedTask] = []
        for c in raw.closed where !c.id.isEmpty && closedIDs.insert(c.id).inserted {
            closed.append(.init(id: c.id, status: c.status == "dropped" ? .dropped : .done, reason: c.reason))
        }

        var taskIDs = Set<String>()
        var tasks: [PlanResult.PlannedTask] = []
        for t in raw.tasks {
            let id = t.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.title.isEmpty, id.isEmpty || taskIDs.insert(id).inserted else { continue }
            let status = TaskStatus(rawValue: t.status) ?? .todo
            // A finished task listed among the open ones is a closing in the wrong place.
            if !status.isOpen {
                if !id.isEmpty, closedIDs.insert(id).inserted {
                    closed.append(.init(id: id, status: status, reason: ""))
                }
                continue
            }
            var sessionId = t.sessionId
            if sessionId.hasPrefix("session=") { sessionId = String(sessionId.dropFirst("session=".count)) }
            var cwd: String?
            if let sessions, !sessionId.isEmpty {
                let source = session(sessionId, in: sessions)
                sessionId = source?.id ?? ""
                cwd = source?.cwd
            }
            let area = t.area == Area.inboxID ? t.area : slug(t.area)
            tasks.append(.init(id: id, title: t.title, note: t.note, area: area, status: status,
                               priority: priority(t.priority), when: When(rawValue: t.when) ?? .week,
                               estimate: t.estimate, sessionId: sessionId, cwd: cwd, why: t.why,
                               due: dueDay(t.due, now: now),
                               kind: TaskKind(rawValue: t.kind.lowercased()) ?? .task))
        }

        return PlanResult(focus: raw.focus, areas: areas, tasks: tasks, closed: closed, generatedAt: now,
                          model: model, sessionCount: sessions?.count ?? 0, costUSD: costUSD)
    }

    /// The session an answer names: its full id, or the short one the digest shows when only one fits.
    static func session(_ id: String, in sessions: [SessionDigest]) -> SessionDigest? {
        if let exact = sessions.first(where: { $0.id == id }) { return exact }
        guard id.count >= 6 else { return nil }
        let matches = sessions.filter { $0.id.hasPrefix(id) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// A due day as the model wrote it: yyyy-mm-dd, dd.mm.yyyy, or dd.mm in the year that puts it nearest
    /// to `now` (the later one on a tie). nil for anything else, an impossible date, or an explicit one more
    /// than half a year back — a wrong year would pin the task to Today as overdue for good.
    static func dueDay(_ raw: String, now: Date, calendar: Calendar = .current) -> Day? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // ASCII digits only ([0-9], not \d): Int() reads no other digits, and the counts are checked anyway.
        func numbers(_ pattern: String, count: Int) -> [Int]? {
            guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
            let n = text[match].split(whereSeparator: { !($0.isASCII && $0.isNumber) }).compactMap { Int($0) }
            return n.count >= count ? n : nil
        }
        // Days are Gregorian whatever the system calendar.
        let gregorian = Calendar(identifier: .gregorian)
        func valid(_ y: Int, _ m: Int, _ d: Int) -> Day? {
            DateComponents(calendar: gregorian, year: y, month: m, day: d).isValidDate
                ? Day(year: y, month: m, day: d) : nil
        }
        let today = Day(now, calendar: calendar)
        let explicit: Day?
        if let n = numbers(#"^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}"#, count: 3) {
            explicit = valid(n[0], n[1], n[2])
        } else if let n = numbers(#"^[0-9]{1,2}\.[0-9]{1,2}\.([0-9]{4}|[0-9]{2})(?![0-9])"#, count: 3) {
            explicit = valid(n[2] < 100 ? 2000 + n[2] : n[2], n[1], n[0])
        } else if let n = numbers(#"^[0-9]{1,2}\.[0-9]{1,2}(?![0-9.])"#, count: 2) {
            let year = today.year
            let candidates = [year - 1, year, year + 1].compactMap { valid($0, n[1], n[0]) }
            return candidates.min { a, b in
                let (da, db) = (abs(today.days(to: a)), abs(today.days(to: b)))
                return da != db ? da < db : a > b
            }
        } else {
            return nil
        }
        guard let day = explicit, day.days(to: today) <= 183 else { return nil }
        return day
    }

    /// An odd priority degrades to medium; "P0"–"P3" read as the four levels.
    private static func priority(_ raw: String) -> Priority {
        if let p = Priority(rawValue: raw) { return p }
        switch raw.uppercased() {
        case "P0": return .urgent
        case "P1": return .high
        case "P3": return .low
        default: return .medium
        }
    }

    /// Lowercase latin slug for ids the model left empty or wrote with spaces.
    static func slug(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? text
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        let mapped = latin.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }

    /// The answer as the model sent it: every field optional, enums as plain strings.
    private struct RawAnswer: Decodable {
        struct RawArea: Decodable {
            var id = "", name = "", symbol = "", color = "", weight = "", status = "", outcome = ""
            var attention: Double?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Key.self)
                id = c.string("id"); name = c.string("name"); symbol = c.string("symbol"); color = c.string("color")
                weight = c.string("weight"); status = c.string("status"); outcome = c.string("outcome")
                attention = c.optionalNumber("attention")
            }
        }
        struct RawTask: Decodable {
            /// Hours of the owner's attention a task may claim: more is a slip, and a huge value would trap
            /// wherever hours become an Int.
            static let maxEstimate = 24.0

            var id = "", title = "", note = "", area = "", status = "", priority = "", when = "", sessionId = ""
            var why = "", due = "", kind = ""
            var estimate = 0.0
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Key.self)
                id = c.string("id"); title = c.string("title"); note = c.string("note"); area = c.string("area")
                status = c.string("status"); priority = c.string("priority"); when = c.string("when")
                sessionId = c.string("sessionId"); estimate = min(Self.maxEstimate, max(0, c.number("estimate")))
                why = c.string("why"); due = c.string("due"); kind = c.string("kind")
            }
        }
        struct RawClosed: Decodable {
            var id = "", status = "", reason = ""
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Key.self)
                id = c.string("id"); status = c.string("status"); reason = c.string("reason")
            }
        }

        var focus = ""
        var areas: [RawArea] = []
        var tasks: [RawTask] = []
        var closed: [RawClosed] = []

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            focus = c.string("focus")
            areas = (try? c.decode([RawArea].self, forKey: Key("areas"))) ?? []
            tasks = (try? c.decode([RawTask].self, forKey: Key("tasks"))) ?? []
            closed = (try? c.decode([RawClosed].self, forKey: Key("closed"))) ?? []
        }
    }

    fileprivate struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

private extension KeyedDecodingContainer where K == Planner.Key {
    func string(_ key: String) -> String {
        ((try? decodeIfPresent(String.self, forKey: K(key))) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Numbers sometimes arrive as strings ("2.5").
    func number(_ key: String) -> Double { optionalNumber(key) ?? 0 }

    /// nil when missing, not a number, or not finite ("inf", "nan").
    func optionalNumber(_ key: String) -> Double? {
        var value = (try? decodeIfPresent(Double.self, forKey: K(key))) ?? nil
        if value == nil, let s = (try? decodeIfPresent(String.self, forKey: K(key))) ?? nil {
            value = Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
}
