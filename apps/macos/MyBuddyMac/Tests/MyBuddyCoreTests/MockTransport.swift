import Foundation
@testable import MyBuddyCore

/// Scripted HTTP transport that records every request.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case data(status: Int, body: String, headers: [String: String] = [:])
        case lines(status: Int, lines: [String], headers: [String: String] = [:], failAfter: (any Error)? = nil)
        case fail(any Error)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [HTTPRequestSpec] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var callCount: Int { lock.withLock { requests.count } }

    private func next(_ r: HTTPRequestSpec) -> Reply {
        lock.withLock {
            requests.append(r)
            return replies.isEmpty ? .fail(URLError(.badServerResponse)) : replies.removeFirst()
        }
    }

    func data(_ request: HTTPRequestSpec) async throws -> (HTTPResponseHead, Data) {
        switch next(request) {
        case .data(let status, let body, let headers): return (HTTPResponseHead(status: status, headers: headers), Data(body.utf8))
        case .lines(let status, let lines, let headers, _): return (HTTPResponseHead(status: status, headers: headers), Data(lines.joined(separator: "\n").utf8))
        case .fail(let e): throw e
        }
    }

    func lines(_ request: HTTPRequestSpec) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, any Error>) {
        switch next(request) {
        case .lines(let status, let lines, let headers, let failAfter):
            let stream = AsyncThrowingStream<String, any Error> { c in
                for l in lines { c.yield(l) }
                c.finish(throwing: failAfter)
            }
            return (HTTPResponseHead(status: status, headers: headers), stream)
        case .data(let status, let body, let headers):
            let stream = AsyncThrowingStream<String, any Error> { c in
                for l in body.split(separator: "\n", omittingEmptySubsequences: false) { c.yield(String(l)) }
                c.finish()
            }
            return (HTTPResponseHead(status: status, headers: headers), stream)
        case .fail(let e): throw e
        }
    }

    func bodyJSON(_ index: Int) -> [String: Any] {
        lock.withLock { (try? JSONSerialization.jsonObject(with: requests[index].body ?? Data())) as? [String: Any] ?? [:] }
    }
}

func collect(_ stream: AsyncThrowingStream<ChatEvent, any Error>) async -> (events: [ChatEvent], error: AIError?) {
    var events: [ChatEvent] = []
    do {
        for try await e in stream { events.append(e) }
        return (events, nil)
    } catch {
        return (events, error as? AIError ?? .network("\(error)"))
    }
}

func sse(_ events: [(String, String)]) -> [String] {
    events.flatMap { ["event: \($0.0)", "data: \($0.1)", ""] }
}
