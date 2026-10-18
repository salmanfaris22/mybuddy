import Foundation

/// Chat-model providers. Coding agents are a separate type (`AgentKind`).
public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openAI
    case ollama
    case openAICompatible

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic API"
        case .openAI: "OpenAI API"
        case .ollama: "Ollama (local)"
        case .openAICompatible: "Custom OpenAI-compatible server"
        }
    }

    public var defaultEndpoint: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com")!
        case .openAI: URL(string: "https://api.openai.com")!
        case .ollama: URL(string: "http://127.0.0.1:11434")!
        case .openAICompatible: URL(string: "http://127.0.0.1:8080")!
        }
    }

    /// How the provider authenticates — shown to the user before first use.
    public var authDescription: String {
        switch self {
        case .anthropic: "Your Anthropic API key, stored in the macOS Keychain"
        case .openAI: "Your OpenAI API key, stored in the macOS Keychain"
        case .ollama: "No key — talks to the Ollama server on this Mac"
        case .openAICompatible: "Optional key, stored in the macOS Keychain"
        }
    }

    public var requiresAPIKey: Bool { self == .anthropic || self == .openAI }
}

/// Points at a Keychain item. Never contains the secret itself.
public struct SecretReference: Codable, Sendable, Hashable {
    public let service: String
    public let account: String
    public init(service: String = "app.mybuddy.mac.provider", account: String) {
        self.service = service
        self.account = account
    }
}

public enum EndpointTrust: String, Codable, Sendable {
    /// Built-in defaults only (official API hosts, loopback for local servers).
    case standard
    /// The user explicitly trusts a server on their local network.
    case userTrustedLocalNetwork
    /// The user explicitly trusts a remote HTTPS server (e.g. a corporate gateway).
    case userTrustedRemote
}

public struct ModelDescriptor: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public var displayName: String
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var supportsVision: Bool?
    public var supportsAdaptiveThinking: Bool?
    public var supportsEffort: Bool?
    public var detail: String?
    public var source: String

    public init(id: String, displayName: String? = nil, contextWindow: Int? = nil, maxOutputTokens: Int? = nil, supportsVision: Bool? = nil,
                supportsAdaptiveThinking: Bool? = nil, supportsEffort: Bool? = nil, detail: String? = nil, source: String) {
        self.id = id
        self.displayName = displayName ?? id
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsVision = supportsVision
        self.supportsAdaptiveThinking = supportsAdaptiveThinking
        self.supportsEffort = supportsEffort
        self.detail = detail
        self.source = source
    }
}

public struct ConnectionTestResult: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable { case ok, failed }
    public let outcome: Outcome
    public let message: String
    public let testedAt: Date
}

public struct ProviderOptions: Codable, Sendable, Equatable {
    /// Anthropic: opt into the server-side refusal fallback (`fallbacks: "default"`) on models that support it.
    public var anthropicRefusalFallback = true
    /// Show summarized reasoning when the model supports adaptive thinking.
    public var showReasoningSummaries = false
    public var maxOutputTokens = 16_000
    public init() {}
}

