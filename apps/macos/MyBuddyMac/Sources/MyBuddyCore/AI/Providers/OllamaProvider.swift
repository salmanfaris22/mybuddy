import Foundation

/// Ollama native API adapter (default http://127.0.0.1:11434, loopback only unless explicitly trusted).
/// GET /api/version, GET /api/tags, POST /api/show, POST /api/chat (NDJSON streaming).
public struct OllamaProvider: ChatModelProvider {
    public let config: ProviderConfig
    private let transport: any HTTPTransport

    public init(config: ProviderConfig, transport: any HTTPTransport) {
        self.config = config
        self.transport = transport
    }

    private var notRunning: AIError {
        .network("Ollama isn’t reachable at \(config.endpoint.host ?? "127.0.0.1"):\(config.endpoint.port ?? 11434). Start the Ollama app or run `ollama serve`.")
    }

    private func mapped(_ error: any Error) -> AIError {
        let e = ProviderHTTP.mapTransportError(error, endpoint: config.endpoint)
        if case .network = e { return notRunning }
        return e
    }

    public func version() async throws -> String {
        do {
            let (head, data) = try await transport.data(HTTPRequestSpec(url: ProviderHTTP.url(config.endpoint, "/api/version"), timeout: 5))
            guard head.status == 200, let v = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?.string("version") else {
                throw AIError.server(status: head.status, message: "unexpected /api/version response")
            }
            return v
        } catch { throw mapped(error) }
    }

    public func listModels() async throws -> [ModelDescriptor] {
        do {
            let (head, data) = try await transport.data(HTTPRequestSpec(url: ProviderHTTP.url(config.endpoint, "/api/tags"), timeout: 10))
            guard head.status == 200 else { throw AIError.server(status: head.status, message: Self.errorMessage(data)) }
            let models = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?.array("models") ?? []
            return models.compactMap { m -> ModelDescriptor? in
                guard let name = m.string("name") ?? m.string("model") else { return nil }
                let details = m.dict("details")
                let size = (m["size"] as? NSNumber)?.int64Value
                let detail = [details?.string("parameter_size"), details?.string("quantization_level"),
                              size.map { $0.formatted(.byteCount(style: .file)) }].compactMap { $0 }.joined(separator: " · ")
                return ModelDescriptor(id: name, detail: detail.isEmpty ? nil : detail, source: "GET /api/tags")
            }
        } catch { throw mapped(error) }
    }

    /// Context window and capabilities from /api/show (only what the server reports).
    public func modelDetails(_ name: String) async throws -> ModelDescriptor {
        do {
            let spec = HTTPRequestSpec(url: ProviderHTTP.url(config.endpoint, "/api/show"), method: "POST",
                                       headers: ["content-type": "application/json"], body: jsonBody(["model": name]), timeout: 10)
            let (head, data) = try await transport.data(spec)
            if head.status == 404 { throw AIError.modelNotFound(name) }
            guard head.status == 200, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw AIError.server(status: head.status, message: Self.errorMessage(data))
            }
            let info = json.dict("model_info") ?? [:]
            let context = info.first { $0.key.hasSuffix(".context_length") }.flatMap { ($0.value as? NSNumber)?.intValue }
            let caps = json["capabilities"] as? [String]
            return ModelDescriptor(id: name, contextWindow: context, supportsVision: caps.map { $0.contains("vision") },
                                   supportsAdaptiveThinking: nil, source: "POST /api/show")
        } catch { throw mapped(error) }
    }

    public func testConnection() async -> ConnectionTestResult {
        do {
            let v = try await version()
            let models = try await listModels()
            let message = models.isEmpty ? "Ollama \(v) is running, but no models are installed. Run `ollama pull <model>`."
                                         : "Ollama \(v) · \(models.count) local models"
            return ConnectionTestResult(outcome: .ok, message: message, testedAt: Date())
        } catch {
            return ConnectionTestResult(outcome: .failed, message: mapped(error).userMessage, testedAt: Date())
        }
    }

    static func errorMessage(_ data: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?.string("error") ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    public func streamChat(_ r: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        var messages: [[String: String]] = []
        if let system = r.system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages += r.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let body: [String: Any] = ["model": r.model, "messages": messages, "stream": true, "options": ["num_predict": r.maxOutputTokens]]
        let spec = HTTPRequestSpec(url: ProviderHTTP.url(config.endpoint, "/api/chat"), method: "POST",
                                   headers: ["content-type": "application/json"], body: jsonBody(body), timeout: 300)
        let transport = self.transport
        let model = r.model
        let notRunning = self.notRunning
        let inner = ProviderHTTP.stream(endpoint: config.endpoint) { continuation in
            let (head, lines) = try await transport.lines(spec)
            guard head.status == 200 else {
                let message = Self.errorMessage(await ProviderHTTP.collect(lines))
                if head.status == 404 { throw AIError.modelNotFound(model) }
                throw AIError.server(status: head.status, message: message)
            }
            continuation.yield(.started(model: model))
            for try await line in lines where !line.isEmpty {
                try Task.checkCancellation()
                guard let d = parseJSONObject(line) else { throw AIError.decoding("NDJSON line") }
                if let error = d.string("error") { throw AIError.server(status: 500, message: error) }
                let message = d.dict("message")
                if let thinking = message?.string("thinking"), !thinking.isEmpty { continuation.yield(.reasoningDelta(thinking)) }
                if let content = message?.string("content"), !content.isEmpty { continuation.yield(.textDelta(content)) }
                if d.bool("done") == true {
                    continuation.yield(.completed(stopReason: d.string("done_reason") ?? "stop",
                                                  usage: TokenUsage(inputTokens: d.int("prompt_eval_count"), outputTokens: d.int("eval_count")),
                                                  servedBy: d.string("model") ?? model))
                    return
                }
            }
            throw AIError.decoding("stream ended before done")
        }
        // Map "can't connect" to the friendlier Ollama-specific message.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await e in inner { continuation.yield(e) }
                    continuation.finish()
                } catch AIError.network {
                    continuation.finish(throwing: notRunning)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
