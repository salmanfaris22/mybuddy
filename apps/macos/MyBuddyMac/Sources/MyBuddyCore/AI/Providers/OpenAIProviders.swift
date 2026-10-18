import Foundation

/// OpenAI Responses API adapter: POST /v1/responses (SSE), GET /v1/models. Uses `store: false`.
public struct OpenAIProvider: ChatModelProvider {
    public let config: ProviderConfig
    private let transport: any HTTPTransport
    private let apiKey: String

    public init(config: ProviderConfig, apiKey: String, transport: any HTTPTransport) {
        self.config = config
        self.apiKey = apiKey
        self.transport = transport
    }

    private var headers: [String: String] { ["authorization": "Bearer \(apiKey)", "content-type": "application/json"] }

    /// Model ids the models endpoint returns that are clearly not chat models (heuristic, documented in the UI).
    static func isLikelyChatModel(_ id: String) -> Bool {
        let excluded = ["embedding", "whisper", "tts", "dall-e", "moderation", "transcribe", "audio", "realtime", "image", "davinci", "babbage", "search", "computer-use"]
        return !excluded.contains { id.contains($0) }
    }

    public func listModels() async throws -> [ModelDescriptor] {
        let (head, data) = try await transport.data(HTTPRequestSpec(url: ProviderHTTP.url(config.endpoint, "/v1/models"), headers: headers, timeout: 20))
        guard (200..<300).contains(head.status) else { throw Self.mapError(status: head.status, body: data, head: head, model: nil) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let list = json.array("data") else {
            throw AIError.decoding("models list")
        }
        return list.compactMap { $0.string("id") }.filter(Self.isLikelyChatModel).sorted()
            .map { ModelDescriptor(id: $0, source: "GET /v1/models (chat models filtered heuristically)") }
    }

    public func testConnection() async -> ConnectionTestResult {
        do {
            let models = try await listModels()
            return ConnectionTestResult(outcome: .ok, message: "Connected · \(models.count) chat models listed", testedAt: Date())
        } catch {
            return ConnectionTestResult(outcome: .failed, message: ProviderHTTP.mapTransportError(error, endpoint: config.endpoint).userMessage, testedAt: Date())
        }
    }

    func requestBody(_ r: ChatRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": r.model,
            "input": r.messages.map { ["role": $0.role.rawValue, "content": $0.text] },
            "stream": true,
            "store": false,
            "max_output_tokens": r.maxOutputTokens,
        ]
        if let system = r.system, !system.isEmpty { body["instructions"] = system }
        return body
    }

    public func streamChat(_ r: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        let spec = HTTPRequestSpec(url: ProviderHTTP.url(config.endpoint, "/v1/responses"), method: "POST",
                                   headers: headers.merging(["accept": "text/event-stream"]) { $1 }, body: jsonBody(requestBody(r)), timeout: 120)
        let transport = self.transport
        let requested = r.model
        return ProviderHTTP.stream(endpoint: config.endpoint) { continuation in
            let (head, lines) = try await transport.lines(spec)
            guard (200..<300).contains(head.status) else {
                throw Self.mapError(status: head.status, body: await ProviderHTTP.collect(lines), head: head, model: requested)
            }
            var parser = SSEParser()
            var model = requested
            var refused = false
            var done = false
            func handle(_ e: SSEParser.Event) throws {
                guard let d = parseJSONObject(e.data) else { return }
                let response = d.dict("response")
                switch d.string("type") ?? e.event {
                case "response.created":
                    model = response?.string("model") ?? model
                    continuation.yield(.started(model: model))
                case "response.output_text.delta":
                    if let t = d.string("delta") { continuation.yield(.textDelta(t)) }
                case "response.reasoning_summary_text.delta":
                    if let t = d.string("delta") { continuation.yield(.reasoningDelta(t)) }
                case "response.refusal.delta", "response.refusal.done":
                    refused = true
                case "response.completed":
                    let usage = response?.dict("usage")
                    if refused { continuation.yield(.refused(category: nil)) }
                    continuation.yield(.completed(stopReason: refused ? "refusal" : "completed",
                                                  usage: TokenUsage(inputTokens: usage?.int("input_tokens"), outputTokens: usage?.int("output_tokens")),
                                                  servedBy: response?.string("model") ?? model))
                    done = true
                case "response.incomplete":
                    let reason = response?.dict("incomplete_details")?.string("reason") ?? "unknown"
                    continuation.yield(.completed(stopReason: "incomplete: \(reason)", usage: nil, servedBy: response?.string("model") ?? model))
                    done = true
                case "response.failed":
                    throw AIError.server(status: 500, message: response?.dict("error")?.string("message") ?? "response failed")
                case "error":
                    let code = d.string("code") ?? ""
                    let message = d.string("message") ?? "stream error"
                    if code.contains("rate_limit") { throw AIError.rateLimited(retryAfter: nil) }
                    throw AIError.server(status: 500, message: message)
                default:
                    break
                }
            }
            for try await line in lines {
                try Task.checkCancellation()
                if let e = parser.feed(line) { try handle(e) }
                if done { return }
            }
            if let e = parser.finish() { try handle(e) }
            guard done else { throw AIError.decoding("stream ended before response.completed") }
        }
    }