/// Non-secret provider configuration. Encoding this type can never leak a key.
public struct ProviderConfig: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var kind: ProviderKind
    public var displayName: String
    public var endpoint: URL
    public var trust: EndpointTrust
    public var secret: SecretReference?
    public var selectedModel: String?
    public var models: [ModelDescriptor]
    public var modelsLoadedAt: Date?
    public var lastTest: ConnectionTestResult?
    public var options: ProviderOptions

    public init(id: String, kind: ProviderKind, displayName: String? = nil, endpoint: URL? = nil, trust: EndpointTrust = .standard,
                secret: SecretReference? = nil, selectedModel: String? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName ?? kind.displayName
        self.endpoint = endpoint ?? kind.defaultEndpoint
        self.trust = trust
        self.secret = secret ?? (kind == .ollama ? nil : SecretReference(account: id))
        self.selectedModel = selectedModel
        models = []
        options = ProviderOptions()
    }

    public static var defaults: [ProviderConfig] {
        [ProviderConfig(id: "anthropic", kind: .anthropic), ProviderConfig(id: "openai", kind: .openAI), ProviderConfig(id: "ollama", kind: .ollama)]
    }

    /// Where prompts go — shown next to the active provider at all times.
    public var privacyLabel: String {
        switch EndpointValidator.classify(host: endpoint.host ?? "") {
        case .loopback: "Stays on this Mac"
        case .privateNetwork: "Sent to a server on your local network"
        case .publicInternet: "Sent to \(endpoint.host ?? "a remote server")"
        }
    }

    public var isCloud: Bool { EndpointValidator.classify(host: endpoint.host ?? "") != .loopback }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    public var text: String

    public init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public struct ChatRequest: Sendable, Equatable {
    public var messages: [ChatMessage]
    public var model: String
    public var system: String?
    public var maxOutputTokens: Int

    public init(messages: [ChatMessage], model: String, system: String? = nil, maxOutputTokens: Int = 16_000) {
        self.messages = messages
        self.model = model
        self.system = system
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum ChatEvent: Sendable, Equatable {
    case started(model: String)
    case textDelta(String)
    case reasoningDelta(String)
    /// Anthropic server-side refusal fallback switched models mid-request.
    case fallback(from: String, to: String)
    /// The provider declined; partial output (if any) must be discarded.
    case refused(category: String?)
    case completed(stopReason: String, usage: TokenUsage?, servedBy: String)
}

public enum AIError: Error, Equatable, Sendable {
    case notConfigured(String)
    case blockedByLocalOnly(String)
    case endpointRejected(String)
    case unauthorized(String)
    case modelNotFound(String)
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case invalidRequest(String)
    case server(status: Int, message: String)
    case network(String)
    case timeout
    case cancelled
    case decoding(String)

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .timeout, .network: true
        case .server(let status, _): status >= 500
        default: false
        }
    }

    public var code: String {
        switch self {
        case .notConfigured: "not_configured"
        case .blockedByLocalOnly: "blocked_local_only"
        case .endpointRejected: "endpoint_rejected"
        case .unauthorized: "unauthorized"
        case .modelNotFound: "model_not_found"
        case .rateLimited: "rate_limited"
        case .overloaded: "overloaded"
        case .invalidRequest: "invalid_request"
        case .server: "server_error"
        case .network: "network"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .decoding: "decoding"
        }
    }

    /// User-facing copy (already redacted).
    public var userMessage: String {
        switch self {
        case .notConfigured(let what): what
        case .blockedByLocalOnly(let why): why
        case .endpointRejected(let why): why
        case .unauthorized(let why): why
        case .modelNotFound(let model): "The model “\(model)” isn’t available to this account or server."
        case .rateLimited(let after): after.map { "Rate limited — try again in \(Int($0)) s." } ?? "Rate limited — try again shortly."
        case .overloaded: "The provider is overloaded right now. Try again in a moment."
        case .invalidRequest(let m): "The provider rejected the request: \(Redactor.redact(m))"
        case .server(let status, let m): "Provider error \(status): \(Redactor.redact(m))"
        case .network(let m): Redactor.redact(m)
        case .timeout: "The request timed out."
        case .cancelled: "Cancelled."
        case .decoding(let m): "Unexpected response from the provider (\(m))."
        }
    }
}

/// Removes secrets from any text that may reach logs or the UI.
public enum Redactor {
    private static let patterns: [(String, String)] = [
        (#"sk-ant-[A-Za-z0-9_\-]{6,}"#, "sk-ant-…[redacted]"),
        (#"sk-(proj-)?[A-Za-z0-9_\-]{8,}"#, "sk-…[redacted]"),
        (#"(?i)bearer\s+[A-Za-z0-9._\-~+/=]{8,}"#, "Bearer [redacted]"),
        (#"(?i)(x-api-key|api[_-]?key|authorization)(["']?\s*[:=]\s*["']?)[^\s"',}]+"#, "$1$2[redacted]"),
        (#"gh[pousr]_[A-Za-z0-9]{20,}"#, "gh…[redacted]"),
        (#"AKIA[0-9A-Z]{16}"#, "AKIA…[redacted]"),
    ]

    public static func redact(_ text: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var out = text
        for (pattern, replacement) in patterns {
            out = out.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        if !homeDirectory.isEmpty, homeDirectory != "/" { out = out.replacingOccurrences(of: homeDirectory, with: "~") }
        return out
    }
}
