import Foundation

/// A folder this Mac lets paired phones run coding agents in (chosen on the Mac; the phone only ever sees its name).
public struct PhoneAgentWorkspace: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public var name: String

    public init(id: String = "ws_" + UUID().uuidString.lowercased().prefix(12), path: String, name: String) {
        self.id = id
        self.path = path
        self.name = name
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// How a coding-agent task started from the phone travels: `ai.request` (mode `agent`) in, `ai.delta` / `ai.complete` out
/// (PROTOCOL.md §5.7). The agents themselves run exactly as when started on the Mac.
public enum PhoneAgentWire {
    public static func kind(_ s: String?) -> AgentKind? {
        switch s {
        case "claude_code": .claudeCode
        case "codex": .codex
        default: nil
        }
    }

    public static func wire(_ k: AgentKind) -> String { k == .claudeCode ? "claude_code" : "codex" }

    public static func level(_ s: String?) -> AgentPermissionLevel? {
        switch s {
        case "read_only": .readOnly
        case "edit_workspace": .editWorkspace
        default: nil
        }
    }

    /// The line the phone shows for one agent event, or nil. `sawText`: the answer already streamed, so a successful
    /// run's final summary (the same answer again) is skipped. Paths are shortened the way the Mac's log shows them.
    public static func text(for event: AgentEvent, sawText: Bool) -> String? {
        switch event {
        case .started(_, let model): model.map { "Started · \($0)\n\n" } ?? "Started\n\n"
        case .assistantText(let t): t.hasSuffix("\n") ? t : t + "\n"
        case .toolProposed(let name, let summary): "→ \(name): \(Redactor.redact(summary))\n"
        case .commandStarted(let c): "$ \(Redactor.redact(c))\n"
        case .commandFinished(let c, let code): code.flatMap { $0 == 0 ? nil : "  exit \($0) · \(Redactor.redact(c))\n" }
        case .fileChanged(let path, let kind): "✎ \(kind) \(Redactor.redact(path))\n"
        case .permissionDenied(let what): "⛔ Blocked: \(Redactor.redact(what))\n"
        case .notice(let n): "ℹ︎ \(n)\n"
        case .finished(let ok, let summary, _):
            ok ? (sawText || summary.isEmpty ? nil : "\n\(summary)\n") : "\nFailed: \(summary.isEmpty ? "the agent stopped" : summary)\n"
        }
    }

    /// `ai.delta.text` holds at most 16 KiB of characters: longer output goes out in pieces.
    public static func chunks(_ text: String, max: Int = 8_000) -> [String] {
        guard text.count > max else { return [text] }
        var out: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            out.append(String(rest.prefix(max)))
            rest = rest.dropFirst(max)
        }
        return out
    }
}
