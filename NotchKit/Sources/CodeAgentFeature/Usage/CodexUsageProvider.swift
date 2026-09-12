import CodeAgentShared
import Foundation

/// Drives `codex app-server` over stdio JSON-RPC to read the account's rate limits.
///
/// There is no `codex usage` subcommand; the TUI's `/status` and `/usage` are backed by
/// exactly this call. Going through the app-server also means Codex resolves auth itself,
/// which matters because `~/.codex/auth.json` does not exist when the credential store is
/// `keyring` or `ephemeral`.
public final class CodexUsageProvider: UsageProvider {
    public let agent = Agent.codex

    /// Whole exchange: launch, initialize, read. Seam uses the same order of magnitude.
    private static let timeout: Duration = .seconds(10)
    private static let initializeID = 1
    private static let rateLimitsID = 2

    private let home: URL
    private let logger = UsageLog.logger("codex")

    public init(home: URL) {
        self.home = home
    }

    public func fetch() async throws(UsageError) -> AgentUsage {
        guard let executable = await ExecutableLocator.find("codex", home: home) else {
            throw UsageError.unavailable("Codex CLI not found")
        }

        let box = ProcessBox()
        do {
            try box.launch(executable, arguments: ["app-server"], attachStdin: true)
        } catch {
            throw UsageError.unavailable("Could not launch codex")
        }

        let watchdog = Task {
            try await Task.sleep(for: Self.timeout)
            box.terminate(dueToTimeout: true)
        }

        // The exchange is blocking pipe I/O, so it runs on the process queue rather than on
        // the cooperative pool. Only `Data` crosses back — `[String: Any]` is not `Sendable`.
        let reply = await ProcessQueue.run { Self.exchange(box) }
        watchdog.cancel()
        // `app-server` is a long-lived server, not a one-shot command: it exits only because
        // Notch asks it to, so the reap (and its SIGKILL escalation) is the only thing
        // standing between a failed poll and an accumulating pile of Codex processes.
        await ProcessQueue.run { box.reap() }

        guard let reply else {
            if box.timedOut {
                logger.error("codex app-server timed out")
                throw UsageError.network("app-server timeout")
            }
            throw UsageError.unavailable("Codex app-server closed before answering")
        }

        guard let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let usage = CodexRateLimitParser.parse(json, now: Date())
        else {
            throw UsageError.unavailable("No rate-limit payload")
        }
        return usage
    }

    /// Writes the three lines Codex expects and returns the raw `id: 2` response line.
    ///
    /// An unsolicited `remoteControl/status/changed` notification arrives between the two
    /// responses, so lines must be correlated by `id`, never by arrival order.
    private static func exchange(_ box: ProcessBox) -> Data? {
        var buffer = Data()
        do {
            try box.write(
                #"{"jsonrpc":"2.0","id":\#(initializeID),"method":"initialize","#
                    + #""params":{"clientInfo":{"name":"Notch","version":"1.0"}}}"#
            )
            guard awaitResponse(box, id: initializeID, buffer: &buffer) != nil else { return nil }

            // The server only accepts requests after the `initialized` notification.
            try box.write(#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#)
            try box.write(
                #"{"jsonrpc":"2.0","id":\#(rateLimitsID),"method":"account/rateLimits/read","params":{}}"#
            )
            return awaitResponse(box, id: rateLimitsID, buffer: &buffer)
        } catch {
            return nil
        }
    }

    private static func awaitResponse(_ box: ProcessBox, id: Int, buffer: inout Data) -> Data? {
        while let line = box.readLine(buffer: &buffer) {
            guard !line.isEmpty,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == id
            else { continue }
            return line
        }
        return nil
    }
}
