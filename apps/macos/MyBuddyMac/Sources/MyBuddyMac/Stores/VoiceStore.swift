import AppKit
import Foundation
import MyBuddyCore
import MyBuddyHost
import Observation

/// MyBuddy Voice on the Mac: push-to-talk → transcript → typed intent → policy → (approval) → action → spoken result.
@MainActor
@Observable
final class VoiceStore {
    @ObservationIgnored var app: AppModel!
    let demo: Bool
    private(set) var state: VoicePipelineState = .idle
    private(set) var level: Double = 0
    private(set) var caption = ""
    private(set) var history: [VoiceOutcome] = []
    private(set) var micPermission: PermissionState = .notDetermined
    private(set) var speechPermission: PermissionState = .notDetermined
    private(set) var onDevice = false
    var typedCommand = ""
    /// Approval requested by a phone-originated command (approved here, on the Mac).
    private(set) var peerApproval: (intent: VoiceIntent, device: String, sessionId: String, utteranceId: String, intentId: String)?

    @ObservationIgnored private let input = SpeechInputService()
    @ObservationIgnored private let output = SpeechOutputService()

    init(demo: Bool) {
        self.demo = demo
        if demo {
            history = DemoData.voiceHistory
            micPermission = .granted
            speechPermission = .granted
        }
    }

    /// Speech capture needs a bundled app (Info.plist usage descriptions); `swift run` cannot use it.
    var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    var orbPhase: VoiceOrbPhaseValue {
        switch state {
        case .listening: .listening
        case .understanding, .executing: .thinking
        case .speaking: .speaking
        case .failed: .error
        default: .idle
        }
    }

    enum VoiceOrbPhaseValue { case idle, listening, thinking, speaking, error }

    var lastOutcome: VoiceOutcome? { history.first }

    func refreshPermissions() {
        guard !demo else { return }
        micPermission = SystemPermissions.microphone
        speechPermission = SystemPermissions.speechRecognition
    }

    func requestPermissions() async {
        guard isBundled else { return }
        _ = await SpeechInputService.requestAuthorization()
        refreshPermissions()
    }

    // MARK: Push-to-talk

