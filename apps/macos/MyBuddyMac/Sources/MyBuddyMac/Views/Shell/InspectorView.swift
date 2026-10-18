import MyBuddyCore
import MyBuddyDesign
import MyBuddyHost
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let section: AppSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MBSpace.l) {
                switch section {
                case .ai: providerDetails
                case .health: healthLegend
                case .voice: voiceDetails
                default: sessionDetails
                }
            }
            .padding(MBSpace.l)
        }
        .scrollIndicators(.never)
        .background(MBColor.surface.ignoresSafeArea())
    }

    private var sessionDetails: some View {
        VStack(alignment: .leading, spacing: MBSpace.m) {
            Eyebrow("Session")
            if let s = model.connection.activeSession {
                InspectorRow("Device", s.deviceName)
                InspectorRow("Platform", s.platform.capitalized)
                InspectorRow("Since", s.startedAt.formatted(date: .omitted, time: .shortened))
                InspectorRow("Address", s.remoteAddress)
                InspectorRow("Route", s.route == .tailscale ? "Tailscale (WireGuard)" : s.route.title)
                InspectorRow("Ping", model.connection.activeRoundTripMs.map { "\($0) ms" } ?? "measuring…")
                InspectorRow("Stay Awake", model.isStayingAwake ? "On while connected" : "Off")
                InspectorRow("Channel", "MBH1 · AES-256-GCM")
                Eyebrow("Granted")
                ForEach(s.grantedCapabilities.sorted { $0.title < $1.title }, id: \.self) { c in
                    Label(c.title, systemImage: "checkmark.circle.fill").font(MBFont.callout).foregroundStyle(MBColor.textSecondary)
                }
            } else {
                Text("No active session").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
            }
            Divider().overlay(MBColor.border)
            Eyebrow("This Mac")
            InspectorRow("Name", model.hostName)
            if let identity = model.identity {
                InspectorRow("Device ID", String(identity.deviceId.prefix(12)) + "…")
                InspectorRow("Key", model.identityBackend?.rawValue ?? "—")
            }
            InspectorRow("Trusted phones", "\(model.connection.trustedDevices.filter(\.isActive).count)")
            InspectorRow("Local Only", model.settings.localOnly ? "On" : "Off")
        }
    }

    private var providerDetails: some View {
        let p = model.ai.selectedProvider
        let model = p.models.first { $0.id == p.selectedModel }
        return VStack(alignment: .leading, spacing: MBSpace.m) {
            Eyebrow("Active provider")
            InspectorRow("Provider", p.displayName)
            InspectorRow("Type", p.kind == .ollama || p.kind == .openAICompatible ? "Local model server" : "Cloud API (your key)")
            InspectorRow("Endpoint", p.endpoint.host ?? p.endpoint.absoluteString)
            InspectorRow("Data goes to", p.privacyLabel)
            InspectorRow("Auth", p.kind.authDescription)
            if let m = model {
                Eyebrow("Model")
                InspectorRow("ID", m.id)
                if let c = m.contextWindow { InspectorRow("Context", "\(c.formatted()) tokens") }
                if let o = m.maxOutputTokens { InspectorRow("Max output", "\(o.formatted()) tokens") }
                if let v = m.supportsVision { InspectorRow("Images", v ? "Supported" : "No") }
                InspectorRow("Source", m.source)
            }
            Text("Switching providers starts a new conversation; history is not shared between providers.")
                .font(MBFont.callout).foregroundStyle(MBColor.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var healthLegend: some View {
        VStack(alignment: .leading, spacing: MBSpace.m) {
            Eyebrow("How to read this")
            legend("OS-reported", "Read directly from a macOS API (source shown under each value).", .live)
            legend("Derived", "Computed by MyBuddy from OS values; the formula is shown.", .info)
            legend("Estimate", "A best guess with the reason stated.", .warning)
            legend("Unavailable", "No supported API, or the system declined. Never filled in.", .neutral)
            Divider().overlay(MBColor.border)
            Text("Apple Silicon Macs expose no supported public API for CPU/GPU temperatures or fan speed, so MyBuddy shows the thermal state macOS reports instead.")
                .font(MBFont.callout).foregroundStyle(MBColor.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var voiceDetails: some View {
        VStack(alignment: .leading, spacing: MBSpace.m) {
            Eyebrow("What Voice can do")
            ForEach(["Show my Mac battery health", "Show my system health report", "Open Xcode on my Mac", "Open the Downloads folder",
                     "Pause clipboard sync", "Switch assistant to my local model"], id: \.self) {
                Text("“\($0)”").font(MBFont.callout).foregroundStyle(MBColor.textSecondary)
            }
            Divider().overlay(MBColor.border)
            Text("Anything destructive, financial or administrative is refused. Medium- and high-risk commands always ask on this Mac first.")
                .font(MBFont.callout).foregroundStyle(MBColor.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func legend(_ title: String, _ text: String, _ tone: MBTone) -> some View {
        HStack(alignment: .top, spacing: MBSpace.s) {
            Circle().fill(tone.color).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                Text(text).font(MBFont.callout).foregroundStyle(MBColor.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct InspectorRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(MBColor.textTertiary)
            Text(value).font(MBFont.callout).foregroundStyle(MBColor.textPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
