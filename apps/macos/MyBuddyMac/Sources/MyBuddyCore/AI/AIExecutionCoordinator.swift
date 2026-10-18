import Foundation

public struct AIPrivacySettings: Codable, Sendable, Equatable {
    /// Blocks every non-loopback AI provider (cloud APIs, LAN servers) before any request is made.
    public var localOnly: Bool
    public init(localOnly: Bool = false) { self.localOnly = localOnly }
}

/// Creates providers after policy checks. The only place that reads provider secrets.
public enum AIProviderFactory {
    public static func make(_ config: ProviderConfig, privacy: AIPrivacySettings, secrets: any SecretStore,
                            transport: any HTTPTransport) throws(AIError) -> any ChatModelProvider {
        if privacy.localOnly, !EndpointValidator.allowedInLocalOnly(config) {
            throw .blockedByLocalOnly("Local Only is on. \(config.displayName) would send data off this Mac, so it’s blocked.")
        }
        try EndpointValidator.validate(config.endpoint, kind: config.kind, trust: config.trust)
        func key() throws(AIError) -> String? {
            guard let ref = config.secret else { return nil }
            do { return try secrets.read(ref) } catch { throw .notConfigured("Couldn’t read the API key from the Keychain.") }
        }
        switch config.kind {
        case .anthropic:
            guard let k = try key(), !k.isEmpty else { throw .notConfigured("Add your Anthropic API key in Settings → AI Providers.") }
            return AnthropicProvider(config: config, apiKey: k, transport: transport)
        case .openAI:
            guard let k = try key(), !k.isEmpty else { throw .notConfigured("Add your OpenAI API key in Settings → AI Providers.") }
            return OpenAIProvider(config: config, apiKey: k, transport: transport)
        case .ollama:
            return OllamaProvider(config: config, transport: transport)
        case .openAICompatible:
            return OpenAICompatibleProvider(config: config, apiKey: try key(), transport: transport)
        }
    }
}

/// Records privacy-safe AI activity (never prompts or responses).
public protocol AIActivityRecorder: Sendable {
    func recordAI(provider: String, model: String, outcome: String)
}

/// Runs chat requests with policy enforcement, capped retries (only before any output) and cancellation.
public final class AIExecutionCoordinator: Sendable {
    private let secrets: any SecretStore
    private let transport: any HTTPTransport
    private let privacy: @Sendable () -> AIPrivacySettings
    private let recorder: (any AIActivityRecorder)?
    private let maxRetries: Int
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(secrets: any SecretStore, transport: any HTTPTransport, privacy: @escaping @Sendable () -> AIPrivacySettings,
                recorder: (any AIActivityRecorder)? = nil, maxRetries: Int = 2,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.secrets = secrets
        self.transport = transport
        self.privacy = privacy
        self.recorder = recorder
        self.maxRetries = maxRetries
        self.sleep = sleep
    }

    public func provider(for config: ProviderConfig) throws(AIError) -> any ChatModelProvider {
        try AIProviderFactory.make(config, privacy: privacy(), secrets: secrets, transport: transport)
    }

    public func listModels(_ config: ProviderConfig) async throws -> [ModelDescriptor] {
        try await provider(for: config).listModels()
    }

    public func testConnection(_ config: ProviderConfig) async -> ConnectionTestResult {
        do {
            return try await provider(for: config).testConnection()
        } catch {
            return ConnectionTestResult(outcome: .failed, message: error.userMessage, testedAt: Date())
        }
    }

    public func stream(_ config: ProviderConfig, _ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        let recorder = self.recorder
        let maxRetries = self.maxRetries
        let sleep = self.sleep
        let providerResult = Result { () throws(AIError) -> any ChatModelProvider in try provider(for: config) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                let provider: any ChatModelProvider
                switch providerResult {
                case .success(let p): provider = p
                case .failure(let error):
                    recorder?.recordAI(provider: config.displayName, model: request.model, outcome: "blocked: \(error.code)")
                    continuation.finish(throwing: error)
                    return
                }
                var attempt = 0
                while true {
                    var emitted = false
                    do {
                        for try await event in provider.streamChat(request) {
                            emitted = true
                            continuation.yield(event)
                            if case .completed(let stop, _, let servedBy) = event {
                                recorder?.recordAI(provider: config.displayName, model: servedBy, outcome: stop)
                            }
                        }
                        continuation.finish()
                        return
                    } catch {
                        let ai = (error as? AIError) ?? ProviderHTTP.mapTransportError(error, endpoint: config.endpoint)
                        if !emitted, ai.isRetryable, attempt < maxRetries, !Task.isCancelled {
                            attempt += 1
                            do { try await sleep(Double(attempt)) } catch {
                                continuation.finish(throwing: AIError.cancelled)
                                return
                            }
                            continue
                        }
                        recorder?.recordAI(provider: config.displayName, model: request.model, outcome: "failed: \(ai.code)")
                        continuation.finish(throwing: ai)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