    func startListening() {
        guard !demo, isBundled else { return }
        refreshPermissions()
        guard micPermission == .granted, speechPermission == .granted else {
            state = .failed("Microphone and speech recognition permission are needed.")
            return
        }
        output.stop()
        caption = ""
        do {
            try input.start(locale: .current, onLevel: { [weak self] l in
                Task { @MainActor in self?.level = l }
            }, onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            })
            onDevice = input.usesOnDeviceRecognition
            state = .listening(partial: "")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stopListening() {
        guard case .listening = state else { return }
        input.finish()
        level = 0
        if caption.isEmpty { state = .idle }
    }

    func cancel() {
        input.stop()
        output.stop()
        level = 0
        if case .awaitingApproval = state { record(VoiceOutcome(transcript: caption, intent: nil, status: .denied, summary: "Cancelled")) }
        state = .idle
    }

    private func handle(_ event: SpeechInputService.Event) {
        switch event {
        case .partial(let text):
            caption = text
            state = .listening(partial: text)
        case .final(let text):
            caption = text
            input.stop()
            level = 0
            Task { await understand(text) }
        case .failed(let message):
            input.stop()
            level = 0
            if caption.isEmpty { state = .failed(message) } else { Task { await understand(caption) } }
        }
    }

    /// Typed alternative to speaking (accessibility, noisy rooms).
    func submitTyped() {
        let text = typedCommand
        typedCommand = ""
        caption = text
        Task { await understand(text) }
    }

    func understand(_ transcript: String) async {
        state = .understanding(transcript: transcript)
        switch VoiceIntentParser.parse(transcript) {
        case .intent(let intent):
            if intent.requiresApproval {
                state = .awaitingApproval(intent, transcript: transcript)
            } else {
                await run(intent, transcript: transcript)
            }
        case .clarification(let question):
            finish(VoiceOutcome(transcript: transcript, intent: nil, status: .clarification, summary: question))
        case .rejected(let why):
            finish(VoiceOutcome(transcript: transcript, intent: nil, status: .rejected, summary: why))
        case .unrecognized:
            finish(VoiceOutcome(transcript: transcript, intent: nil, status: .unrecognized,
                                summary: "I didn’t catch a command I can do. Try “Show my Mac battery health”."))
        }
    }

    func approvePending() {
        guard case .awaitingApproval(let intent, let transcript) = state else { return }
        Task { await run(intent, transcript: transcript) }
    }

    func denyPending() {
        guard case .awaitingApproval(let intent, let transcript) = state else { return }
        finish(VoiceOutcome(transcript: transcript, intent: intent, status: .denied, summary: "Okay, I won’t do that."))
    }

    private func run(_ intent: VoiceIntent, transcript: String) async {
        state = .executing(intent)
        let (status, summary) = await execute(intent, local: true)
        finish(VoiceOutcome(transcript: transcript, intent: intent, status: status, summary: summary))
    }

    private func finish(_ outcome: VoiceOutcome) {
        record(outcome)
        state = .speaking(outcome.summary)
        output.muted = app.settings.voiceMuted
        output.rate = app.settings.voiceRate
        output.voiceIdentifier = app.settings.voiceIdentifier
        output.speak(outcome.summary) { [weak self] in
            Task { @MainActor in
                guard let self, case .speaking = self.state else { return }
                self.state = .finished(outcome)
            }
        }
    }

    private func record(_ outcome: VoiceOutcome) {
        history.insert(outcome, at: 0)
        if history.count > 20 { history.removeLast() }
        app.activityLog.record(.voice, outcome.intent?.title ?? "Voice command", detail: outcome.status.rawValue)
    }

    // MARK: Actions (typed, allowlisted)

    func execute(_ intent: VoiceIntent, local: Bool) async -> (VoiceOutcome.Status, String) {
        switch intent {
        case .showBatteryHealth:
            if local { app.selection = .health }
            await app.health.refresh()
            guard let b = app.health.snapshot?.battery, b.present.usableValue == true else {
                return (.failed, "Battery details aren’t available on this Mac.")
            }
            var parts: [String] = []
            if let l = b.levelPercent.usableValue { parts.append("Battery at \(l) percent\(b.isCharging.usableValue == true ? ", charging" : "")") }
            if let c = b.condition.usableValue { parts.append("condition \(c)") }
            if let n = b.cycleCount.usableValue { parts.append("\(n) cycles") }
            if let m = b.maximumCapacityPercent.usableValue { parts.append("maximum capacity \(m) percent") }
            return (.succeeded, parts.joined(separator: ", ") + ".")
        case .showHealthReport:
            if local { app.selection = .health }
            await app.health.refresh()
            let findings = app.health.snapshot.map(HealthAssessment.findings) ?? []
            let worst = findings.first
            return (.succeeded, worst.map { "Here’s your health report. \($0.area): \($0.title)." } ?? "Here’s your Mac health report.")
        case .startScreenSharing:
            if local { app.selection = .remote }
            return (.failed, "Screen sharing starts from your phone: open Remote in MyBuddy and tap View screen. I opened Remote Desktop here so you can see its status.")
        case .openApp(let name):
            let matches = WorkspaceAppCatalog.search(name, in: WorkspaceAppCatalog.installedApps(), limit: 3)
            guard let first = matches.first else { return (.failed, "I couldn’t find an app called \(name).") }
            if matches.count > 1, first.name.lowercased() != name.lowercased() {
                return (.failed, "I found several apps matching \(name). Which one: \(matches.map(\.name).joined(separator: ", "))?")
            }
            let status = await WorkspaceAppCatalog.open(bundleId: first.bundleId)
            return status == "opened" ? (.succeeded, "Opened \(first.name).") : (.failed, "\(first.name) didn’t open.")
        case .openFolder(let folder):
            let dir: FileManager.SearchPathDirectory = switch folder {
            case .downloads: .downloadsDirectory
            case .documents: .documentDirectory
            case .desktop: .desktopDirectory
            }
            guard local else {
                return (.needsPermission, "Opening folders from the phone needs the folder shared in Files & Clipboard on the Mac.")
            }
            guard let url = FileManager.default.urls(for: dir, in: .userDomainMask).first, NSWorkspace.shared.open(url) else {
                return (.failed, "I couldn’t open that folder.")
            }
            return (.succeeded, "Opened your \(folder.rawValue.capitalized) folder.")
        case .sendTextToMac(let text):
            app.files.applyText(text, origin: "Voice")
            return (.succeeded, "Copied it to this Mac’s clipboard.")
        case .pauseClipboardSync:
            app.settings.clipboardPaused = true
            return (.succeeded, "Clipboard sync is paused.")
        case .resumeClipboardSync:
            app.settings.clipboardPaused = false
            return (.succeeded, "Clipboard sync is back on.")
        case .switchAssistant(let target):
            let id = switch target {
            case .localModel: "ollama"
            case .anthropic: "anthropic"
            case .openAI: "openai"
            }
            if app.settings.localOnly, target != .localModel {
                return (.denied, "Local Only is on, so I can’t switch to \(target.title).")
            }
            app.ai.selectProvider(id)
            return (.succeeded, "The assistant now uses \(target.title).")
        case .summarizeVisibleApp:
            return (.needsPermission, "Summarizing the screen needs AI screen analysis, which isn’t available in this build.")
        }
    }

    // MARK: Phone-originated voice

    func handlePeer(_ e: Envelope, device: TrustedDevice, granted: Set<Capability>) async -> [OutgoingEvent] {
        guard e.type == .voiceTranscript, e.payload["isFinal"]?.boolValue == true,
              let utteranceId = e.payload["utteranceId"]?.stringValue, let text = e.payload["text"]?.stringValue else { return [] }
        func result(_ intentId: String, _ status: VoiceOutcome.Status, _ summary: String) -> OutgoingEvent {
            let wire = switch status {
            case .succeeded: "succeeded"
            case .denied, .rejected: "denied"
            case .needsPermission: "needs_permission"
            default: "failed"
            }
            return OutgoingEvent(.voiceIntentResult, ["utteranceId": .string(utteranceId), "intentId": .string(intentId),
                                                      "status": .string(wire), "spokenSummary": .string(String(summary.prefix(500)))], replyTo: e.sequence)
        }
        switch VoiceIntentParser.parse(text) {
        case .intent(let intent):
            let proposed = OutgoingEvent(.voiceIntentProposed, ["utteranceId": .string(utteranceId), "intentId": .string(intent.intentId),
                                                                "intent": .object(["kind": .string(intent.intentId)]),
                                                                "requiresApproval": .bool(intent.requiresApproval), "risk": .string(intent.risk.rawValue)], replyTo: e.sequence)
            guard granted.contains(intent.requiredCapability) else {
                return [proposed, result(intent.intentId, .needsPermission, "“\(intent.requiredCapability.title)” isn’t enabled for \(device.name) on the Mac.")]
            }
            if intent.requiresApproval {
                peerApproval = (intent, device.name, e.sessionId, utteranceId, intent.intentId)
                app.activityLog.record(.voice, "\(device.name) asked: \(intent.title)", detail: "Waiting for approval on the Mac")
                return [proposed]
            }
            let (status, summary) = await execute(intent, local: false)
            app.activityLog.record(.voice, "\(device.name): \(intent.title)", detail: status.rawValue)
            return [proposed, result(intent.intentId, status, summary)]
        case .clarification(let q):
            return [result("clarification", .clarification, q)]
        case .rejected(let why):
            return [result("rejected", .rejected, why)]
        case .unrecognized:
            return [result("unrecognized", .unrecognized, "I didn’t catch a command I can do.")]
        }
    }

    func resolvePeerApproval(_ approve: Bool) {
        guard let p = peerApproval else { return }
        peerApproval = nil
        Task {
            let (status, summary) = approve ? await execute(p.intent, local: false) : (.denied, "Declined on the Mac.")
            let wire = status == .succeeded ? "succeeded" : status == .denied ? "denied" : status == .needsPermission ? "needs_permission" : "failed"
            app.connection.push(OutgoingEvent(.voiceIntentResult, ["utteranceId": .string(p.utteranceId), "intentId": .string(p.intentId),
                                                                   "status": .string(wire), "spokenSummary": .string(summary)]), toSession: p.sessionId)
            app.activityLog.record(.voice, "\(p.device): \(p.intent.title)", detail: approve ? status.rawValue : "declined")
        }
    }
}
