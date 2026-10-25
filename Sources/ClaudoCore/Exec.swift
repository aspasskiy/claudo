import Foundation

struct ExecResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var err: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct ExecTimeout: Error {}

/// Runs a binary synchronously with a hard timeout. stdin is fed and both
/// pipes are drained on their own threads, so a large prompt can't deadlock
/// against a chatty child. Call off the main thread.
func execRun(_ path: String, _ args: [String], stdin: Data? = nil, cwd: URL? = nil,
             timeout: TimeInterval) throws -> ExecResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    var env = ProcessInfo.processInfo.environment
    // A launchd-started app has a bare PATH; claude shells out to git and friends.
    env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    p.environment = env
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    let input = stdin.map { _ in Pipe() }
    p.standardInput = input ?? FileHandle.nullDevice
    try p.run()

    var outData = Data(), errData = Data()
    let group = DispatchGroup()
    if let input, let stdin {
        DispatchQueue.global().async {
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }
    }
    group.enter()
    DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = group.wait(timeout: .now() + 1)
        throw ExecTimeout()
    }
    p.waitUntilExit()
    return ExecResult(status: p.terminationStatus, stdout: outData, stderr: errData)
}
