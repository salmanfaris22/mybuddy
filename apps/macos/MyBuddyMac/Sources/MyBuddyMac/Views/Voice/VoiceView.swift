import MyBuddyCore
import MyBuddyDesign
import MyBuddyHost
import SwiftUI

struct VoiceView: View {
    @Environment(AppModel.self) private var model
    @State private var pressing = false

    var body: some View {
        let voice = model.voice
        Page {
            Panel(padding: MBSpace.xxl) {
                VStack(spacing: MBSpace.l) {
                    VoiceOrb(phase: orbPhase, level: voice.level, size: 230)
                        .padding(.top, MBSpace.s)
                    Text(statusLine).font(MBFont.title).foregroundStyle(MBColor.textPrimary)
                    Text(voice.caption.isEmpty ? "Hold the button and speak. MyBuddy only listens while you hold it." : "“\(voice.caption)”")
                        .font(MBFont.body).foregroundStyle(voice.caption.isEmpty ? MBColor.textTertiary : MBColor.textPrimary)
                        .multilineTextAlignment(.center).frame(maxWidth: 560).frame(minHeight: 36)
                        .accessibilityLabel(voice.caption.isEmpty ? "No transcript yet" : "Transcript: \(voice.caption)")
                    if case .awaitingApproval(let intent, _) = voice.state {
                        ApprovalCard(title: intent.title, risk: intent.risk, approve: voice.approvePending, deny: voice.denyPending)
                    }
                    if let p = voice.peerApproval {
                        ApprovalCard(title: "\(p.device) asks: \(p.intent.title)", risk: p.intent.risk,
                                     approve: { voice.resolvePeerApproval(true) }, deny: { voice.resolvePeerApproval(false) })
                    }
                    talkControl
                    HStack(spacing: MBSpace.s) {
                        TextField("Or type a command, e.g. “show my battery health”", text: Binding(get: { voice.typedCommand }, set: { voice.typedCommand = $0 }))
                            .textFieldStyle(.plain).font(MBFont.body)
                            .padding(.horizontal, MBSpace.m).padding(.vertical, MBSpace.s)
                            .background(RoundedRectangle(cornerRadius: MBRadius.md).fill(MBColor.base))
                            .overlay(RoundedRectangle(cornerRadius: MBRadius.md).strokeBorder(MBColor.border))
                            .onSubmit { voice.submitTyped() }
                        Button("Run") { voice.submitTyped() }.buttonStyle(MBButtonStyle(.secondary, compact: true))
                            .disabled(voice.typedCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity)
            }

            AdaptiveColumns {
                Panel {
                    VStack(alignment: .leading, spacing: MBSpace.s) {
                        SectionHeader("Recent commands", subtitle: "Typed intents only — nothing is executed from free text")
                        if voice.history.isEmpty {
                            Text("No commands yet.").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                        }
                        ForEach(Array(voice.history.prefix(6).enumerated()), id: \.offset) { _, o in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("“\(o.transcript)”").font(MBFont.body).foregroundStyle(MBColor.textPrimary).lineLimit(1)
                                    Spacer()
                                    StatusPill(o.status.rawValue, tone: o.status == .succeeded ? .live : o.status == .rejected || o.status == .failed ? .danger : .warning)
                                }
                                Text(o.summary).font(MBFont.callout).foregroundStyle(MBColor.textTertiary).lineLimit(2)
                            }
                            .padding(.vertical, MBSpace.xs)
                        }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: MBSpace.s) {
                        SectionHeader("Voice settings")
                        MetricRow("Microphone", value: voice.micPermission.title, tone: voice.micPermission == .granted ? .live : .warning)
                        MetricRow("Speech recognition", value: voice.speechPermission.title, tone: voice.speechPermission == .granted ? .live : .warning)
                        MetricRow("Recognition", value: voice.onDevice ? "On this Mac" : "Apple speech service (may use the network)")
                        Toggle("Mute spoken replies", isOn: Binding(get: { model.settings.voiceMuted }, set: { model.settings.voiceMuted = $0 }))
                            .toggleStyle(.switch).font(MBFont.body)
                        HStack {
                            Text("Speaking rate").font(MBFont.body).foregroundStyle(MBColor.textSecondary)
                            Slider(value: Binding(get: { Double(model.settings.voiceRate) }, set: { model.settings.voiceRate = Float($0) }), in: 0.3...0.65)
                        }
                        if !voice.isBundled && !model.demoMode {
                            Text("Run the bundled MyBuddy.app (scripts/build-app.sh) to use the microphone.").font(MBFont.callout).foregroundStyle(MBColor.warning)
                        } else if voice.micPermission != .granted || voice.speechPermission != .granted {
                            Button("Allow microphone & speech…") { Task { await voice.requestPermissions() } }.buttonStyle(MBButtonStyle(.secondary, compact: true))
                        }
                        Text("No wake word: MyBuddy never listens in the background.").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                    }
                }
            }
        }
        .onAppear { voice.refreshPermissions() }
    }

