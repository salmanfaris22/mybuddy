import Foundation

/// A chat-model provider. Implementations never log or expose their credentials.
public protocol ChatModelProvider: Sendable {
    var config: ProviderConfig { get }
    func listModels() async throws -> [ModelDescriptor]
    func testConnection() async -> ConnectionTestResult
    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error>
}

/// Keychain-style secret storage. The Mac uses `KeychainSecretStore` (MyBuddyHost).
public protocol SecretStore: Sendable {
    func read(_ ref: SecretReference) throws -> String?
    func write(_ value: String, for ref: SecretReference) throws
    func delete(_ ref: SecretReference) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretReference: String] = [:]
    public init(_ values: [SecretReference: String] = [:]) { self.values = values }
    public func read(_ ref: SecretReference) throws -> String? { lock.withLock { values[ref] } }
    public func write(_ value: String, for ref: SecretReference) throws { lock.withLock { values[ref] = value } }
    public func delete(_ ref: SecretReference) throws { _ = lock.withLock { values.removeValue(forKey: ref) } }
}

enum ProviderHTTP {
    /// Joins an API path onto a base URL, tolerating a base that already ends in /v1.
    static func url(_ base: URL, _ path: String) -> URL {
        var b = base.absoluteString
        while b.hasSuffix("/") { b.removeLast() }
        var p = path
        if b.hasSuffix("/v1"), p.hasPrefix("/v1/") { p = String(p.dropFirst(3)) }
        return URL(string: b + p)!
    }

    static func mapTransportError(_ error: any Error, endpoint: URL) -> AIError {
        if let ai = error as? AIError { return ai }
        if error is CancellationError { return .cancelled }
        if let u = error as? URLError {
            switch u.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return .network("Can’t reach \(endpoint.host ?? "the server")\(endpoint.port.map { ":\($0)" } ?? "").")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return .network("The secure connection to \(endpoint.host ?? "the server") failed.")
            default: return .network(u.localizedDescription)
            }
        }
        return .network(error.localizedDescription)
    }

    /// Reads an error body from a line stream (bounded).
    static func collect(_ lines: AsyncThrowingStream<String, any Error>, limit: Int = 64 * 1024) async -> Data {
        var data = Data()
        do {
            for try await line in lines {
                data.append(contentsOf: line.utf8)
                data.append(0x0A)
                if data.count > limit { break }
            }
        } catch {}
        return data
    }

    static func retryAfter(_ head: HTTPResponseHead) -> TimeInterval? {
        head.header("retry-after").flatMap(TimeInterval.init)
    }

    /// Runs `body` inside a cancellable stream, mapping errors uniformly.
    static func stream(endpoint: URL, _ body: @escaping @Sendable (AsyncThrowingStream<ChatEvent, any Error>.Continuation) async throws -> Void)
        -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapTransportError(error, endpoint: endpoint))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }
    func bool(_ key: String) -> Bool? { (self[key] as? NSNumber)?.boolValue }
}
