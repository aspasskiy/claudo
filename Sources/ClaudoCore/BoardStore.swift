import Foundation

/// board.json in the data dir (~/Library/Application Support/Claudo unless overridden).
public enum BoardStore {
    /// Tests and `claudo-cli --data-dir` point this elsewhere.
    nonisolated(unsafe) public static var directory = Paths.support

    static var boardURL: URL { directory.appendingPathComponent("board.json") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The saved board, or an empty one before the first save. An unreadable board (a newer build's, a bad
    /// edit) is copied aside first, so the next save can't overwrite it.
    public static func load() -> Board {
        let fm = FileManager.default
        guard fm.fileExists(atPath: boardURL.path) else { return .empty }
        if let board = load(from: boardURL) { return board }
        let bad = directory.appendingPathComponent("board.unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? fm.copyItem(at: boardURL, to: bad)
        return .empty
    }

    public static func load(from url: URL) -> Board? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Board.self, from: data)
    }

    public static func save(_ board: Board) throws {
        try save(board, to: boardURL)
    }

    public static func save(_ board: Board, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(board).write(to: url, options: .atomic)
    }
}
