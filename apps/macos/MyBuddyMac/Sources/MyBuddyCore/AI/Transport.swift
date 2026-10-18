import Foundation

public struct HTTPRequestSpec: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 60) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponseHead: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]

    public init(status: Int, headers: [String: String]) {
        self.status = status
        self.headers = headers
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Abstracts HTTP so providers can be tested without a network.
public protocol HTTPTransport: Sendable {
    func data(_ request: HTTPRequestSpec) async throws -> (HTTPResponseHead, Data)
    /// Streams the body as lines (including empty lines, which SSE uses as event boundaries).
    func lines(_ request: HTTPRequestSpec) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, any Error>)
}

/// Production transport. Does not follow redirects to a different host.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    override public init() {}

    private func urlRequest(_ spec: HTTPRequestSpec) -> URLRequest {
        var r = URLRequest(url: spec.url, timeoutInterval: spec.timeout)
        r.httpMethod = spec.method
        r.httpBody = spec.body
        for (k, v) in spec.headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    private static func head(_ response: URLResponse) -> HTTPResponseHead {
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { headers["\(k)"] = "\(v)" }
        return HTTPResponseHead(status: http?.statusCode ?? 0, headers: headers)
    }

    public func data(_ request: HTTPRequestSpec) async throws -> (HTTPResponseHead, Data) {
        let (data, response) = try await session.data(for: urlRequest(request))
        return (Self.head(response), data)
    }

    public func lines(_ request: HTTPRequestSpec) async throws -> (HTTPResponseHead, AsyncThrowingStream<String, any Error>) {
        let (bytes, response) = try await session.bytes(for: urlRequest(request))
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    var buffer = [UInt8]()
                    for try await byte in bytes {
                        if byte == 0x0A {
                            if buffer.last == 0x0D { buffer.removeLast() }
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                            if buffer.count > 1 << 20 { throw AIError.decoding("line too long") }
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (Self.head(response), stream)
    }

    // Refuse cross-host redirects so credentials never follow a redirect elsewhere.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        guard let from = task.originalRequest?.url?.host, let to = request.url?.host, from == to else { return nil }
        return request
    }
}

/// Server-Sent Events parser (WHATWG spec subset: event, data, comments; dispatch on blank line).
public struct SSEParser: Sendable {
    public struct Event: Sendable, Equatable {
        public let event: String
        public let data: String
    }

    private var eventName = ""
    private var dataLines: [String] = []

    public init() {}

    /// Feeds one line; returns an event when a blank line completes one.
    public mutating func feed(_ line: String) -> Event? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let (field, value): (Substring, Substring)
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var v = line[line.index(after: colon)...]
            if v.hasPrefix(" ") { v = v.dropFirst() }
            value = v
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }

    /// Flushes a pending event at end of stream.
    public mutating func finish() -> Event? { dispatch() }

    private mutating func dispatch() -> Event? {
        defer {
            eventName = ""
            dataLines = []
        }
        guard !dataLines.isEmpty else { return nil }
        return Event(event: eventName.isEmpty ? "message" : eventName, data: dataLines.joined(separator: "\n"))
    }
}

func parseJSONObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func jsonBody(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
}
