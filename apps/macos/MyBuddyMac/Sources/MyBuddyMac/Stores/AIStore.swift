import AppKit
import Foundation
import MyBuddyCore
import MyBuddyHost
import Observation

struct ChatTurn: Identifiable, Equatable {
    enum Status: Equatable { case streaming, complete, refused(String?), failed(String), cancelled }
    let id = UUID()
    let role: ChatMessage.Role
    var text: String
    var reasoning: String = ""
    var status: Status = .complete
    var servedBy: String?
    var providerName: String?
    var fallbackNote: String?
    var usage: TokenUsage?
}

struct AgentLogLine: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let event: AgentEvent
}

@MainActor
@Observable
final class AIStore {
    enum Mode: String, CaseIterable { case chat = "Chat Models", agents = "Coding Agents" }

    @ObservationIgnored var app: AppModel!
    let demo: Bool
    var mode: Mode = .chat
    private(set) var transcript: [ChatTurn] = []
    var draft = ""
    private(set) var isStreaming = false
    private(set) var modelsState: LoadState<[ModelDescriptor]> = .idle
    private(set) var testResult: ConnectionTestResult?
    private(set) var isTesting = false
    private var streamTask: Task<Void, Never>?
    private var peerTasks: [String: Task<Void, Never>] = [:]

    // Agents
    private(set) var detections: [AgentKind: LoadState<AgentDetection>] = [:]
    var agentKind: AgentKind = .claudeCode
    var agentWorkspace: URL?
    var agentLevel: AgentPermissionLevel = .readOnly
    var agentPrompt = ""
    var allowNonGitWorkspace = false
    var confirmEditRun = false
    private(set) var agentLog: [AgentLogLine] = []
    private(set) var agentRun: AgentService.Run?
    private(set) var agentError: String?

    @ObservationIgnored private lazy var coordinator: AIExecutionCoordinator = {
        let app = self.app!
        return AIExecutionCoordinator(secrets: app.secrets, transport: URLSessionTransport(),
                                      privacy: { [settings = SettingsBox.shared] in settings.privacy }, recorder: app.activityLog)
    }()

    init(demo: Bool) {
        self.demo = demo
        if demo {
            transcript = DemoData.chat
            modelsState = .loaded(DemoData.models)
            detections = DemoData.agentDetections
            agentWorkspace = URL(fileURLWithPath: "/Users/you/Projects/mybuddy")
            agentLog = DemoData.agentLog
        }
    }

    // MARK: Provider selection

    var providers: [ProviderConfig] { app.settings.providers }

    var selectedProvider: ProviderConfig {
        get { providers.first { $0.id == app.settings.selectedProviderId } ?? providers[0] }
        set {
            if let i = app.settings.providers.firstIndex(where: { $0.id == newValue.id }) { app.settings.providers[i] = newValue }
        }
    }

    func selectProvider(_ id: String) {
        guard id != app.settings.selectedProviderId else { return }
        app.settings.selectedProviderId = id
        modelsState = selectedProvider.models.isEmpty ? .idle : .loaded(selectedProvider.models)
        testResult = selectedProvider.lastTest
        if !transcript.isEmpty {
            transcript.append(ChatTurn(role: .assistant, text: "Switched to \(selectedProvider.displayName). The new provider starts a fresh conversation — earlier messages are not sent to it.", status: .complete, providerName: "MyBuddy"))
        }
        app.activityLog.record(.ai, "Chat provider switched to \(selectedProvider.displayName)")
    }

    func selectModel(_ id: String) {
        var p = selectedProvider
        p.selectedModel = id
        selectedProvider = p
    }

    var blockedByLocalOnly: Bool { app.settings.localOnly && !EndpointValidator.allowedInLocalOnly(selectedProvider) }

    func hasKey(_ config: ProviderConfig) -> Bool {
        guard let ref = config.secret else { return true }
        return ((try? app.secrets.read(ref)) ?? nil)?.isEmpty == false
    }

