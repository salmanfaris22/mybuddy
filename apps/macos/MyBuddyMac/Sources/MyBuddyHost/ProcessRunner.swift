import Darwin
import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs executables directly — never through a shell — with a minimal, allowlisted
/// environment, bounded output and a timeout.
public enum ProcessRunner {
    /// Environment variables passed through to child processes. Provider API keys are
    /// deliberately excluded so official CLIs use their own sign-in, not a key MyBuddy happens to see.
    static let passthrough = ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "CODEX_HOME", "CLAUDE_CONFIG_DIR",
                              "XDG_CONFIG_HOME", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy"]
    static let blocked = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"]

    public static func environment(executable: String) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in passthrough { if let v = parent[key] { env[key] = v } }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        let execDir = (executable as NSString).deletingLastPathComponent
        env["PATH"] = ([execDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        for key in blocked { env.removeValue(forKey: key) }
        return env
    }

    /// Runs to completion. `executable` must be an absolute path.
    public static func run(_ executable: String, _ arguments: [String], stdin: Data? = nil, cwd: URL? = nil,
                           timeout: TimeInterval = 10, maxOutput: Int = 1 << 20) async -> ProcessResult {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            return ProcessResult(exitCode: 127, stdout: Data(), stderr: Data("not an executable: \(executable)".utf8), timedOut: false)
        }
        let out = OutputBuffer(limit: maxOutput)
        let err = OutputBuffer(limit: maxOutput)
        let child: ChildProcess
        do {
            child = try ChildProcess(executable: executable, arguments: arguments, cwd: cwd, stdin: stdin ?? Data(),
                                     onStdout: { out.append($0) }, onStderr: { err.append($0) })
        } catch {
            return ProcessResult(exitCode: 126, stdout: Data(), stderr: Data("\(error)".utf8), timedOut: false)
        }
        let timedOut = OnceFlag()
        let timer = DispatchWorkItem { [child] in
            if child.isRunning, timedOut.claim() { child.terminate(grace: 2) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let code = await child.waitForCompletion()
        timer.cancel()
        return ProcessResult(exitCode: code, stdout: out.data, stderr: err.data, timedOut: !timedOut.claim())
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true for the first caller only.
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ d: Data) { lock.withLock { if buffer.count < limit { buffer.append(d.prefix(limit - buffer.count)) } } }
    var data: Data { lock.withLock { buffer } }
}

/// Owns a child process and its pipes. Completion fires only after the process has exited
/// AND both pipes reached EOF (or a short grace period passed), so no trailing output is lost.
final class ChildProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var openStreams = 2
    private var exitStatus: Int32?
    private var completed = false
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(executable: String, arguments: [String], cwd: URL?, stdin: Data,
         onStdout: @escaping @Sendable (Data) -> Void, onStderr: @escaping @Sendable (Data) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessRunner.environment(executable: executable)
        if let cwd { process.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        for (pipe, sink) in [(out, onStdout), (err, onStderr)] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self?.streamClosed()
                } else {
                    sink(data)
                }
            }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.lock.withLock { self.exitStatus = p.terminationStatus }
            self.tryComplete()
            // A grandchild may keep a pipe open; don't wait forever for EOF.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.forceComplete() }
        }
        try process.run()
        if !stdin.isEmpty { input.fileHandleForWriting.write(stdin) }
        try? input.fileHandleForWriting.close()
    }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    private func streamClosed() {
        lock.withLock { openStreams -= 1 }
        tryComplete()
    }

    private func tryComplete() {
        let ready: (Int32, [CheckedContinuation<Int32, Never>])? = lock.withLock {
            guard !completed, let status = exitStatus, openStreams <= 0 else { return nil }
            completed = true
            defer { waiters = [] }
            return (status, waiters)
        }
        if let (status, ws) = ready { ws.forEach { $0.resume(returning: status) } }
    }

    private func forceComplete() {
        lock.withLock { openStreams = 0 }
        tryComplete()
    }

    func waitForCompletion() async -> Int32 {
        await withCheckedContinuation { c in
            let status: Int32? = lock.withLock {
                if completed { return exitStatus }
                waiters.append(c)
                return nil
            }
            if let status { c.resume(returning: status) }
        }
    }

    func interrupt() { if process.isRunning { kill(process.processIdentifier, SIGINT) } }

    func terminate(grace: TimeInterval) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [process] in if process.isRunning { kill(pid, SIGKILL) } }
    }
}

/// A long-running child process whose stdout is consumed line by line (coding agents).
public final class StreamingProcess: @unchecked Sendable {
    public let lines: AsyncStream<String>
    private let child: ChildProcess
    private let stderr = OutputBuffer(limit: 64 * 1024)

    public init(executable: String, arguments: [String], cwd: URL, stdin: Data) throws {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(10_000))
        lines = stream
        let splitter = LineSplitter { continuation.yield($0) }
        let errBuffer = stderr
        child = try ChildProcess(executable: executable, arguments: arguments, cwd: cwd, stdin: stdin,
                                 onStdout: { splitter.feed($0) }, onStderr: { errBuffer.append($0) })
        Task { [child] in
            _ = await child.waitForCompletion()
            splitter.flush()
            continuation.finish()
        }
    }

    public var processIdentifier: Int32 { child.processIdentifier }
    public var stderrSummary: String { String(decoding: stderr.data.suffix(8192), as: UTF8.self) }

    public func waitForExit() async -> Int32 { await child.waitForCompletion() }

    /// SIGINT first (lets the agent end its turn cleanly), then SIGTERM, then SIGKILL.
    public func cancel() {
        guard child.isRunning else { return }
        child.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [child] in child.terminate(grace: 3) }
    }
}

final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let emit: @Sendable (String) -> Void
    init(_ emit: @escaping @Sendable (String) -> Void) { self.emit = emit }

    func feed(_ data: Data) {
        let lines: [String] = lock.withLock {
            buffer.append(data)
            var out: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                out.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            if buffer.count > 4 << 20 { buffer.removeAll() }  // a single runaway line is dropped
            return out
        }
        lines.forEach(emit)
    }

    func flush() {
        let rest: String? = lock.withLock {
            defer { buffer.removeAll() }
            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
        if let rest { emit(rest) }
    }
}
