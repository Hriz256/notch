import Foundation

// notch-hook — a tiny bridge between coding-agent hook processes and the Notch app.
//
// Usage: notch-hook <claude|codex|cursor> [payload] [--debug]
//
// The agent CLI spawns this on every hook event, so the whole process must be
// cheap: Foundation only, no networking, no app kit, and a hard 1 s watchdog so
// a wedged notification centre can never stall the agent.

private enum Hook {
    static let notificationName = Notification.Name("app.notch.agent.event")
    static let knownAgents: Set<String> = ["claude", "codex", "cursor"]
    /// Maximum number of stdin bytes kept; anything beyond this is discarded.
    static let payloadByteLimit = 64 * 1024
    /// Strings longer than this inside verbose keys are clipped before posting.
    static let stringLengthLimit = 2048
    /// Top-level keys whose (possibly nested) string values get clipped.
    static let verboseKeys = [
        "tool_input",
        "tool_response",
        "message",
        "last_assistant_message",
        "last-assistant-message",
    ]
    static let watchdogSeconds = 1.0
}

/// Reads stdin to EOF, keeping at most `limit` bytes. Returns empty data when
/// stdin is a terminal (no payload was piped in).
private func readStandardInput(limit: Int) -> Data {
    let fd = FileHandle.standardInput.fileDescriptor
    guard isatty(fd) == 0 else { return Data() }

    let chunkSize = 16 * 1024
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    var collected = Data()

    while true {
        let bytesRead = buffer.withUnsafeMutableBytes { raw -> Int in
            read(fd, raw.baseAddress, chunkSize)
        }
        if bytesRead < 0 {
            if errno == EINTR { continue }
            break
        }
        if bytesRead == 0 { break }
        // Past the limit the remainder is drained and discarded rather than
        // left unread: bailing out early would hand the agent an EPIPE.
        if collected.count < limit {
            collected.append(contentsOf: buffer[0..<bytesRead])
        }
    }

    return collected.count > limit ? Data(collected.prefix(limit)) : collected
}

/// Clips over-long strings. `depth` bounds how far into nested containers the
/// walk goes (1 = the value itself plus one level of dictionary/array).
private func clippingLongStrings(_ value: Any, depth: Int) -> Any {
    if let string = value as? String {
        guard string.count > Hook.stringLengthLimit else { return string }
        return String(string.prefix(Hook.stringLengthLimit)) + "…"
    }
    guard depth > 0 else { return value }
    if let dictionary = value as? [String: Any] {
        var clipped = dictionary
        for (key, nested) in dictionary {
            clipped[key] = clippingLongStrings(nested, depth: depth - 1)
        }
        return clipped
    }
    if let array = value as? [Any] {
        return array.map { clippingLongStrings($0, depth: depth - 1) }
    }
    return value
}

/// Normalises a raw hook payload: when it is a JSON object the verbose keys are
/// clipped, Claude gets its terminal recorded, and the result is re-serialised
/// compactly. Anything that is not a JSON object is forwarded verbatim.
private func normalizedPayload(raw: String, agent: String, terminal: String?) -> String {
    guard
        let data = raw.data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data),
        var object = parsed as? [String: Any]
    else { return raw }

    if agent == "claude", let terminal, !terminal.isEmpty {
        object["sourceApp"] = terminal
    }
    for key in Hook.verboseKeys where object[key] != nil {
        object[key] = clippingLongStrings(object[key]!, depth: 1)
    }

    guard
        let encoded = try? JSONSerialization.data(withJSONObject: object),
        let string = String(data: encoded, encoding: .utf8)
    else { return raw }
    return string
}

private func writeToStandardError(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}

// Watchdog: whatever happens below, the process is gone within a second.
DispatchQueue.global().asyncAfter(deadline: .now() + Hook.watchdogSeconds) {
    exit(0)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else { exit(0) }

let agent = arguments[1]
guard Hook.knownAgents.contains(agent) else { exit(0) }

let extraArguments = arguments.dropFirst(2)
let isDebug = extraArguments.contains("--debug")
let inlinePayload = extraArguments.first { $0 != "--debug" }

var rawPayload = String(decoding: readStandardInput(limit: Hook.payloadByteLimit), as: UTF8.self)
if rawPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let inlinePayload {
    // Codex's legacy `notify` hands the JSON over as an argument, not on stdin.
    rawPayload = inlinePayload
}

let payload = normalizedPayload(
    raw: rawPayload,
    agent: agent,
    terminal: ProcessInfo.processInfo.environment["TERM_PROGRAM"]
)

let userInfo: [String: String] = ["agent": agent, "payload": payload]
if isDebug {
    writeToStandardError("notch-hook posting: \(userInfo)")
}

DistributedNotificationCenter.default().postNotificationName(
    Hook.notificationName,
    object: nil,
    userInfo: userInfo,
    deliverImmediately: true
)

exit(0)
