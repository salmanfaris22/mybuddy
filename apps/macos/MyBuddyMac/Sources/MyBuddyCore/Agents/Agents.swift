import Foundation

/// Coding agents run through their official CLIs. They are not chat providers.
public enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode
    case codex

    public var id: String { rawValue }
    public var displayName: String { self == .claudeCode ? "Claude Code" : "Codex CLI" }
    public var executableName: String { self == .claudeCode ? "claude" : "codex" }
    public var docsURL: URL {
        self == .claudeCode ? URL(string: "https://code.claude.com/docs/en/cli-reference")! : URL(string: "https://learn.chatgpt.com/docs/non-interactive-mode")!
    }
    public var installHint: String {
        self == .claudeCode ? "Install Claude Code from code.claude.com, then run `claude` once in Terminal to sign in."
                            : "Install the Codex CLI (e.g. `brew install codex`), then run `codex login` in Terminal."
    }
    /// Where these CLIs are commonly installed (searched in addition to PATH).
    public var searchPaths: [String] {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/bin"]
    }
}

public enum AgentAuthState: Sendable, Equatable {
    case signedIn(method: String)
    case signedOut
    case unknown(String)

    public var title: String {
        switch self {
        case .signedIn(let m): "Signed in (\(m))"
        case .signedOut: "Not signed in"
        case .unknown(let why): "Sign-in status unknown — \(why)"
        }
    }
}

public struct AgentDetection: Sendable, Equatable {
    public let kind: AgentKind
    public let executablePath: String?
    public let version: String?
    public let auth: AgentAuthState
    public let checkedAt: Date

    public init(kind: AgentKind, executablePath: String?, version: String?, auth: AgentAuthState, checkedAt: Date) {
        self.kind = kind
        self.executablePath = executablePath
        self.version = version
        self.auth = auth
        self.checkedAt = checkedAt
    }

    public var isReady: Bool {
        if executablePath == nil { return false }
        if case .signedIn = auth { return true }
        return false
    }
}

/// What the agent may do. MyBuddy never offers modes that bypass the agent's own approvals.
public enum AgentPermissionLevel: String, Codable, CaseIterable, Sendable {
    /// Claude Code `--permission-mode plan`; Codex `--sandbox read-only`.
    case readOnly
    /// Claude Code `--permission-mode acceptEdits` (shell still denied); Codex `--sandbox workspace-write`.
    case editWorkspace

    public var title: String { self == .readOnly ? "Read-only (plan / review)" : "Edit files in workspace" }
    public var requiresConfirmation: Bool { self == .editWorkspace }
}

public struct AgentTask: Sendable, Equatable {
    public var prompt: String
    public var workspace: URL
    public var level: AgentPermissionLevel
    public var model: String?
    /// Codex refuses non-Git folders unless the user explicitly allows it.
    public var allowNonGitWorkspace: Bool

    public init(prompt: String, workspace: URL, level: AgentPermissionLevel = .readOnly, model: String? = nil, allowNonGitWorkspace: Bool = false) {
        self.prompt = prompt
        self.workspace = workspace
        self.level = level
        self.model = model
        self.allowNonGitWorkspace = allowNonGitWorkspace
    }
}

public enum AgentError: Error, Equatable, Sendable {
    case notInstalled(AgentKind)
    case notSignedIn(AgentKind)
    case forbiddenArgument(String)
    case invalidWorkspace(String)
    case launchFailed(String)
    case exited(code: Int32, message: String)
    case cancelled
}

public enum AgentArguments {
    /// Flags MyBuddy must never pass (enforced for every launch, and by tests).
    public static let forbidden: [String] = [
        "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "bypassPermissions",
        "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust", "danger-full-access",
        "--full-auto", "--yolo", "--approve-for-me",
    ]

    public static func validate(_ args: [String]) throws(AgentError) {
        for a in args {
            if let f = forbidden.first(where: { a == $0 || a.hasPrefix($0 + "=") }) {
                throw .forbiddenArgument(f)
            }
        }
    }

