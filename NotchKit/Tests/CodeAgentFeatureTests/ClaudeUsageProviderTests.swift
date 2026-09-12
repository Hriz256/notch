import CodeAgentShared
import Foundation
import Testing
import os
@testable import CodeAgentFeature

/// Captures the outgoing request and answers it locally, so nothing leaves the machine.
private final class CapturingProtocol: URLProtocol {
    struct Capture: Sendable {
        var userAgent: String?
        var cachePolicy: URLRequest.CachePolicy?
    }

    nonisolated(unsafe) static let captured = OSAllocatedUnfairLock(initialState: Capture())

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let capture = Capture(
            userAgent: request.value(forHTTPHeaderField: "User-Agent"),
            cachePolicy: request.cachePolicy
        )
        Self.captured.withLock { $0 = capture }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct ClaudeUsageProviderTests {

    /// `claude --version` boots Node and is budgeted 20 s. Resolving it on the fetch path
    /// would delay the first usage bars of every cold launch by that much, so the request
    /// must go out immediately with the fallback UA and pick the real version up later.
    @Test func fetchDoesNotWaitForTheVersionDetector() async {
        CapturingProtocol.captured.withLock { $0 = .init() }
        let provider = ClaudeUsageProvider(
            session: CapturingProtocol.session(),
            home: URL(fileURLWithPath: "/nonexistent"),
            claudeVersion: {
                // Far longer than any acceptable fetch: if `fetch()` awaited this, the
                // test would time out rather than fail.
                try? await Task.sleep(for: .seconds(30))
                return "9.9.9"
            },
            credentials: { _, _ in .success(.init(accessToken: "sk-ant-oat-x", expiresAt: nil)) }
        )

        let started = ContinuousClock.now
        _ = try? await provider.fetch()
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(5))
        let captured = CapturingProtocol.captured.withLock { $0 }
        #expect(captured.userAgent == "claude-code/\(ClaudeVersionDetector.fallback)")
        // Quota is the one thing that must never come back out of a cache.
        #expect(captured.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func notSignedInShortCircuitsBeforeAnyRequest() async {
        CapturingProtocol.captured.withLock { $0 = .init() }
        let provider = ClaudeUsageProvider(
            session: CapturingProtocol.session(),
            home: URL(fileURLWithPath: "/nonexistent"),
            claudeVersion: { ClaudeVersionDetector.fallback },
            credentials: { _, _ in .failure(.notSignedIn) }
        )

        await #expect(throws: UsageError.notSignedIn) { try await provider.fetch() }
        #expect(CapturingProtocol.captured.withLock { $0.userAgent } == nil)
    }
}

struct ClaudeVersionDetectorTests {
    @Test func extractsTheSemverClaudePrints() {
        #expect(ClaudeVersionDetector.semver(in: "2.1.258 (Claude Code)") == "2.1.258")
        #expect(ClaudeVersionDetector.semver(in: "  1.0.0\n") == "1.0.0")
        // Only the first three-component version is taken, prefix noise and all.
        #expect(ClaudeVersionDetector.semver(in: "claude 2.1.3 (build 4.5.6)") == "2.1.3")
    }

    @Test(arguments: ["", "unknown", "2.1", "v2", "no digits here"])
    func unrecognizableOutputYieldsNothing(output: String) {
        #expect(ClaudeVersionDetector.semver(in: output) == nil)
    }

    /// The fallback only has to look like a plausible Claude Code version — that is what
    /// keeps the request out of the punitive rate-limit bucket.
    @Test func fallbackIsItselfASemver() {
        #expect(ClaudeVersionDetector.semver(in: ClaudeVersionDetector.fallback)
            == ClaudeVersionDetector.fallback)
    }
}
