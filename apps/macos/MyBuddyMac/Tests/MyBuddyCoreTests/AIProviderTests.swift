import Foundation
import Testing
@testable import MyBuddyCore

@Suite("AI providers")
struct AIProviderTests {
    static let key = "sk-" + "ant-test-0123456789abcdef"

    func anthropic(_ t: MockTransport, model: String = "claude-opus-5-5") -> AnthropicProvider {
        var c = ProviderConfig(id: "anthropic", kind: .anthropic)
        c.selectedModel = model
        return AnthropicProvider(config: c, apiKey: Self.key, transport: t)
    }

    @Test func sseParserFollowsSpec() {
        var p = SSEParser()
        #expect(p.feed(": keep-alive") == nil)
        #expect(p.feed("event: content_block_delta") == nil)
        #expect(p.feed("data: {\"a\":1}") == nil)
        #expect(p.feed("data:second") == nil)
        #expect(p.feed("") == SSEParser.Event(event: "content_block_delta", data: "{\"a\":1}\nsecond"))
        #expect(p.feed("") == nil, "blank line without data dispatches nothing")
        _ = p.feed("data: tail")
        #expect(p.finish() == SSEParser.Event(event: "message", data: "tail"))
    }

    @Test func anthropicStreamsTextAndUsage() async throws {
        let t = MockTransport([.lines(status: 200, lines: sse([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":21}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("ping", #"{"type":"ping"}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Your battery "}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"is healthy."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ]))])
        let (events, error) = await collect(anthropic(t).streamChat(ChatRequest(messages: [ChatMessage(role: .user, text: "hi")], model: "claude-opus-5-5", system: "Be brief")))
        #expect(error == nil)
        #expect(events == [.started(model: "claude-opus-5-5"), .textDelta("Your battery "), .textDelta("is healthy."),
                           .completed(stopReason: "end_turn", usage: TokenUsage(inputTokens: 21, outputTokens: 9), servedBy: "claude-opus-5-5")])
        let req = t.requests[0]
        #expect(req.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.headers["x-api-key"] == Self.key && req.headers["anthropic-version"] == "2023-06-01")
        #expect(req.headers["anthropic-beta"] == "server-side-fallback-2026-07-01", "refusal fallback opted in on supported models")
        let body = t.bodyJSON(0)
        #expect(body["model"] as? String == "claude-opus-5-5" && body["stream"] as? Bool == true && body["system"] as? String == "Be brief")
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["thinking"] == nil, "no thinking config unless the user enabled summaries and the model supports it")
    }

    @Test func anthropicNoFallbackOnUnsupportedModel() async {
        let t = MockTransport([.lines(status: 200, lines: sse([("message_stop", #"{"type":"message_stop"}"#)]))])
        _ = await collect(anthropic(t).streamChat(ChatRequest(messages: [ChatMessage(role: .user, text: "hi")], model: "claude-haiku-4-5")))
        #expect(t.requests[0].headers["anthropic-beta"] == nil)
        #expect(t.bodyJSON(0)["fallbacks"] == nil)
    }

    @Test func anthropicRefusalAndFallbackAreSurfaced() async {
        let t = MockTransport([.lines(status: 200, lines: sse([
            ("message_start", #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":5}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"partial"}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}},"usage":{"output_tokens":3}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ]))])
        let (events, _) = await collect(anthropic(t).streamChat(ChatRequest(messages: [ChatMessage(role: .user, text: "x")], model: "claude-opus-5-5")))
        #expect(events.contains(.fallback(from: "claude-opus-5-5", to: "claude-opus-4-8")))
        #expect(events.contains(.refused(category: "cyber")))
        #expect(events.last == .completed(stopReason: "refusal", usage: TokenUsage(inputTokens: 5, outputTokens: 3), servedBy: "claude-opus-4-8"))
    }

    @Test(arguments: [(401, "unauthorized"), (403, "unauthorized"), (404, "model_not_found"), (429, "rate_limited"), (529, "overloaded"), (400, "invalid_request"), (500, "server_error")])
    func anthropicHTTPErrorsAreMapped(status: Int, code: String) async {
        let t = MockTransport([.lines(status: status, lines: [#"{"type":"error","error":{"type":"x","message":"bad things"}}"#], headers: ["retry-after": "7"])])
        let (_, error) = await collect(anthropic(t).streamChat(ChatRequest(messages: [ChatMessage(role: .user, text: "x")], model: "claude-opus-5-5")))
        #expect(error?.code == code)
        if status == 429 { #expect(error == .rateLimited(retryAfter: 7)) }
        #expect(!(error?.userMessage.contains(Self.key) ?? true))
    }

    @Test func anthropicMidStreamOverloadAndEarlyEnd() async {
        let t = MockTransport([.lines(status: 200, lines: sse([("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)])),
                               .lines(status: 200, lines: sse([("message_start", #"{"type":"message_start","message":{"model":"m"}}"#)]))])
        let p = anthropic(t)
        #expect(await collect(p.streamChat(ChatRequest(messages: [], model: "m"))).error == .overloaded)
        #expect(await collect(p.streamChat(ChatRequest(messages: [], model: "m"))).error?.code == "decoding")
    }

    @Test func anthropicModelDiscoveryWithCapabilitiesAndPagination() async throws {
        let page1 = #"{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5","max_input_tokens":1000000,"max_tokens":128000,"capabilities":{"image_input":{"supported":true},"thinking":{"supported":true,"types":{"adaptive":{"supported":true}}},"effort":{"supported":true}}}],"has_more":true,"last_id":"claude-opus-5-5"}"#
        let page2 = #"{"data":[{"id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5","max_input_tokens":200000,"max_tokens":64000,"capabilities":{"thinking":{"supported":true,"types":{"adaptive":{"supported":false}}}}}],"has_more":false}"#
        let t = MockTransport([.data(status: 200, body: page1), .data(status: 200, body: page2)])
        let models = try await anthropic(t).listModels()
        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-haiku-4-5"])
        #expect(models[0].contextWindow == 1_000_000 && models[0].supportsAdaptiveThinking == true && models[0].supportsVision == true)
        #expect(models[1].supportsAdaptiveThinking == false)
        #expect(t.requests[1].url.query?.contains("after_id=claude-opus-5-5") == true)
    }

    @Test func openAIResponsesStreaming() async {
        let t = MockTransport([.lines(status: 200, lines: sse([
            ("response.created", #"{"type":"response.created","response":{"id":"r1","model":"gpt-5.5","status":"in_progress"}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","delta":"Hello","item_id":"i","output_index":0,"content_index":0,"sequence_number":3}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","delta":" there","item_id":"i","output_index":0,"content_index":0,"sequence_number":4}"#),
            ("response.completed", #"{"type":"response.completed","response":{"id":"r1","model":"gpt-5.5","status":"completed","usage":{"input_tokens":12,"output_tokens":2}}}"#),
        ]))])
        var c = ProviderConfig(id: "openai", kind: .openAI)
        c.selectedModel = "gpt-5.5"
        let (events, error) = await collect(OpenAIProvider(config: c, apiKey: "sk-proj-abcdefghijklmnop", transport: t)
            .streamChat(ChatRequest(messages: [ChatMessage(role: .user, text: "hi")], model: "gpt-5.5", system: "sys")))
        #expect(error == nil)
        #expect(events == [.started(model: "gpt-5.5"), .textDelta("Hello"), .textDelta(" there"),
                           .completed(stopReason: "completed", usage: TokenUsage(inputTokens: 12, outputTokens: 2), servedBy: "gpt-5.5")])
        let body = t.bodyJSON(0)
        #expect(body["store"] as? Bool == false, "responses are not stored server-side")
        #expect(body["instructions"] as? String == "sys")
        #expect(t.requests[0].headers["authorization"] == "Bearer sk-proj-abcdefghijklmnop")
        #expect(t.requests[0].url.absoluteString == "https://api.openai.com/v1/responses")
    }

    @Test func openAIFailuresAndQuota() async {
        let t = MockTransport([
            .lines(status: 200, lines: sse([("response.failed", #"{"type":"response.failed","response":{"error":{"message":"boom"}}}"#)])),
            .lines(status: 429, lines: [#"{"error":{"message":"quota","code":"insufficient_quota"}}"#]),
            .lines(status: 200, lines: sse([("response.incomplete", #"{"type":"response.incomplete","response":{"model":"m","incomplete_details":{"reason":"max_output_tokens"}}}"#)])),
        ])
        let p = OpenAIProvider(config: ProviderConfig(id: "openai", kind: .openAI), apiKey: "k", transport: t)
        #expect(await collect(p.streamChat(ChatRequest(messages: [], model: "m"))).error == .server(status: 500, message: "boom"))
        #expect(await collect(p.streamChat(ChatRequest(messages: [], model: "m"))).error == .invalidRequest("Your OpenAI quota is exhausted."))
        #expect(await collect(p.streamChat(ChatRequest(messages: [], model: "m"))).events.last == .completed(stopReason: "incomplete: max_output_tokens", usage: nil, servedBy: "m"))
    }

    @Test func openAIModelListFiltersNonChatModels() async throws {
        let t = MockTransport([.data(status: 200, body: #"{"data":[{"id":"gpt-5.5"},{"id":"text-embedding-3-large"},{"id":"whisper-1"},{"id":"gpt-5.5-mini"},{"id":"dall-e-3"}]}"#)])
        let models = try await OpenAIProvider(config: ProviderConfig(id: "openai", kind: .openAI), apiKey: "k", transport: t).listModels()
        #expect(models.map(\.id) == ["gpt-5.5", "gpt-5.5-mini"])
    }

    @Test func ollamaNDJSONStreamingAndErrors() async throws {
        let ok = MockTransport([.lines(status: 200, lines: [
            #"{"model":"llama3.2","message":{"role":"assistant","content":"Hi"},"done":false}"#,
            #"{"model":"llama3.2","message":{"role":"assistant","content":" there"},"done":false}"#,
            #"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":10,"eval_count":2}"#,
        ])])
        let config = ProviderConfig(id: "ollama", kind: .ollama)
        let (events, error) = await collect(OllamaProvider(config: config, transport: ok).streamChat(ChatRequest(messages: [ChatMessage(role: .user, text: "hey")], model: "llama3.2")))
        #expect(error == nil)
        #expect(events == [.started(model: "llama3.2"), .textDelta("Hi"), .textDelta(" there"),
                           .completed(stopReason: "stop", usage: TokenUsage(inputTokens: 10, outputTokens: 2), servedBy: "llama3.2")])
        #expect(ok.requests[0].url.absoluteString == "http://127.0.0.1:11434/api/chat")

        let midError = MockTransport([.lines(status: 200, lines: [#"{"model":"m","message":{"content":"a"},"done":false}"#, #"{"error":"model runner crashed"}"#])])
        #expect(await collect(OllamaProvider(config: config, transport: midError).streamChat(ChatRequest(messages: [], model: "m"))).error == .server(status: 500, message: "model runner crashed"))

        let missing = MockTransport([.lines(status: 404, lines: [#"{"error":"model 'nope' not found"}"#])])
        #expect(await collect(OllamaProvider(config: config, transport: missing).streamChat(ChatRequest(messages: [], model: "nope"))).error == .modelNotFound("nope"))

        let down = MockTransport([.fail(URLError(.cannotConnectToHost))])
        let downError = await collect(OllamaProvider(config: config, transport: down).streamChat(ChatRequest(messages: [], model: "m"))).error
        #expect(downError?.userMessage.contains("Ollama isn’t reachable") == true)
    }

    @Test func ollamaDiscoveryAndDetails() async throws {
        let t = MockTransport([
            .data(status: 200, body: #"{"models":[{"name":"llama3.2:latest","size":2019393189,"details":{"parameter_size":"3.2B","quantization_level":"Q4_K_M"}}]}"#),
            .data(status: 200, body: #"{"model_info":{"general.architecture":"llama","llama.context_length":131072},"capabilities":["completion","tools"]}"#),
        ])
        let p = OllamaProvider(config: ProviderConfig(id: "ollama", kind: .ollama), transport: t)
        let models = try await p.listModels()
        #expect(models.first?.id == "llama3.2:latest" && models.first?.detail?.contains("Q4_K_M") == true)
        let details = try await p.modelDetails("llama3.2:latest")
        #expect(details.contextWindow == 131_072 && details.supportsVision == false)
    }

    @Test func openAICompatibleChatCompletions() async {
        let t = MockTransport([.lines(status: 200, lines: [
            #"data: {"model":"qwen","choices":[{"delta":{"content":"Yo"}}]}"#, "",
            #"data: {"model":"qwen","choices":[{"delta":{},"finish_reason":"stop"}]}"#, "",
            "data: [DONE]", "",
        ])])
        let config = ProviderConfig(id: "lmstudio", kind: .openAICompatible, endpoint: URL(string: "http://127.0.0.1:1234/v1")!)
        let (events, error) = await collect(OpenAICompatibleProvider(config: config, apiKey: nil, transport: t).streamChat(ChatRequest(messages: [], model: "qwen")))
        #expect(error == nil)
        #expect(events == [.started(model: "qwen"), .textDelta("Yo"), .completed(stopReason: "stop", usage: nil, servedBy: "qwen")])
        #expect(t.requests[0].url.absoluteString == "http://127.0.0.1:1234/v1/chat/completions", "a base ending in /v1 is not doubled")
    }
}

@Suite("AI policy, endpoints and secrets")
struct AIPolicyTests {
    @Test func endpointClassification() {
        #expect(EndpointValidator.classify(host: "127.0.0.1") == .loopback)
        #expect(EndpointValidator.classify(host: "localhost") == .loopback)
        #expect(EndpointValidator.classify(host: "::1") == .loopback)
        #expect(EndpointValidator.classify(host: "192.168.1.10") == .privateNetwork)
        #expect(EndpointValidator.classify(host: "172.20.0.5") == .privateNetwork)
        #expect(EndpointValidator.classify(host: "172.32.0.5") == .publicInternet)
        #expect(EndpointValidator.classify(host: "studio.local") == .privateNetwork)
        #expect(EndpointValidator.classify(host: "api.anthropic.com") == .publicInternet)
        #expect(EndpointValidator.classify(host: "fe80::1%en0") == .privateNetwork)
    }

    @Test func endpointRules() throws {
        func ok(_ s: String, _ k: ProviderKind, _ t: EndpointTrust = .standard) -> Bool {
            (try? EndpointValidator.validate(URL(string: s)!, kind: k, trust: t)) != nil
        }
        #expect(ok("https://api.anthropic.com", .anthropic))
        #expect(!ok("http://api.anthropic.com", .anthropic))
        #expect(!ok("https://evil.example.com", .anthropic))
        #expect(ok("https://gateway.corp.example", .anthropic, .userTrustedRemote))
        #expect(ok("http://127.0.0.1:11434", .ollama))
        #expect(!ok("http://192.168.1.50:11434", .ollama))
        #expect(ok("http://192.168.1.50:11434", .ollama, .userTrustedLocalNetwork))
        #expect(!ok("http://llm.example.com", .openAICompatible, .userTrustedRemote), "remote requires https")
        #expect(ok("https://llm.example.com", .openAICompatible, .userTrustedRemote))
        #expect(!ok("http://user:pass@127.0.0.1:8080", .openAICompatible))
        #expect(!ok("file:///etc/passwd", .openAICompatible))
        #expect(!ok("http://127.0.0.1:8080/v1?x=1", .openAICompatible))
    }

    @Test func localOnlyBlocksCloudBeforeAnyRequest() async {
        let spy = MockTransport([])
        let secrets = InMemorySecretStore([SecretReference(account: "anthropic"): "sk-" + "ant-secret-value-123456"])
        let coordinator = AIExecutionCoordinator(secrets: secrets, transport: spy, privacy: { AIPrivacySettings(localOnly: true) })
        let (_, error) = await collect(coordinator.stream(ProviderConfig(id: "anthropic", kind: .anthropic), ChatRequest(messages: [], model: "claude-opus-5-5")))
        #expect(error?.code == "blocked_local_only")
        #expect(spy.callCount == 0, "no network request may be attempted in Local Only mode")
        let test = await coordinator.testConnection(ProviderConfig(id: "openai", kind: .openAI))
        #expect(test.outcome == .failed && spy.callCount == 0)
        // Loopback Ollama is still allowed.
        #expect((try? coordinator.provider(for: ProviderConfig(id: "ollama", kind: .ollama))) != nil)
        // A LAN Ollama is not "local only" even if trusted.
        let lan = ProviderConfig(id: "lan", kind: .ollama, endpoint: URL(string: "http://192.168.1.5:11434")!, trust: .userTrustedLocalNetwork)
        #expect(throws: AIError.self) { try coordinator.provider(for: lan) }
    }

    @Test func missingKeyIsReportedWithoutNetwork() async {
        let spy = MockTransport([])
        let coordinator = AIExecutionCoordinator(secrets: InMemorySecretStore(), transport: spy, privacy: { AIPrivacySettings() })
        let (_, error) = await collect(coordinator.stream(ProviderConfig(id: "openai", kind: .openAI), ChatRequest(messages: [], model: "gpt-5.5")))
        #expect(error?.code == "not_configured" && spy.callCount == 0)
    }

    @Test func retriesOnlyRetryableErrorsBeforeOutput() async {
        let secrets = InMemorySecretStore([SecretReference(account: "anthropic"): "k"])
        let flaky = MockTransport([.lines(status: 529, lines: ["{}"]), .lines(status: 529, lines: ["{}"]),
                                   .lines(status: 200, lines: sse([("message_start", #"{"type":"message_start","message":{"model":"m"}}"#), ("message_stop", "{\"type\":\"message_stop\"}")]))])
        let c1 = AIExecutionCoordinator(secrets: secrets, transport: flaky, privacy: { AIPrivacySettings() }, sleep: { _ in })
        let r1 = await collect(c1.stream(ProviderConfig(id: "anthropic", kind: .anthropic), ChatRequest(messages: [], model: "m")))
        #expect(r1.error == nil && flaky.callCount == 3)

        let unauthorized = MockTransport([.lines(status: 401, lines: ["{}"]), .lines(status: 200, lines: [])])
        let c2 = AIExecutionCoordinator(secrets: secrets, transport: unauthorized, privacy: { AIPrivacySettings() }, sleep: { _ in })
        #expect(await collect(c2.stream(ProviderConfig(id: "anthropic", kind: .anthropic), ChatRequest(messages: [], model: "m"))).error?.code == "unauthorized")
        #expect(unauthorized.callCount == 1, "non-retryable errors are not retried")

        let partial = MockTransport([.lines(status: 200, lines: sse([("message_start", #"{"type":"message_start","message":{"model":"m"}}"#)]), failAfter: URLError(.networkConnectionLost)),
                                     .lines(status: 200, lines: [])])
        let c3 = AIExecutionCoordinator(secrets: secrets, transport: partial, privacy: { AIPrivacySettings() }, sleep: { _ in })
        let r3 = await collect(c3.stream(ProviderConfig(id: "anthropic", kind: .anthropic), ChatRequest(messages: [], model: "m")))
        #expect(r3.events == [.started(model: "m")] && r3.error?.code == "network")
        #expect(partial.callCount == 1, "never retry after output started (would duplicate text)")
    }

    @Test func providerConfigNeverContainsSecrets() throws {
        let secrets = InMemorySecretStore()
        let config = ProviderConfig(id: "anthropic", kind: .anthropic)
        try secrets.write("sk-" + "ant-super-secret-key-0000", for: config.secret!)
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(!json.contains("sk-" + "ant-super-secret"))
        #expect(json.contains("app.mybuddy.mac.provider"))
    }

    @Test func redactorScrubsCredentials() {
        let text = "x-api-key: sk-ant-api03-ABCDEFGHIJ Authorization: Bearer eyJhbGciOi.abc.def key=sk-proj-1234567890abcd at \(NSHomeDirectory())/secret"
        let r = Redactor.redact(text)
        #expect(!r.contains("ABCDEFGHIJ") && !r.contains("eyJhbGciOi") && !r.contains("1234567890abcd"))
        #expect(!r.contains(NSHomeDirectory()) && r.contains("~/secret"))
    }

    @Test func activityLogRecordsOnlyMetadata() {
        let log = ActivityLog(capacity: 3, retention: 60)
        log.recordAI(provider: "Anthropic API", model: "claude-opus-5-5", outcome: "end_turn")
        log.record(.clipboard, "Copied to phone", detail: "token sk-ant-api03-SECRETSECRET")
        #expect(log.all.count == 2 && !(log.all[0].detail ?? "").contains("SECRETSECRET"))
        for i in 0..<5 { log.record(.session, "s\(i)") }
        #expect(log.all.count == 3, "capacity is enforced")
        log.record(ActivityEvent(date: Date().addingTimeInterval(-120), kind: .health, title: "old"))
        #expect(!log.all.contains { $0.title == "old" }, "retention is enforced")
        log.deleteAll()
        #expect(log.all.isEmpty)
    }
}