    func setKey(_ key: String, for config: ProviderConfig) {
        guard let ref = config.secret else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try? app.secrets.delete(ref) } else { try? app.secrets.write(trimmed, for: ref) }
        app.activityLog.record(.security, trimmed.isEmpty ? "Removed API key for \(config.displayName)" : "Saved API key for \(config.displayName) in the Keychain")
    }

    func refreshModels() async {
        guard !demo else { return }
        let config = selectedProvider
        modelsState = .loading
        do {
            let models = try await coordinator.listModels(config)
            var p = config
            p.models = models
            p.modelsLoadedAt = Date()
            if p.selectedModel == nil || !models.contains(where: { $0.id == p.selectedModel }) {
                p.selectedModel = models.first(where: { $0.id == "claude-opus-5-5" })?.id ?? models.first?.id
            }
            selectedProvider = p
            modelsState = models.isEmpty ? .unavailable(config.kind == .ollama ? "No local models installed. Run `ollama pull <model>`." : "No models listed for this account.") : .loaded(models)
        } catch let e as AIError {
            modelsState = e.code == "not_configured" || e.code == "blocked_local_only" ? .notAuthorized(e.userMessage) : .failed(e.userMessage)
        } catch {
            modelsState = .failed(Redactor.redact("\(error)"))
        }
    }

    func testConnection() async {
        guard !demo else { return }
        isTesting = true
        let result = await coordinator.testConnection(selectedProvider)
        var p = selectedProvider
        p.lastTest = result
        selectedProvider = p
        testResult = result
        isTesting = false
    }

    // MARK: Chat

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draft = ""
        transcript.append(ChatTurn(role: .user, text: text))
        guard !demo else { return }
        let config = selectedProvider
        guard let model = config.selectedModel else {
            transcript.append(ChatTurn(role: .assistant, text: "", status: .failed("Choose a model first (Refresh models).")))
            return
        }
        let history = transcript.filter { $0.status == .complete && $0.providerName != "MyBuddy" }.map { ChatMessage(role: $0.role, text: $0.text) }
        transcript.append(ChatTurn(role: .assistant, text: "", status: .streaming, providerName: config.displayName))
        let index = transcript.count - 1
        isStreaming = true
        let request = ChatRequest(messages: history, model: model, system: "You are MyBuddy, a concise assistant running on the user's Mac.",
                                  maxOutputTokens: config.options.maxOutputTokens)
        streamTask = Task {
            do {
                for try await event in coordinator.stream(config, request) {
                    apply(event, at: index)
                }
                if transcript[index].status == .streaming { transcript[index].status = .complete }
            } catch let e as AIError {
                transcript[index].status = e == .cancelled ? .cancelled : .failed(e.userMessage)
            } catch {
                transcript[index].status = .failed(Redactor.redact("\(error)"))
            }
            isStreaming = false
        }
    }

    private func apply(_ event: ChatEvent, at i: Int) {
        switch event {
        case .started(let model): transcript[i].servedBy = model
        case .textDelta(let t): transcript[i].text += t
        case .reasoningDelta(let t): transcript[i].reasoning += t
        case .fallback(let from, let to):
            transcript[i].fallbackNote = "\(from) declined; answered by \(to)"
            transcript[i].servedBy = to
        case .refused(let category):
            transcript[i].text = ""
            transcript[i].status = .refused(category)
        case .completed(let stop, let usage, let servedBy):
            transcript[i].servedBy = servedBy
            transcript[i].usage = usage
            if case .refused = transcript[i].status {} else {
                transcript[i].status = .complete
                if stop == "max_tokens" { transcript[i].fallbackNote = "Stopped at the output limit" }
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    func clearConversation() {
        stop()
        transcript = []
    }

    // MARK: Phone-originated requests (run on this Mac; the phone never gets keys)

    func handlePeerRequest(_ e: Envelope, device: TrustedDevice, granted: Set<Capability>) async -> [OutgoingEvent] {
        guard let requestId = e.payload["requestId"]?.stringValue else { return [] }
        // No model picked yet (e.g. Ollama was just installed): list the provider's models, which selects the first.
        if e.payload["mode"]?.stringValue == "chat", selectedProvider.selectedModel == nil { await refreshModels() }
        let config = selectedProvider
        func failure(_ code: String, _ message: String) -> [OutgoingEvent] {
            [OutgoingEvent(.aiError, ["requestId": .string(requestId), "code": .string(code), "message": .string(message), "retryable": .bool(false)], replyTo: e.sequence)]
        }
        if e.payload["mode"]?.stringValue == "agent" { return handlePeerAgent(e, requestId: requestId, device: device, granted: granted) }
        guard e.payload["mode"]?.stringValue == "chat" else { return failure("unsupported", "Unknown request mode.") }
        guard let model = config.selectedModel else { return failure("not_configured", "No model selected on the Mac.") }
        let messages = (e.payload["messages"]?.arrayValue ?? []).compactMap { m -> ChatMessage? in
            guard let role = m["role"]?.stringValue.flatMap(ChatMessage.Role.init(rawValue:)), let text = m["text"]?.stringValue else { return nil }
            return ChatMessage(role: role, text: text)
        }
        let sessionId = e.sessionId
        app.activityLog.record(.ai, "\(device.name) asked \(config.displayName)", detail: model)
        peerTasks[requestId] = Task {
            do {
                for try await event in coordinator.stream(config, ChatRequest(messages: messages, model: model, maxOutputTokens: 4096)) {
                    switch event {
                    case .textDelta(let t):
                        app.connection.push(OutgoingEvent(.aiDelta, ["requestId": .string(requestId), "text": .string(t)]), toSession: sessionId)
                    case .completed(let stop, let usage, let servedBy):
                        var payload: [String: JSONValue] = ["requestId": .string(requestId), "stopReason": .string(stop), "servedBy": .string(servedBy)]
                        if let usage { payload["usage"] = .object(["inputTokens": .int(Int64(usage.inputTokens ?? 0)), "outputTokens": .int(Int64(usage.outputTokens ?? 0))]) }
                        app.connection.push(OutgoingEvent(.aiComplete, payload), toSession: sessionId)
                    default: break
                    }
                }
            } catch {
                let ai = error as? AIError ?? .network("\(error)")
                app.connection.push(OutgoingEvent(.aiError, ["requestId": .string(requestId), "code": .string(ai.code),
                                                             "message": .string(String(ai.userMessage.prefix(500))), "retryable": .bool(ai.isRetryable)]), toSession: sessionId)
            }
            peerTasks[requestId] = nil
        }
        return [OutgoingEvent(.aiProviderStatus, ["mode": .string("chat"), "providerId": .string(config.id), "providerKind": .string(config.kind.rawValue),
                                                  "displayName": .string(config.displayName), "modelId": .string(model),
                                                  "privacyLabel": .string(config.privacyLabel), "localOnly": .bool(app.settings.localOnly),
                                                  "availability": .string("available")], replyTo: e.sequence)]
    }

    func cancelPeer(requestId: String?) {
        guard let requestId else { return }
        peerTasks[requestId]?.cancel()
        peerTasks[requestId] = nil
        if phoneRun?.requestId == requestId { agentRun?.cancel() }
        if pendingPhoneAgent?.id == requestId { pendingPhoneAgent = nil }
    }

    // MARK: Coding agents started from the phone

    /// A phone's task that would edit files: it waits for your OK on this Mac.
    struct PhoneAgentRequest: Identifiable {
        let id: String
        let sessionId: String
        let deviceName: String
        let kind: AgentKind
        let workspace: PhoneAgentWorkspace
        let level: AgentPermissionLevel
        let prompt: String
    }

    var pendingPhoneAgent: PhoneAgentRequest?
    @ObservationIgnored private var phoneRun: (requestId: String, sessionId: String)?
    /// Thread-safe copy of the folders and agent readiness phones are told about in `session.approved`.
    let phoneAgents = PhoneAgentDirectory()

    var phoneWorkspaces: [PhoneAgentWorkspace] { app.settings.phoneAgentWorkspaces }

    func addPhoneWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder your phone may run coding agents in. Agents can’t act outside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AgentArguments.workspaceCheck(url)
        } catch {
            agentError = "That folder can’t be used: choose a specific project folder."
            return
        }
        guard !phoneWorkspaces.contains(where: { $0.path == url.path }), phoneWorkspaces.count < 16 else { return }
        app.settings.phoneAgentWorkspaces.append(PhoneAgentWorkspace(path: url.path, name: String(url.lastPathComponent.prefix(255))))
        refreshPhoneDirectory()
        app.connection.refreshSessions(using: .aiAgent)
        app.activityLog.record(.security, "Phones may run coding agents in \(url.lastPathComponent)", detail: "Edits still need your approval on this Mac")
    }

    func removePhoneWorkspace(_ id: String) {
        app.settings.phoneAgentWorkspaces.removeAll { $0.id == id }
        refreshPhoneDirectory()
        app.connection.refreshSessions(using: .aiAgent)
    }

    func refreshPhoneDirectory() {
        let ready = AgentKind.allCases.map { kind -> (AgentKind, Bool) in
            if case .loaded(let d)? = detections[kind] { return (kind, d.isReady) }
            return (kind, false)
        }
        phoneAgents.update(workspaces: phoneWorkspaces.map { ($0.id, $0.name) }, agents: ready)
    }

    private func handlePeerAgent(_ e: Envelope, requestId: String, device: TrustedDevice, granted: Set<Capability>) -> [OutgoingEvent] {
        func failure(_ code: String, _ message: String) -> [OutgoingEvent] {
            [OutgoingEvent(.aiError, ["requestId": .string(requestId), "code": .string(code), "message": .string(message), "retryable": .bool(false)], replyTo: e.sequence)]
        }
        guard granted.contains(.aiAgent) else {
            return failure("not_permitted", "Turn on “Coding agents” for this phone on your Mac: Settings → Devices.")
        }
        let agent = e.payload["agent"]?.objectValue
        guard let kind = PhoneAgentWire.kind(agent?["kind"]?.stringValue), let level = PhoneAgentWire.level(agent?["level"]?.stringValue),
              let workspace = phoneWorkspaces.first(where: { $0.id == agent?["workspaceId"]?.stringValue })
        else { return failure("invalid_request", "Choose an agent and one of the folders your Mac shares for agents.") }
        let prompt = (e.payload["messages"]?.arrayValue ?? []).last { $0["role"]?.stringValue == "user" }?["text"]?.stringValue ?? ""
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return failure("invalid_request", "Describe the task.") }
        guard agentRun == nil, pendingPhoneAgent == nil else { return failure("busy", "A coding agent is already running on your Mac.") }
        guard case .loaded(let detection)? = detections[kind], detection.isReady else {
            return failure("not_configured", "\(kind.displayName) isn’t ready on your Mac — install it and sign in there.")
        }
        if kind == .codex, !AgentService.isGitWorkTree(workspace.url) {
            return failure("invalid_request", "Codex needs a Git repository. Share a folder that is one.")
        }
        do {
            try AgentArguments.workspaceCheck(workspace.url)
        } catch {
            return failure("invalid_request", "“\(workspace.name)” can’t be used anymore. Check it on your Mac.")
        }
        let request = PhoneAgentRequest(id: requestId, sessionId: e.sessionId, deviceName: device.name, kind: kind, workspace: workspace, level: level, prompt: prompt)
        var status: [String: JSONValue] = [
            "mode": .string("agent"), "providerId": .string(PhoneAgentWire.wire(kind)), "providerKind": .string("coding_agent"),
            "displayName": .string(kind.displayName), "privacyLabel": .string(String("Runs on your Mac in \(workspace.name)".prefix(128))),
            "localOnly": .bool(app.settings.localOnly), "availability": .string("available"),
        ]
        if level.requiresConfirmation {
            pendingPhoneAgent = request
            NSApp.requestUserAttention(.criticalRequest)
            status["detail"] = .string("Waiting for you to allow edits on your Mac")
            app.activityLog.record(.ai, "\(device.name) asked \(kind.displayName) to edit files", detail: "Waiting for approval · \(workspace.name)")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                if self?.pendingPhoneAgent?.id == requestId { self?.denyPhoneAgent(reason: "Nobody allowed it on the Mac within 2 minutes.") }
            }
        } else {
            startPhoneAgent(request)
        }
        return [OutgoingEvent(.aiProviderStatus, status, replyTo: e.sequence)]
    }

    func approvePhoneAgent() {
        guard let request = pendingPhoneAgent else { return }
        pendingPhoneAgent = nil
        startPhoneAgent(request)
    }

    func denyPhoneAgent(reason: String = "Edits weren’t allowed on your Mac.") {
        guard let r = pendingPhoneAgent else { return }
        pendingPhoneAgent = nil
        app.connection.push(OutgoingEvent(.aiError, ["requestId": .string(r.id), "code": .string("denied"), "message": .string(reason), "retryable": .bool(false)]),
                            toSession: r.sessionId)
        app.activityLog.record(.ai, "Declined \(r.kind.displayName) edits for \(r.deviceName)")
    }

    /// Runs the agent exactly as a Mac-started task (same flags, same log on this Mac) and streams it to the phone.
    private func startPhoneAgent(_ r: PhoneAgentRequest) {
        let send: (OutgoingEvent) -> Void = { [weak self] event in self?.app.connection.push(event, toSession: r.sessionId) }
        func fail(_ code: String, _ message: String) {
            send(OutgoingEvent(.aiError, ["requestId": .string(r.id), "code": .string(code), "message": .string(String(message.prefix(500))), "retryable": .bool(false)]))
        }
        guard agentRun == nil else { return fail("busy", "A coding agent is already running on your Mac.") }
        guard case .loaded(let detection)? = detections[r.kind] else { return fail("not_configured", "\(r.kind.displayName) isn’t ready on your Mac.") }
        let run: AgentService.Run
        do {
            run = try AgentService.start(r.kind, task: AgentTask(prompt: r.prompt, workspace: r.workspace.url, level: r.level), detection: detection)
        } catch {
            return fail("launch_failed", "\(r.kind.displayName) couldn’t start: \(error)")
        }
        agentRun = run
        agentLog = []
        agentError = nil
        agentKind = r.kind
        agentLevel = r.level
        agentWorkspace = r.workspace.url
        agentPrompt = r.prompt
        phoneRun = (r.id, r.sessionId)
        app.activityLog.record(.ai, "\(r.deviceName) started \(r.kind.displayName)", detail: "\(r.level.title) in \(r.workspace.name)")
        Task {
            var sawText = false
            var success = true
            for await event in run.events {
                agentLog.append(AgentLogLine(event: event))
                if case .finished(let ok, _, _) = event { success = ok }
                if let text = PhoneAgentWire.text(for: event, sawText: sawText) {
                    for piece in PhoneAgentWire.chunks(Redactor.redact(text)) {
                        send(OutgoingEvent(.aiDelta, ["requestId": .string(r.id), "text": .string(piece)]))
                    }
                }
                if case .assistantText = event { sawText = true }
            }
            agentRun = nil
            phoneRun = nil
            send(OutgoingEvent(.aiComplete, ["requestId": .string(r.id), "stopReason": .string(success ? "end_turn" : "error"), "servedBy": .string(r.kind.displayName)]))
            app.activityLog.record(.ai, "\(r.kind.displayName) finished for \(r.deviceName)")
        }
    }

    // MARK: Coding agents

    func detectAgents() async {
        guard !demo else { return }
        refreshPhoneDirectory()
        for kind in AgentKind.allCases {
            detections[kind] = .loading
            detections[kind] = .loaded(await AgentService.detect(kind))
        }
        refreshPhoneDirectory()
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the project folder the agent may work in. It can’t act outside this folder."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try AgentArguments.workspaceCheck(url)
                agentWorkspace = url
                agentError = nil
            } catch {
                agentError = "That folder can’t be used: choose a specific project folder."
            }
        }
    }

    var canStartAgent: Bool {
        guard agentRun == nil, agentWorkspace != nil, !agentPrompt.trimmingCharacters(in: .whitespaces).isEmpty,
              case .loaded(let d)? = detections[agentKind], d.isReady else { return false }
        return true
    }

    /// Edit runs require an explicit confirmation (MyBuddy's own approval layer on top of the agent's).
    func requestStartAgent() {
        if agentLevel.requiresConfirmation { confirmEditRun = true } else { startAgent() }
    }

    func startAgent() {
        confirmEditRun = false
        guard let workspace = agentWorkspace, case .loaded(let detection)? = detections[agentKind] else { return }
        if agentKind == .codex, !AgentService.isGitWorkTree(workspace), !allowNonGitWorkspace {
            agentError = "Codex requires a Git repository. Turn on “Allow non-Git folder” if you’re sure."
            return
        }
        let task = AgentTask(prompt: agentPrompt, workspace: workspace, level: agentLevel, allowNonGitWorkspace: allowNonGitWorkspace)
        do {
            let run = try AgentService.start(agentKind, task: task, detection: detection)
            agentRun = run
            agentLog = []
            agentError = nil
            app.activityLog.record(.ai, "Started \(agentKind.displayName)", detail: "\(agentLevel.title) in \(workspace.lastPathComponent)")
            Task {
                for await event in run.events { agentLog.append(AgentLogLine(event: event)) }
                agentRun = nil
                app.activityLog.record(.ai, "\(agentKind.displayName) finished")
            }
        } catch {
            agentError = "\(error)"
        }
    }

    func stopAgent() {
        agentRun?.cancel()
        app.activityLog.record(.ai, "Stopped \(agentKind.displayName)")
    }

    var changedFiles: [String] {
        agentLog.compactMap { if case .fileChanged(let path, _) = $0.event { return path } else { return nil } }
    }
}

/// Thread-safe snapshot of privacy settings for non-main-actor readers.
final class SettingsBox: @unchecked Sendable {
    static let shared = SettingsBox()
    private let lock = NSLock()
    private var value = AIPrivacySettings()
    var privacy: AIPrivacySettings {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// What phones with "Coding agents" are told at session start: the shared folders (names only) and which agents are
/// ready. Read from the connection's queue, so it's a locked snapshot.
final class PhoneAgentDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var workspaces: [(id: String, name: String)] = []
    private var agents: [(kind: AgentKind, ready: Bool)] = []

    func update(workspaces: [(String, String)], agents: [(AgentKind, Bool)]) {
        lock.withLock {
            self.workspaces = workspaces.map { (id: $0.0, name: $0.1) }
            self.agents = agents.map { (kind: $0.0, ready: $0.1) }
        }
    }

    var sessionExtras: [String: JSONValue] {
        lock.withLock {
            ["agentWorkspaces": .array(workspaces.prefix(16).map { .object(["workspaceId": .string($0.id), "name": .string($0.name)]) }),
             "agents": .array(agents.prefix(4).map { .object(["kind": .string(PhoneAgentWire.wire($0.kind)), "ready": .bool($0.ready)]) })]
        }
    }
}
