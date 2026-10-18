import Foundation

/// Anthropic Messages API adapter (raw HTTP; there is no official Swift SDK).
/// POST /v1/messages with SSE streaming, GET /v1/models for discovery and capabilities.
public struct AnthropicProvider: ChatModelProvider {
    public let config: ProviderConfig
    private let transport: any HTTPTransport
    private let apiKey: String

    static let apiVersion = "2023-06-01"
    /// Models that accept `fallbacks: "default"` (server-side refusal fallback, beta).
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public init(config: ProviderConfig, apiKey: String, transport: any HTTPTransport) {
        self.config = config
        self.apiKey = apiKey
        self.transport = transport
    }

    private func headers(beta: String? = nil) -> [String: String] {
        var h = ["x-api-key": apiKey, "anthropic-version": Self.apiVersion, "content-type": "application/json", "accept": "application/json"]
        if let beta { h["anthropic-beta"] = beta }
        return h
    }

    public func listModels() async throws -> [ModelDescriptor] {
        var out: [ModelDescriptor] = []
        var after: String?
        for _ in 0..<5 {
            var url = ProviderHTTP.url(config.endpoint, "/v1/models")
            var items = [URLQueryItem(name: "limit", value: "100")]
            if let after { items.append(URLQueryItem(name: "after_id", value: after)) }
            url = url.appending(queryItems: items)
            let (head, data) = try await transport.data(HTTPRequestSpec(url: url, headers: headers(), timeout: 20))
            guard (200..<300).contains(head.status) else { throw Self.mapError(status: head.status, body: data, head: head, model: nil) }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let list = json.array("data") else {
                throw AIError.decoding("models list")
            }
            out += list.compactMap(Self.descriptor)
            guard json.bool("has_more") == true, let last = json.string("last_id") else { break }
            after = last
        }
        return out
    }

    static func descriptor(_ m: [String: Any]) -> ModelDescriptor? {
        guard let id = m.string("id") else { return nil }
        let caps = m.dict("capabilities")
        func supported(_ path: [String]) -> Bool? {
            var node: [String: Any]? = caps
            for key in path { node = node?.dict(key) }
            return node?.bool("supported")
        }
        return ModelDescriptor(id: id, displayName: m.string("display_name"), contextWindow: m.int("max_input_tokens"),
                               maxOutputTokens: m.int("max_tokens"), supportsVision: supported(["image_input"]),
                               supportsAdaptiveThinking: supported(["thinking", "types", "adaptive"]),
                               supportsEffort: supported(["effort"]), source: "GET /v1/models")
    }

    public func testConnection() async -> ConnectionTestResult {
        do {
            let models = try await listModels()
            return ConnectionTestResult(outcome: .ok, message: "Connected · \(models.count) models available to this key", testedAt: Date())
        } catch {
            return ConnectionTestResult(outcome: .failed, message: ProviderHTTP.mapTransportError(error, endpoint: config.endpoint).userMessage, testedAt: Date())
        }
    }

