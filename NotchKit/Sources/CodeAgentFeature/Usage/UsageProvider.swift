import CodeAgentShared
import Foundation
import os

/// One agent's quota source. Implementations must be safe to call from any task.
public protocol UsageProvider: Sendable {
    var agent: Agent { get }
    func fetch() async throws(UsageError) -> AgentUsage
}

// MARK: - Executable discovery

/// Finds a CLI the way Seam does: the three usual install prefixes, then `which`.
///
/// A GUI app inherits `launchd`'s minimal `PATH`, so `which` alone is not enough —
/// Homebrew's prefix is usually absent from it.
enum ExecutableLocator {
    static func find(_ name: String, home: URL) async -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin").appendingPathComponent(name),
            URL(fileURLWithPath: "/usr/local/bin").appendingPathComponent(name),
            home.appendingPathComponent(".local/bin").appendingPathComponent(name),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        guard let output = await ProcessRunner.output(
            executable: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: [name],
            timeout: .seconds(5)
        ) else { return nil }

        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

// MARK: - Running a short-lived command

/// `Process` and `Pipe` are not `Sendable`, and there is no async replacement in
/// Foundation. This box is the one `@unchecked Sendable` in the module: the process is
/// configured and launched on the calling task and afterwards only `terminate()`,
/// `waitUntilExit()` and reads on the *reading* end of a pipe are used — all documented
/// as safe to call from another thread — so the unchecked promise holds.
final class ProcessBox: @unchecked Sendable {
    /// How long a terminated process is given to exit before it is killed outright.
    static let terminationGrace: TimeInterval = 2

    let process = Process()
    let stdout = Pipe()
    let stdin = Pipe()

    private struct State: Sendable {
        var timedOut = false
        var launched = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// True once the watchdog killed the process, so callers can report a timeout
    /// rather than "closed before answering".
    var timedOut: Bool { lock.withLock { $0.timedOut } }

    func launch(_ executable: URL, arguments: [String], attachStdin: Bool) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        // `/dev/null` rather than a `Pipe()` nobody reads: a child that writes more than one
        // pipe buffer of diagnostics to stderr blocks forever on the write, and the app then
        // waits out the whole watchdog for an answer that was already on its way.
        process.standardError = FileHandle.nullDevice
        if attachStdin { process.standardInput = stdin }
        try process.run()
        lock.withLock { $0.launched = true }
    }

    func terminate(dueToTimeout: Bool = false) {
        if dueToTimeout { lock.withLock { $0.timedOut = true } }
        guard lock.withLock({ $0.launched }), process.isRunning else { return }
        process.terminate()
    }

    /// Terminates the child and reaps it, so every exit path leaves no zombie behind.
    ///
    /// SIGTERM is a request: `codex app-server` in the middle of a network call does not
    /// always honour it, so after ``terminationGrace`` the process is killed outright. The
    /// closing `waitUntilExit` is what actually reaps the entry from the process table.
    ///
    /// Blocking — call it only from ``ProcessQueue``.
    func reap() {
        guard lock.withLock({ $0.launched }) else { return }
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(Self.terminationGrace)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    func write(_ line: String) throws {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    /// Blocking read of one `\n`-terminated line; `nil` at EOF.
    func readLine(buffer: inout Data) -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    func readAllOutput() -> Data {
        (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
    }
}

/// The one thread every blocking `Process` call is allowed to occupy.
///
/// Pipe reads and `waitUntilExit()` block, and the cooperative pool has exactly one thread
/// per core with no way to reclaim a blocked one: a CLI that hangs for the whole watchdog
/// would take a core's worth of concurrency with it — `Task.detached` does not change that,
/// it only picks which pool thread is lost. A dedicated serial queue cannot starve anything
/// else, and serializing the exchanges costs nothing: they are seconds apart.
enum ProcessQueue {
    private static let queue = DispatchQueue(label: "app.notch.code.process", qos: .utility)

    /// Runs one blocking body on the process queue. Never call it from inside another
    /// `ProcessQueue.run` — the queue is serial, and that would deadlock.
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }
}

enum ProcessRunner {
    /// Runs a command to completion and returns its stdout, or `nil` if it could not be
    /// launched. A run that exceeds `timeout` is terminated and yields whatever it wrote.
    static func output(executable: URL, arguments: [String], timeout: Duration) async -> String? {
        let box = ProcessBox()
        do {
            try box.launch(executable, arguments: arguments, attachStdin: false)
        } catch {
            return nil
        }

        let watchdog = Task {
            try await Task.sleep(for: timeout)
            box.terminate(dueToTimeout: true)
        }

        let data = await ProcessQueue.run { box.readAllOutput() }
        watchdog.cancel()
        await ProcessQueue.run { box.reap() }

        return String(data: data, encoding: .utf8)
    }
}

enum UsageLog {
    static func logger(_ category: String) -> Logger {
        Logger(subsystem: "app.notch", category: "code.usage.\(category)")
    }
}
