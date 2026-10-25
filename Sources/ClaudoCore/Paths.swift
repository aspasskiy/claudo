import Foundation

public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    /// Claude Code's transcripts: a folder per launch directory, a .jsonl per session.
    static let projects = home.appendingPathComponent(".claude/projects")
    /// The data dir: the board, the session caches and the last run's files.
    public static let support = home.appendingPathComponent("Library/Application Support/Claudo")

    /// "/Users/me/dev/atlas/web" → "atlas/web": the last two components read best.
    static func shortProject(_ cwd: String) -> String {
        let parts = cwd.split(separator: "/")
        if cwd == home.path { return "~" }
        return parts.suffix(2).joined(separator: "/")
    }

    public static func tilde(_ path: String) -> String {
        path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
    }
}