    /// Builds the request body. Exposed for tests.
    func requestBody(_ r: ChatRequest) -> (body: [String: Any], beta: String?) {
        var body: [String: Any] = [
            "model": r.model,
            "max_tokens": r.maxOutputTokens,
            "stream": true,
            "messages": r.messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if let system = r.system, !system.isEmpty { body["system"] = system }
        let descriptor = config.models.first { $0.id == r.model }
        if config.options.showReasoningSummaries, descriptor?.supportsAdaptiveThinking == true {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        }
        var beta: String?
        if config.options.anthropicRefusalFallback, Self.fallbackModels.contains(r.model) {
            body["fallbacks"] = "default"
            beta = Self.fallbackBeta
        }
        return (body, beta)
    }

    public func streamChat(_ r: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        let (body, beta) = requestBody(r)
        let spec = HTTPRequestSpec(url: ProviderHTTP.url(config.endpoint, "/v1/messages"), method: "POST",
                                   headers: headers(beta: beta).merging(["accept": "text/event-stream"]) { $1 },
                                   body: jsonBody(body), timeout: 120)
        let transport = self.transport
        let requested = r.model
        return ProviderHTTP.stream(endpoint: config.endpoint) { continuation in
            let (head, lines) = try await transport.lines(spec)
            guard (200..<300).contains(head.status) else {
                throw Self.mapError(status: head.status, body: await ProviderHTTP.collect(lines), head: head, model: requested)
            }
            var parser = SSEParser()
            var state = StreamState(model: requested)
            for try await line in lines {
                try Task.checkCancellation()
                if let event = parser.feed(line) { try Self.handle(event, &state, continuation) }
                if state.done { return }
            }
            if let event = parser.finish() { try Self.handle(event, &state, continuation) }
            guard state.done else { throw AIError.decoding("stream ended before message_stop") }
        }
    }

    struct StreamState {
        var model: String
        var stopReason = "end_turn"
        var refusalCategory: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var done = false
    }

    static func handle(_ event: SSEParser.Event, _ s: inout StreamState, _ c: AsyncThrowingStream<ChatEvent, any Error>.Continuation) throws {
        guard let data = parseJSONObject(event.data) else { return }
        switch data.string("type") ?? event.event {
        case "message_start":
            let message = data.dict("message")
            if let model = message?.string("model") { s.model = model }
            s.inputTokens = message?.dict("usage")?.int("input_tokens")
            c.yield(.started(model: s.model))
        case "content_block_start":
            if let block = data.dict("content_block"), block.string("type") == "fallback" {
                let from = block.dict("from")?.string("model") ?? s.model
                let to = block.dict("to")?.string("model") ?? s.model
                s.model = to
                c.yield(.fallback(from: from, to: to))
            }
        case "content_block_delta":
            let delta = data.dict("delta")
            switch delta?.string("type") {
            case "text_delta": if let t = delta?.string("text") { c.yield(.textDelta(t)) }
            case "thinking_delta": if let t = delta?.string("thinking"), !t.isEmpty { c.yield(.reasoningDelta(t)) }
            default: break
            }
        case "message_delta":
            let delta = data.dict("delta")
            if let reason = delta?.string("stop_reason") { s.stopReason = reason }
            s.refusalCategory = delta?.dict("stop_details")?.string("category") ?? data.dict("stop_details")?.string("category") ?? s.refusalCategory
            if let out = data.dict("usage")?.int("output_tokens") { s.outputTokens = out }
        case "message_stop":
            if s.stopReason == "refusal" { c.yield(.refused(category: s.refusalCategory)) }
            c.yield(.completed(stopReason: s.stopReason, usage: TokenUsage(inputTokens: s.inputTokens, outputTokens: s.outputTokens), servedBy: s.model))
            s.done = true
        case "error":
            let err = data.dict("error")
            let message = err?.string("message") ?? "stream error"
            switch err?.string("type") {
            case "overloaded_error": throw AIError.overloaded
            case "rate_limit_error": throw AIError.rateLimited(retryAfter: nil)
            case "invalid_request_error": throw AIError.invalidRequest(message)
            case "authentication_error", "permission_error": throw AIError.unauthorized("Anthropic rejected the API key.")
            default: throw AIError.server(status: 500, message: message)
            }
        default:
            break  // ping and future event types are ignored
        }
    }

    static func mapError(status: Int, body: Data, head: HTTPResponseHead, model: String?) -> AIError {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = json?.dict("error")?.string("message") ?? String(decoding: body.prefix(300), as: UTF8.self)
        switch status {
        case 401: return .unauthorized("Anthropic rejected the API key. Check it in Settings → AI Providers.")
        case 403: return .unauthorized("This API key isn’t allowed to use that model or feature.")
        case 404: return .modelNotFound(model ?? "requested model")
        case 413: return .invalidRequest("The conversation is too large for one request.")
        case 429: return .rateLimited(retryAfter: ProviderHTTP.retryAfter(head))
        case 529: return .overloaded
        case 400..<500: return .invalidRequest(message)
        default: return .server(status: status, message: message)
        }
    }
}