    static func mapError(status: Int, body: Data, head: HTTPResponseHead, model: String?) -> AIError {
        let err = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?.dict("error")
        let message = err?.string("message") ?? String(decoding: body.prefix(300), as: UTF8.self)
        switch status {
        case 401: return .unauthorized("OpenAI rejected the API key. Check it in Settings → AI Providers.")
        case 403: return .unauthorized("This API key isn’t allowed to use that model.")
        case 404: return .modelNotFound(model ?? "requested model")
        case 429:
            if err?.string("code") == "insufficient_quota" { return .invalidRequest("Your OpenAI quota is exhausted.") }
            return .rateLimited(retryAfter: ProviderHTTP.retryAfter(head))
        case 400..<500: return .invalidRequest(message)
        default: return .server(status: status, message: message)
        }
    }
}

/// Generic OpenAI-compatible server (llama.cpp, LM Studio, vLLM…): /v1/chat/completions SSE.
public struct OpenAICompatibleProvider: ChatModelProvider {
    public let config: ProviderConfig
    private let transport: any HTTPTransport
    private let apiKey: String?

    public init(config: ProviderConfig, apiKey: String?, transport: any HTTPTransport) {
        self.config = config
        self.apiKey = apiKey
        self.transport = transport
    }

    private var headers: [String: String] {
        var h = ["content-type": "application/json"]
        if let apiKey, !apiKey.isEmpty { h["authorization"] = "Bearer \(apiKey)" }
        return h
    }

    public func listModels() async throws -> [ModelDescriptor] {
        let (head, data) = try await transport.data(HTTPRequestSpec(url: ProviderHTTP.url(config.endpoint, "/v1/models"), headers: headers, timeout: 10))
        guard (200..<300).contains(head.status) else { throw OpenAIProvider.mapError(status: head.status, body: data, head: head, model: nil) }
        let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?.array("data") ?? []
        return list.compactMap { $0.string("id") }.map { ModelDescriptor(id: $0, source: "GET /v1/models") }
    }

    public func testConnection() async -> ConnectionTestResult {
        do {
            let models = try await listModels()
            return ConnectionTestResult(outcome: .ok, message: "Connected · \(models.count) models", testedAt: Date())
        } catch {
            return ConnectionTestResult(outcome: .failed, message: ProviderHTTP.mapTransportError(error, endpoint: config.endpoint).userMessage, testedAt: Date())
        }
    }

    public func streamChat(_ r: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        var messages: [[String: String]] = []
        if let system = r.system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages += r.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let body: [String: Any] = ["model": r.model, "messages": messages, "stream": true, "max_tokens": r.maxOutputTokens]
        let spec = HTTPRequestSpec(url: ProviderHTTP.url(config.endpoint, "/v1/chat/completions"), method: "POST", headers: headers, body: jsonBody(body), timeout: 120)
        let transport = self.transport
        let requested = r.model
        return ProviderHTTP.stream(endpoint: config.endpoint) { continuation in
            let (head, lines) = try await transport.lines(spec)
            guard (200..<300).contains(head.status) else {
                throw OpenAIProvider.mapError(status: head.status, body: await ProviderHTTP.collect(lines), head: head, model: requested)
            }
            var parser = SSEParser()
            var started = false
            var model = requested
            var finish = "stop"
            var usage: TokenUsage?
            for try await line in lines {
                try Task.checkCancellation()
                guard let e = parser.feed(line) else { continue }
                if e.data == "[DONE]" { break }
                guard let d = parseJSONObject(e.data) else { continue }
                if let m = d.string("model") { model = m }
                if !started {
                    started = true
                    continuation.yield(.started(model: model))
                }
                if let choice = d.array("choices")?.first {
                    if let t = choice.dict("delta")?.string("content"), !t.isEmpty { continuation.yield(.textDelta(t)) }
                    if let f = choice.string("finish_reason") { finish = f }
                }
                if let u = d.dict("usage") { usage = TokenUsage(inputTokens: u.int("prompt_tokens"), outputTokens: u.int("completion_tokens")) }
            }
            if !started { continuation.yield(.started(model: model)) }
            continuation.yield(.completed(stopReason: finish, usage: usage, servedBy: model))
        }
    }
}