    public static func workspaceCheck(_ url: URL) throws(AgentError) {
        var isDir: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw .invalidWorkspace("The workspace folder doesn’t exist.")
        }
        let home = NSHomeDirectory()
        if url.path == "/" || url.path == home || url.path == "/Users" || url.path.hasPrefix("/System") || url.path.hasPrefix("/Library") {
            throw .invalidWorkspace("Choose a project folder, not your whole home folder or a system location.")
        }
    }

    /// `claude -p` headless invocation. The prompt is written to stdin, never argv.
    /// `--restricted` drops shell/code-running tools and project settings (hooks); `--strict-mcp-config`
    /// skips the repository's .mcp.json; `--permission-prompts none` denies anything that would prompt.
    public static func claudeCode(_ task: AgentTask) throws(AgentError) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--verbose",
                    "--restricted", "--strict-mcp-config",
                    "--permission-mode", task.level == .readOnly ? "plan" : "acceptEdits",
                    "--permission-prompts", "none"]
        if let model = task.model, !model.isEmpty { args += ["--model", model] }
        try validate(args)
        return args
    }

    /// `codex exec` headless invocation; `-` reads the prompt from stdin.
    public static func codex(_ task: AgentTask) throws(AgentError) -> [String] {
        var args = ["exec", "--json", "--sandbox", task.level == .readOnly ? "read-only" : "workspace-write",
                    "-C", task.workspace.path, "--ephemeral"]
        if task.allowNonGitWorkspace { args.append("--skip-git-repo-check") }
        if let model = task.model, !model.isEmpty { args += ["-m", model] }
        args.append("-")
        try validate(args)
        return args
    }

    public static func arguments(for kind: AgentKind, task: AgentTask) throws(AgentError) -> [String] {
        try workspaceCheck(task.workspace)
        return kind == .claudeCode ? try claudeCode(task) : try codex(task)
    }
}

/// Parses `--version` output and auth-status output without retaining personal data.
public enum AgentStatusParsing {
    public static func version(from output: String) -> String? {
        output.range(of: #"\d+\.\d+\.\d+([.-][0-9A-Za-z.]+)?"#, options: .regularExpression).map { String(output[$0]) }
    }

    /// `claude auth status --json`: keeps only `loggedIn` and `authMethod`. E-mail, org and
    /// subscription fields are deliberately discarded.
    public static func claudeAuth(json: Data) -> AgentAuthState {
        guard let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return .unknown("unreadable status") }
        guard let loggedIn = (obj["loggedIn"] as? NSNumber)?.boolValue else { return .unknown("no loggedIn field") }
        guard loggedIn else { return .signedOut }
        let method = (obj["authMethod"] as? String).map(sanitizeMethod) ?? "official CLI login"
        return .signedIn(method: method)
    }

    /// `codex login status`: e.g. "Logged in using an API key - sk-…" → keep only "API key".
    public static func codexAuth(output: String, exitCode: Int32) -> AgentAuthState {
        let firstLine = output.split(separator: "\n").first.map(String.init) ?? ""
        if firstLine.localizedCaseInsensitiveContains("not logged in") { return .signedOut }
        guard firstLine.hasPrefix("Logged in using") else {
            return exitCode == 0 ? .unknown("unrecognized status output") : .signedOut
        }
        var method = String(firstLine.dropFirst("Logged in using".count))
        if let dash = method.range(of: " - ") { method = String(method[..<dash.lowerBound]) }
        method = method.trimmingCharacters(in: .whitespaces)
        if method.hasPrefix("an ") { method = String(method.dropFirst(3)) } else if method.hasPrefix("a ") { method = String(method.dropFirst(2)) }
        return .signedIn(method: sanitizeMethod(method))
    }

    private static func sanitizeMethod(_ s: String) -> String {
        let cleaned = String(s.prefix(40)).filter { $0.isLetter || $0.isNumber || " ._-".contains($0) }
        return Redactor.redact(cleaned).isEmpty ? "official CLI login" : Redactor.redact(cleaned)
    }
}

