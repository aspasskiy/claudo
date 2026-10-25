@testable import ClaudoCore
import Foundation

/// Small builders with realistic content, so each test states only what it's about.
enum F {
    static let now = ISO8601DateFormatter().date(from: "2026-10-18T09:00:00Z")!
    static let day: TimeInterval = 86400

    static func area(_ id: String, _ name: String, weight: Weight = .active, color: AreaColor = .blue,
                     symbol: String = "printer.fill", status: String = "Work in progress",
                     outcome: String = "") -> Area {
        Area(id: id, name: name, symbol: symbol, color: color, weight: weight, status: status, outcome: outcome)
    }

    static let atlas = area("atlas", "Atlas", weight: .focus, color: .coral, symbol: "iphone",
                            status: "Release 2.0 stuck on two rounds of fixes",
                            outcome: "Release 2.0 without regressions")
    static let move = area("move", "The move", weight: .focus, color: .teal, symbol: "airplane",
                           status: "Emails to Dana and the landlord not sent", outcome: "The bank's answer on 31.12")
    static let garden = area("garden", "Garden", weight: .active, color: .purple, symbol: "gamecontroller.fill",
                             status: "The winter level is in review", outcome: "")

    static func task(_ id: String, _ title: String, area: String = "atlas", status: TaskStatus = .todo,
                     priority: Priority = .high, when: When = .week, estimate: Double? = 2, origin: Origin = .claude,
                     pinned: Set<Field> = [], createdAt: Date = now - day, completedAt: Date? = nil,
                     sessionId: String? = nil, cwd: String? = nil, advice: Advice? = nil, isNew: Bool = false) -> TaskItem {
        TaskItem(id: id, title: title, note: "A note", area: area, status: status, priority: priority, when: when,
                 estimate: estimate, rank: 0, sessionId: sessionId, cwd: cwd, origin: origin, createdAt: createdAt,
                 updatedAt: completedAt ?? createdAt, completedAt: completedAt, isNew: isNew, pinned: pinned,
                 advice: advice)
    }

    static func planned(_ id: String, _ title: String, area: String = "atlas", status: TaskStatus = .todo,
                        priority: Priority = .high, when: When = .today, estimate: Double = 2,
                        note: String = "Do it and check it", sessionId: String = "",
                        cwd: String? = nil) -> PlanResult.PlannedTask {
        .init(id: id, title: title, note: note, area: area, status: status, priority: priority, when: when,
              estimate: estimate, sessionId: sessionId, cwd: cwd)
    }

    static func result(areas: [Area] = [atlas, move, garden], tasks: [PlanResult.PlannedTask] = [],
                       closed: [PlanResult.ClosedTask] = [],
                       focus: String = "Atlas and the move; Garden with what's left")
        -> PlanResult {
        PlanResult(focus: focus, areas: areas, tasks: tasks, closed: closed, generatedAt: now, model: "sonnet",
                   sessionCount: 119, costUSD: 0.45)
    }

    static func board(areas: [Area] = [atlas, move, garden], tasks: [TaskItem] = []) -> Board {
        Board(focus: "The old focus", areas: areas, tasks: tasks, plannedAt: now - day, model: "sonnet",
              sessionCount: 100, costUSD: 0.4)
    }

    static func session(_ id: String, cwd: String) -> SessionDigest {
        SessionDigest(id: id, cwd: cwd, folder: FileManager.default.temporaryDirectory, title: "A session",
                      start: now - 3600, end: now, prompts: ["do it"], lastReply: "done", awaitingReply: false)
    }
}
