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
    let process = Process()
    let stdout = Pipe()
    let stdin = Pipe()
    private let lock = OSAllocatedUnfairLock(initialState: false)

    /// True once the watchdog killed the process, so callers can report a timeout
    /// rather than "closed before answering".
    var timedOut: Bool { lock.withLock { $0 } }

    func launch(_ executable: URL, arguments: [String], attachStdin: Bool) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = Pipe()
        if attachStdin { process.standardInput = stdin }
        try process.run()
    }

    func terminate(dueToTimeout: Bool = false) {
        if dueToTimeout { lock.withLock { $0 = true } }
        guard process.isRunning else { return }
        process.terminate()
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

    func waitUntilExit() {
        process.waitUntilExit()
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
        defer { watchdog.cancel() }

        let data = await Task.detached(priority: .utility) { () -> Data in
            let data = box.readAllOutput()
            box.waitUntilExit()
            return data
        }.value

        return String(data: data, encoding: .utf8)
    }
}

enum UsageLog {
    static func logger(_ category: String) -> Logger {
        Logger(subsystem: "app.notch", category: "code.usage.\(category)")
    }
}
