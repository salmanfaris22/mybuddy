import Foundation
import MyBuddyCore

/// Detects and runs the official Claude Code / Codex CLIs. Uses only their documented
/// commands; never reads their credential stores, cookies or config files.
public enum AgentService {
    /// Finds the CLI on PATH or in common install locations.
    public static func findExecutable(_ kind: AgentKind) -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in kind.searchPaths + pathDirs {
            let candidate = (dir as NSString).appendingPathComponent(kind.executableName)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func detect(_ kind: AgentKind) async -> AgentDetection {
        guard let path = findExecutable(kind) else {
            return AgentDetection(kind: kind, executablePath: nil, version: nil, auth: .unknown("not installed"), checkedAt: Date())
        }
        let versionResult = await ProcessRunner.run(path, ["--version"], timeout: 10)
        let version = AgentStatusParsing.version(from: versionResult.stdoutString)
        let auth: AgentAuthState
        switch kind {
        case .claudeCode:
            let r = await ProcessRunner.run(path, ["auth", "status", "--json"], timeout: 15)
            auth = r.timedOut ? .unknown("status check timed out") : AgentStatusParsing.claudeAuth(json: r.stdout)
        case .codex:
            let r = await ProcessRunner.run(path, ["login", "status"], timeout: 15)
            // Codex prints its status on stdout or stderr depending on version.
            let text = r.stdoutString.isEmpty ? String(decoding: r.stderr, as: UTF8.self) : r.stdoutString
            auth = r.timedOut ? .unknown("status check timed out") : AgentStatusParsing.codexAuth(output: text, exitCode: r.exitCode)
        }
        return AgentDetection(kind: kind, executablePath: path, version: version, auth: auth, checkedAt: Date())
    }

    /// A running agent task. Events are parsed from the CLI's documented JSON stream.
    public final class Run: @unchecked Sendable {
        public let kind: AgentKind
        public let task: AgentTask
        public let events: AsyncStream<AgentEvent>
        private let process: StreamingProcess

        init(kind: AgentKind, task: AgentTask, process: StreamingProcess) {
            self.kind = kind
            self.task = task
            self.process = process
            let parse: @Sendable (String) -> [AgentEvent] = kind == .claudeCode ? ClaudeStreamParser.parse : CodexStreamParser.parse
            let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
            events = stream
            Task {
                for await line in process.lines {
                    for event in parse(line) { continuation.yield(event) }
                }
                let code = await process.waitForExit()
                if code != 0 {
                    let tail = Redactor.redact(String(process.stderrSummary.suffix(400)))
                    continuation.yield(.finished(success: false, summary: tail.isEmpty ? "Exited with code \(code)" : tail, costUSD: nil))
                }
                continuation.finish()
            }
        }

        public func cancel() { process.cancel() }
        public var processIdentifier: Int32 { process.processIdentifier }
    }

    /// Starts a task after the caller has obtained the user's approval for workspace and level.
    public static func start(_ kind: AgentKind, task: AgentTask, detection: AgentDetection) throws(AgentError) -> Run {
        guard let path = detection.executablePath else { throw .notInstalled(kind) }
        guard detection.isReady else { throw .notSignedIn(kind) }
        let args = try AgentArguments.arguments(for: kind, task: task)
        do {
            let process = try StreamingProcess(executable: path, arguments: args, cwd: task.workspace, stdin: Data(task.prompt.utf8))
            return Run(kind: kind, task: task, process: process)
        } catch {
            throw .launchFailed(Redactor.redact("\(error)"))
        }
    }

    /// Whether a folder is a Git work tree (Codex requires one unless the user opts out).
    public static func isGitWorkTree(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }
}