// MARK: - Agent events

public enum AgentEvent: Sendable, Equatable {
    case started(sessionId: String?, model: String?)
    case assistantText(String)
    case toolProposed(name: String, summary: String)
    case commandStarted(String)
    case commandFinished(command: String, exitCode: Int?)
    case fileChanged(path: String, kind: String)
    case permissionDenied(String)
    case notice(String)
    case finished(success: Bool, summary: String, costUSD: Double?)
}

/// Parses `claude -p --output-format stream-json --verbose` lines (tolerant of unknown types).
public enum ClaudeStreamParser {
    public static func parse(line: String) -> [AgentEvent] {
        guard let obj = parseJSONObject(line), let type = obj.string("type") else { return [] }
        switch type {
        case "system":
            switch obj.string("subtype") {
            case "init": return [.started(sessionId: obj.string("session_id"), model: obj.string("model"))]
            case "api_retry": return [.notice("Retrying API request (attempt \(obj.int("attempt") ?? 0))")]
            case "permission_denied": return [.permissionDenied(obj.string("tool_name") ?? obj.string("message") ?? "A tool call was denied")]
            default: return []
            }
        case "assistant":
            let content = obj.dict("message")?.array("content") ?? []
            return content.compactMap { block in
                switch block.string("type") {
                case "text":
                    return block.string("text").map { .assistantText($0) }
                case "tool_use":
                    let name = block.string("name") ?? "tool"
                    let input = block.dict("input") ?? [:]
                    if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name), let path = input.string("file_path") ?? input.string("notebook_path") {
                        return .fileChanged(path: path, kind: name == "Write" ? "write" : "edit")
                    }
                    let detail = input.string("file_path") ?? input.string("pattern") ?? input.string("path") ?? input.string("command") ?? ""
                    return .toolProposed(name: name, summary: Redactor.redact(String(detail.prefix(200))))
                default:
                    return nil
                }
            }
        case "result":
            let isError = obj.bool("is_error") ?? (obj.string("subtype") != "success")
            let summary = obj.string("result") ?? obj.string("subtype") ?? ""
            let denials = (obj["permission_denials"] as? [Any])?.count ?? 0
            var events: [AgentEvent] = []
            if denials > 0 { events.append(.notice("\(denials) action(s) were denied by the permission mode")) }
            events.append(.finished(success: !isError, summary: summary, costUSD: (obj["total_cost_usd"] as? NSNumber)?.doubleValue))
            return events
        default:
            return []
        }
    }
}

/// Parses `codex exec --json` JSONL lines (tolerant of unknown types).
public enum CodexStreamParser {
    public static func parse(line: String) -> [AgentEvent] {
        guard let obj = parseJSONObject(line), let type = obj.string("type") else { return [] }
        let item = obj.dict("item") ?? [:]
        switch type {
        case "thread.started":
            return [.started(sessionId: obj.string("thread_id"), model: nil)]
        case "item.started":
            if item.string("type") == "command_execution", let cmd = item.string("command") { return [.commandStarted(Redactor.redact(cmd))] }
            return []
        case "item.completed":
            switch item.string("type") {
            case "agent_message": return item.string("text").map { [.assistantText($0)] } ?? []
            case "command_execution":
                return [.commandFinished(command: Redactor.redact(item.string("command") ?? ""), exitCode: item.int("exit_code"))]
            case "file_change":
                return (item.array("changes") ?? []).compactMap { c in c.string("path").map { .fileChanged(path: $0, kind: c.string("kind") ?? "update") } }
            case "error":
                return [.notice(item.string("message") ?? "error")]
            default:
                return []
            }
        case "turn.completed":
            return [.finished(success: true, summary: "Turn completed", costUSD: nil)]
        case "turn.failed":
            return [.finished(success: false, summary: obj.dict("error")?.string("message") ?? "Turn failed", costUSD: nil)]
        case "error":
            return [.notice(obj.string("message") ?? "error")]
        default:
            return []
        }
    }
}