    private var orbPhase: VoiceOrbPhase {
        switch model.voice.orbPhase {
        case .idle: .idle
        case .listening: .listening
        case .thinking: .thinking
        case .speaking: .speaking
        case .error: .error
        }
    }

    private var statusLine: String {
        switch model.voice.state {
        case .idle: "MyBuddy Voice"
        case .listening: "Listening…"
        case .understanding: "Understanding…"
        case .awaitingApproval: "Needs your OK"
        case .executing(let i): i.title
        case .speaking: "Answering"
        case .finished(let o): o.status == .succeeded ? "Done" : "Finished"
        case .failed: "Something went wrong"
        }
    }

    private var talkControl: some View {
        let voice = model.voice
        let listening: Bool = { if case .listening = voice.state { return true } else { return false } }()
        return HStack(spacing: MBSpace.m) {
            Text(listening ? "Release to send" : "Hold to talk")
                .font(MBFont.bodyEmphasis)
                .foregroundStyle(listening ? MBColor.onAccent : MBColor.textPrimary)
                .padding(.horizontal, MBSpace.xl).padding(.vertical, MBSpace.m)
                .background(Capsule().fill(listening ? MBColor.accent : MBColor.elevatedHover))
                .overlay(Capsule().strokeBorder(listening ? .clear : MBColor.borderStrong))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressing {
                            pressing = true
                            voice.startListening()
                        }
                    }
                    .onEnded { _ in
                        pressing = false
                        voice.stopListening()
                    })
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Hold to talk")
                .accessibilityAction { listening ? voice.stopListening() : voice.startListening() }
            if voice.state.isActive {
                Button { voice.cancel() } label: { Label("Cancel", systemImage: "xmark") }.buttonStyle(MBButtonStyle(.ghost, compact: true))
            }
            if listening { LevelMeter(level: voice.level) }
        }
    }
}

struct ApprovalCard: View {
    let title: String
    let risk: IntentRisk
    let approve: () -> Void
    let deny: () -> Void

    var body: some View {
        HStack(spacing: MBSpace.m) {
            Image(systemName: "hand.raised.fill").foregroundStyle(risk == .high ? MBColor.danger : MBColor.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                Text("\(risk.rawValue.capitalized) risk · needs your approval on this Mac").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
            }
            Spacer()
            Button("Don’t", action: deny).buttonStyle(MBButtonStyle(.ghost, compact: true))
            Button("Allow", action: approve).buttonStyle(MBButtonStyle(.primary, compact: true))
        }
        .padding(MBSpace.m)
        .background(RoundedRectangle(cornerRadius: MBRadius.md).fill(MBColor.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: MBRadius.md).strokeBorder(MBColor.warning.opacity(0.3)))
        .frame(maxWidth: 560)
    }
}
