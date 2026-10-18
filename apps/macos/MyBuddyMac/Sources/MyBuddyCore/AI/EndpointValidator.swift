import Foundation

public enum EndpointClass: Sendable, Equatable {
    case loopback
    case privateNetwork
    case publicInternet
}

/// Validates provider endpoints to reduce SSRF / accidental data exfiltration (SECURITY T10, T11).
public enum EndpointValidator {
    public static let officialHosts: [ProviderKind: String] = [.anthropic: "api.anthropic.com", .openAI: "api.openai.com"]

    public static func classify(host rawHost: String) -> EndpointClass {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") { return .loopback }
        if host.hasSuffix(".local") { return .privateNetwork }
        if let v4 = ipv4(host) {
            switch (v4[0], v4[1]) {
            case (127, _): return .loopback
            case (10, _), (192, 168), (169, 254): return .privateNetwork
            case (172, 16...31): return .privateNetwork
            case (100, 64...127): return .privateNetwork  // CGNAT / Tailscale
            case (0, _): return .privateNetwork
            default: return .publicInternet
            }
        }
        if host.contains(":") {
            if host == "::1" { return .loopback }
            if host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") { return .privateNetwork }
            if host.hasPrefix("fc") || host.hasPrefix("fd") { return .privateNetwork }
            return .publicInternet
        }
        return .publicInternet
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let nums = parts.compactMap { Int($0) }
        guard nums.count == 4, nums.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return nums
    }

    /// Throws if `url` may not be used for `kind` under `trust`.
    public static func validate(_ url: URL, kind: ProviderKind, trust: EndpointTrust) throws(AIError) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw .endpointRejected("Only http(s) endpoints are allowed.")
        }
        guard let host = url.host, !host.isEmpty else { throw .endpointRejected("The endpoint has no host.") }
        guard url.user == nil, url.password == nil else { throw .endpointRejected("Credentials in URLs are not allowed — use the Keychain field.") }
        guard url.query == nil, url.fragment == nil else { throw .endpointRejected("Endpoints may not contain a query or fragment.") }
        let cls = classify(host: host)

        switch kind {
        case .anthropic, .openAI:
            guard scheme == "https" else { throw .endpointRejected("Cloud providers require HTTPS.") }
            if host.lowercased() != officialHosts[kind], trust != .userTrustedRemote {
                throw .endpointRejected("Only \(officialHosts[kind]!) is allowed unless you explicitly trust a custom gateway.")
            }
        case .ollama, .openAICompatible:
            switch cls {
            case .loopback:
                break
            case .privateNetwork:
                guard trust == .userTrustedLocalNetwork || trust == .userTrustedRemote else {
                    throw .endpointRejected("This server is on your local network. Confirm that you trust it before sending prompts.")
                }
            case .publicInternet:
                guard trust == .userTrustedRemote else {
                    throw .endpointRejected("This is a public internet server. MyBuddy won’t send private prompts there unless you explicitly trust it.")
                }
                guard scheme == "https" else { throw .endpointRejected("Remote servers require HTTPS.") }
            }
        }
    }

    /// Local Only mode: only loopback model servers are permitted (checked before any request).
    public static func allowedInLocalOnly(_ config: ProviderConfig) -> Bool {
        (config.kind == .ollama || config.kind == .openAICompatible) && classify(host: config.endpoint.host ?? "") == .loopback
    }
}
