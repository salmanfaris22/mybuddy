import MyBuddyCore
import MyBuddyDesign
import MyBuddyHost
import SwiftUI

struct AIStudioView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ai = model.ai
        VStack(spacing: 0) {
            HStack(spacing: MBSpace.m) {
                Picker("Mode", selection: $ai.mode) {
                    ForEach(AIStore.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .labelsHidden()
                Text(ai.mode == .chat ? "API models and local model servers. Keys stay in this Mac’s Keychain."
                                      : "Official CLIs run on this Mac in a folder you choose, with their own sign-in and approvals.")
                    .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                Spacer()
            }
            .padding(.horizontal, MBSpace.xl).padding(.vertical, MBSpace.m)
            Rectangle().fill(MBColor.border).frame(height: 1)
            if ai.mode == .chat { ChatPane() } else { AgentsPane() }
        }
    }
}

// MARK: - Chat

struct ChatPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ai = model.ai
        let p = ai.selectedProvider
        VStack(spacing: 0) {
            HStack(spacing: MBSpace.s) {
                Menu {
                    ForEach(ai.providers) { provider in
                        Button(provider.displayName) { ai.selectProvider(provider.id) }
                    }
                } label: { Label(p.displayName, systemImage: p.isCloud ? "cloud" : "desktopcomputer") }
                    .menuStyle(.borderlessButton).fixedSize()
                Text("·").foregroundStyle(MBColor.textTertiary)
                modelMenu
                Button { Task { await ai.refreshModels() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(MBButtonStyle(.ghost, compact: true)).help("Refresh models from the provider").disabled(model.demoMode)
                Spacer()
                Label(p.privacyLabel, systemImage: p.isCloud ? "arrow.up.forward.circle" : "lock.circle")
                    .font(MBFont.callout).foregroundStyle(p.isCloud ? MBColor.warning : MBColor.accent)
                if !ai.transcript.isEmpty {
                    Button("New chat") { ai.clearConversation() }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                }
            }
            .padding(.horizontal, MBSpace.xl).padding(.vertical, MBSpace.s)

            if ai.blockedByLocalOnly {
                StateView(.notAuthorized, title: "Blocked by Local Only", message: "Local Only is on, so \(p.displayName) can’t receive prompts. Switch to Ollama or turn Local Only off in Settings → Privacy.") {
                    Button("Use Ollama") { ai.selectProvider("ollama") }.buttonStyle(MBButtonStyle(.secondary))
                }
                Spacer()
            } else if p.kind.requiresAPIKey && !ai.hasKey(p) && !model.demoMode {
                StateView(.notAuthorized, title: "Add your \(p.kind.displayName) key", message: "\(p.kind.authDescription). MyBuddy never sends it to your phone or puts it in logs.") {
                    Button("Open AI provider settings") { model.selection = .settings }.buttonStyle(MBButtonStyle(.primary))
                }
                Spacer()
            } else {
                transcript
            }
            composer
        }
    }

    private var modelMenu: some View {
        let ai = model.ai
        let p = ai.selectedProvider
        let models: [ModelDescriptor] = ai.modelsState.value ?? p.models
        return Menu {
            if models.isEmpty { Text("No models loaded — press Refresh") }
            ForEach(models) { m in
                Button(m.displayName + (m.detail.map { " — \($0)" } ?? "")) { ai.selectModel(m.id) }
            }
        } label: {
            Text(p.selectedModel ?? "Choose model").font(MBFont.mono)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var transcript: some View {
        let ai = model.ai
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: MBSpace.l) {
                    if ai.transcript.isEmpty {
                        StateView(.empty, title: "Ask anything", message: "Messages go to \(ai.selectedProvider.displayName). Nothing on this Mac — screen, files, health data — is included unless you paste it in.")
                            .padding(.top, MBSpace.xxl)
                    }
                    ForEach(ai.transcript) { turn in
                        ChatBubble(turn: turn).id(turn.id)
                    }
                    if case .failed(let message) = ai.modelsState {
                        Text(message).font(MBFont.callout).foregroundStyle(MBColor.danger)
                    }
                }
                .padding(.horizontal, MBSpace.xl).padding(.vertical, MBSpace.l)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: ai.transcript.last?.text) { _, _ in
                if let last = ai.transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        @Bindable var ai = model.ai
        return HStack(alignment: .bottom, spacing: MBSpace.s) {
            TextField("Message \(ai.selectedProvider.displayName)…", text: $ai.draft, axis: .vertical)
                .textFieldStyle(.plain).font(MBFont.body).lineLimit(1...6)
                .padding(MBSpace.m)
                .background(RoundedRectangle(cornerRadius: MBRadius.md).fill(MBColor.elevated))
                .overlay(RoundedRectangle(cornerRadius: MBRadius.md).strokeBorder(MBColor.border))
                .onSubmit { ai.send() }
            if ai.isStreaming {
                Button { ai.stop() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(MBButtonStyle(.danger))
            } else {
                Button { ai.send() } label: { Label("Send", systemImage: "arrow.up") }
                    .buttonStyle(MBButtonStyle(.primary))
                    .disabled(ai.draft.trimmingCharacters(in: .whitespaces).isEmpty || ai.blockedByLocalOnly)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, MBSpace.xl).padding(.vertical, MBSpace.m)
        .background(MBColor.base.opacity(0.7))
    }
}

struct ChatBubble: View {
    let turn: ChatTurn

    var body: some View {
        if turn.role == .user {
            HStack {
                Spacer(minLength: 80)
                Text(turn.text).font(MBFont.body).foregroundStyle(MBColor.textPrimary).textSelection(.enabled)
                    .padding(MBSpace.m)
                    .background(RoundedRectangle(cornerRadius: MBRadius.lg, style: .continuous).fill(MBColor.elevatedHover))
            }
        } else {
            VStack(alignment: .leading, spacing: MBSpace.s) {
                HStack(spacing: MBSpace.s) {
                    BrandMark(size: 18, live: turn.status == .streaming)
                    Text(turn.servedBy ?? turn.providerName ?? "Assistant").font(MBFont.mono).foregroundStyle(MBColor.textTertiary)
                    if let note = turn.fallbackNote { Text(note).font(MBFont.callout).foregroundStyle(MBColor.warning) }
                }
                switch turn.status {
                case .refused(let category):
                    Label("The model declined this request\(category.map { " (\($0))" } ?? ""). Partial output was discarded.", systemImage: "hand.raised")
                        .font(MBFont.body).foregroundStyle(MBColor.warning)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").font(MBFont.body).foregroundStyle(MBColor.danger)
                default:
                    if !turn.reasoning.isEmpty {
                        DisclosureGroup("Reasoning summary") {
                            Text(turn.reasoning).font(MBFont.callout).foregroundStyle(MBColor.textTertiary).textSelection(.enabled)
                        }
                        .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                    }
                    Text(turn.text.isEmpty && turn.status == .streaming ? "…" : turn.text)
                        .font(MBFont.body).foregroundStyle(MBColor.textPrimary).textSelection(.enabled).lineSpacing(3)
                    if turn.status == .cancelled { Text("Stopped").font(MBFont.callout).foregroundStyle(MBColor.textTertiary) }
                    if let u = turn.usage, let i = u.inputTokens, let o = u.outputTokens {
                        Text("\(i) in · \(o) out tokens (provider-reported)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(MBColor.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Coding agents

struct AgentsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ai = model.ai
        Page {
            AdaptiveColumns {
                ForEach(AgentKind.allCases) { kind in AgentCard(kind: kind) }
            }
            Panel {
                VStack(alignment: .leading, spacing: MBSpace.m) {
                    SectionHeader("New task", subtitle: "MyBuddy approves the folder and permission level; the agent’s own approvals still apply")
                    HStack(spacing: MBSpace.m) {
                        Picker("Agent", selection: $ai.agentKind) {
                            ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                        }
                        .frame(width: 220)
                        Picker("Permission", selection: $ai.agentLevel) {
                            ForEach(AgentPermissionLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .frame(width: 280)
                    }
                    HStack(spacing: MBSpace.s) {
                        Image(systemName: "folder").foregroundStyle(MBColor.info)
                        Text(ai.agentWorkspace.map { Redactor.redact($0.path) } ?? "No workspace chosen").font(MBFont.mono)
                            .foregroundStyle(ai.agentWorkspace == nil ? MBColor.textTertiary : MBColor.textPrimary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose folder…") { ai.chooseWorkspace() }.buttonStyle(MBButtonStyle(.secondary, compact: true))
                    }
                    if ai.agentKind == .codex {
                        Toggle("Allow a non-Git folder (Codex can’t show a reviewable diff)", isOn: $ai.allowNonGitWorkspace).font(MBFont.callout)
                    }
                    TextField("Describe the task…", text: $ai.agentPrompt, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(3...8).font(MBFont.body)
                        .padding(MBSpace.m)
                        .background(RoundedRectangle(cornerRadius: MBRadius.md).fill(MBColor.base))
                        .overlay(RoundedRectangle(cornerRadius: MBRadius.md).strokeBorder(MBColor.border))
                    HStack {
                        Text(levelExplanation).font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                        Spacer()
                        if ai.agentRun != nil {
                            Button { ai.stopAgent() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(MBButtonStyle(.danger))
                        } else {
                            Button { ai.requestStartAgent() } label: { Label("Start task", systemImage: "play.fill") }
                                .buttonStyle(MBButtonStyle(.primary)).disabled(!ai.canStartAgent || model.demoMode)
                        }
                    }
                    if let error = ai.agentError { Text(error).font(MBFont.callout).foregroundStyle(MBColor.danger) }
                }
            }
            .confirmationDialog("Let \(ai.agentKind.displayName) edit files?", isPresented: $ai.confirmEditRun) {
                Button("Allow edits in \(ai.agentWorkspace?.lastPathComponent ?? "this folder")") { ai.startAgent() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The agent may change files inside the chosen folder. Shell commands stay blocked. Review changes before you commit.")
            }

            Panel {
                VStack(alignment: .leading, spacing: MBSpace.m) {
                    SectionHeader("From your phone", subtitle: "Phones with “Coding agents” (Settings → Devices) can start tasks in these folders. Read-only tasks start at once; edits wait for your OK here.") {
                        Button("Add folder…") { ai.addPhoneWorkspace() }.buttonStyle(MBButtonStyle(.secondary, compact: true)).disabled(model.demoMode)
                    }
                    if ai.phoneWorkspaces.isEmpty {
                        Text("No folders shared with your phone yet.").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                    }
                    ForEach(ai.phoneWorkspaces) { ws in
                        HStack(spacing: MBSpace.s) {
                            Image(systemName: "folder").foregroundStyle(MBColor.info)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ws.name).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                                Text(Redactor.redact(ws.path)).font(MBFont.mono).foregroundStyle(MBColor.textTertiary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button { ai.removePhoneWorkspace(ws.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(MBColor.textSecondary).help("Stop sharing this folder with phones")
                        }
                    }
                }
            }

            if !ai.agentLog.isEmpty || ai.agentRun != nil {
                Panel {
                    VStack(alignment: .leading, spacing: MBSpace.s) {
                        SectionHeader("Run", subtitle: ai.agentRun != nil ? "Running — events from the agent’s JSON stream" : "Finished") {
                            if ai.agentRun != nil { ProgressView().controlSize(.small) }
                        }
                        ForEach(ai.agentLog) { line in AgentEventRow(event: line.event) }
                        if !ai.changedFiles.isEmpty {
                            Divider().overlay(MBColor.border)
                            Eyebrow("Changed files — review before committing")
                            ForEach(ai.changedFiles, id: \.self) { Text(Redactor.redact($0)).font(MBFont.mono).foregroundStyle(MBColor.textSecondary) }
                        }
                    }
                }
            }
        }
    }

    private var levelExplanation: String {
        switch model.ai.agentLevel {
        case .readOnly: model.ai.agentKind == .claudeCode ? "Runs with --permission-mode plan --restricted: reads and plans, no edits, no shell." : "Runs with --sandbox read-only."
        case .editWorkspace: model.ai.agentKind == .claudeCode ? "Runs with --permission-mode acceptEdits --restricted: edits files in the folder; shell stays blocked." : "Runs with --sandbox workspace-write inside the folder."
        }
    }
}

struct AgentCard: View {
    @Environment(AppModel.self) private var model
    let kind: AgentKind

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: MBSpace.s) {
                SectionHeader(kind.displayName, subtitle: "Coding agent CLI") {
                    Button { Task { await model.ai.detectAgents() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(MBButtonStyle(.ghost, compact: true)).disabled(model.demoMode).accessibilityLabel("Re-check \(kind.displayName)")
                }
                switch model.ai.detections[kind] {
                case .loaded(let d):
                    if let path = d.executablePath {
                        MetricRow("Executable", value: Redactor.redact(path))
                        MetricRow("Version", value: d.version ?? "unknown")
                        MetricRow("Sign-in", value: d.auth.title, tone: d.isReady ? .live : .warning)
                        if !d.isReady { Text("Sign in with the official CLI in Terminal. MyBuddy never handles its credentials.").font(MBFont.callout).foregroundStyle(MBColor.textTertiary) }
                    } else {
                        Text("Not installed").font(MBFont.bodyEmphasis).foregroundStyle(MBColor.warning)
                        Text(kind.installHint).font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                    }
                    Link("Official documentation", destination: kind.docsURL).font(MBFont.callout)
                case .loading:
                    Skeleton(); Skeleton()
                default:
                    Text("Not checked yet").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                }
            }
        }
    }
}

struct AgentEventRow: View {
    let event: AgentEvent

    var body: some View {
        let (symbol, tone, text): (String, MBTone, String) = switch event {
        case .started(_, let model): ("play.circle", .info, "Session started\(model.map { " · \($0)" } ?? "")")
        case .assistantText(let t): ("text.bubble", .neutral, t)
        case .toolProposed(let name, let summary): ("wrench.and.screwdriver", .info, "\(name) \(summary)")
        case .commandStarted(let c): ("terminal", .warning, c)
        case .commandFinished(let c, let code): ("terminal", code == 0 ? .live : .warning, "\(c) → exit \(code.map(String.init) ?? "?")")
        case .fileChanged(let path, let kind): ("doc.badge.ellipsis", .warning, "\(kind): \(Redactor.redact(path))")
        case .permissionDenied(let what): ("hand.raised", .warning, "Denied: \(what)")
        case .notice(let n): ("info.circle", .neutral, n)
        case .finished(let ok, let summary, let cost): (ok ? "checkmark.circle" : "xmark.circle", ok ? .live : .danger,
                                                        summary + (cost.map { String(format: " · ~$%.3f (CLI estimate)", $0) } ?? ""))
        }
        return HStack(alignment: .top, spacing: MBSpace.s) {
            Image(systemName: symbol).foregroundStyle(tone.color).frame(width: 18)
            Text(text).font(MBFont.callout).foregroundStyle(MBColor.textSecondary).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// A phone asked a coding agent to edit files: nothing runs until you allow it here.
struct PhoneAgentApprovalSheet: View {
    @Environment(AppModel.self) private var model
    let request: AIStore.PhoneAgentRequest

    var body: some View {
        VStack(alignment: .leading, spacing: MBSpace.l) {
            HStack(spacing: MBSpace.m) {
                Image(systemName: "hammer.circle.fill").font(.system(size: 30)).foregroundStyle(MBColor.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let \(request.kind.displayName) edit files?").font(MBFont.title).foregroundStyle(MBColor.textPrimary)
                    Text("Asked from \(request.deviceName)").font(MBFont.callout).foregroundStyle(MBColor.textSecondary)
                }
            }
            MetricRow("Folder", value: request.workspace.name, note: Redactor.redact(request.workspace.path))
            MetricRow("Permission", value: request.level.title)
            VStack(alignment: .leading, spacing: MBSpace.xs) {
                Eyebrow("Task")
                ScrollView {
                    Text(request.prompt).font(MBFont.body).foregroundStyle(MBColor.textPrimary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .padding(MBSpace.m)
                .background(RoundedRectangle(cornerRadius: MBRadius.md).fill(MBColor.base))
            }
            Text("The agent may change files inside this folder only; shell commands stay blocked. Review the changes before you commit. Declines automatically after 2 minutes.")
                .font(MBFont.callout).foregroundStyle(MBColor.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Decline", role: .cancel) { model.ai.denyPhoneAgent() }.buttonStyle(MBButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button("Allow edits") { model.ai.approvePhoneAgent() }.buttonStyle(MBButtonStyle(.primary))
            }
        }
        .padding(MBSpace.xl)
        .frame(width: 520)
        .background(MBColor.surface)
        .interactiveDismissDisabled()
    }
}
