import MyBuddyCore
import MyBuddyDesign
import MyBuddyHost
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page {
            DevicesSettings()
            ProvidersSettings()
            AdaptiveColumns {
                PrivacySettings()
                ThisMacSettings()
            }
            ConnectionsSettings()
        }
    }
}

/// How the phone reaches this Mac: same Wi-Fi, Tailscale, or the internet through your MyBuddy Connect server.
struct ConnectionsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let connection = model.connection
        Panel {
            VStack(alignment: .leading, spacing: MBSpace.m) {
                SectionHeader("Connections", subtitle: "Every route is end-to-end encrypted and only works for phones you paired and approved.")
                ConnectionRouteRow(symbol: "wifi", title: "Same network (Wi-Fi)", status: lanStatus, tone: lanTone,
                                   detail: "Phone and Mac on the same Wi-Fi. No account or server.")
                ConnectionRouteRow(symbol: "point.3.connected.trianglepath.dotted", title: "Tailscale", status: tailscaleStatus, tone: tailscaleTone,
                                   detail: "Connect from anywhere through your own tailnet. Needs the Tailscale app on this Mac and on your phone, signed in to the same tailnet.") {
                    switch connection.tailscale.state {
                    case .notInstalled:
                        Button("Get Tailscale") { NSWorkspace.shared.open(TailscaleStatus.downloadURL) }.buttonStyle(MBButtonStyle(.secondary, compact: true))
                    case .installedNotConnected:
                        if let url = connection.tailscale.appURL {
                            Button("Open Tailscale") { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
                                .buttonStyle(MBButtonStyle(.secondary, compact: true))
                        }
                    case .connected:
                        EmptyView()
                    }
                }
                Toggle("Allow connections over Tailscale", isOn: Binding(get: { model.settings.allowTailscale }, set: { connection.setAllowTailscale($0) }))
                    .toggleStyle(.switch).font(MBFont.body).padding(.leading, 34)
                Text(model.settings.allowTailscale
                     ? "The pairing code includes this Mac’s Tailscale address, and paired phones may connect through the tailnet. Being on the tailnet grants nothing by itself."
                     : "Off: the pairing code leaves out the Tailscale address and connections from tailnet addresses (100.64.0.0/10) are refused. A Wi-Fi network that uses that range would be refused too.")
                    .font(MBFont.callout).foregroundStyle(MBColor.textTertiary).fixedSize(horizontal: false, vertical: true).padding(.leading, 34)
                InternetConnectionRow()
            }
        }
        .onAppear { connection.refreshTailscale() }
    }

    private var lanStatus: String {
        if let s = model.connection.activeSession, s.route == .localNetwork { return "Connected · \(s.deviceName)" }
        switch model.connection.serverState {
        case .listening(let port):
            let address = SystemHealthCollector.lanIPv4Addresses().first.map { "\($0):\(port)" } ?? "port \(port)"
            return "Listening on \(address)"
        case .failed: return "Error"
        case .stopped: return model.demoMode ? "Listening on 192.168.1.20:47811" : "Not listening"
        }
    }

    private var lanTone: MBTone {
        if case .listening = model.connection.serverState { return .live }
        return model.demoMode ? .live : .neutral
    }

    private var tailscaleStatus: String {
        guard model.settings.allowTailscale else { return "Off in Settings" }
        switch model.connection.tailscale.state {
        case .connected(let i):
            if let s = model.connection.activeSession, s.viaTailnet { return "Connected · \(s.deviceName) via \(i.ipv4)" }
            return "Ready · \(i.ipv4)" + (i.confirmed ? "" : " (unconfirmed)")
        case .installedNotConnected: return "Installed, not connected"
        case .notInstalled: return "Not installed"
        }
    }

    private var tailscaleTone: MBTone {
        guard model.settings.allowTailscale else { return .neutral }
        switch model.connection.tailscale.state {
        case .connected: return .live
        case .installedNotConnected: return .warning
        case .notInstalled: return .neutral
        }
    }
}

/// Internet access through the user's own MyBuddy Connect server (CONNECTIVITY §3).
struct InternetConnectionRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var internet = model.internet
        VStack(alignment: .leading, spacing: MBSpace.s) {
            ConnectionRouteRow(symbol: "globe", title: "Internet (MyBuddy Connect)", status: status, tone: tone,
                               detail: "Away from home without Tailscale, through a server you run. It only introduces your phone to this Mac and, if a direct path isn’t possible, relays encrypted packets (TURN). File transfer stays off on relayed connections.")
            HStack(spacing: MBSpace.s) {
                TextField("https://connect.example.com", text: $internet.serverInput)
                    .textFieldStyle(.roundedBorder).font(MBFont.body.monospaced())
                    .disabled(internet.isOn || model.demoMode)
                    .frame(maxWidth: 360)
                if internet.isOn {
                    Button("Turn Off") { internet.turnOff() }.buttonStyle(MBButtonStyle(.secondary, compact: true))
                } else {
                    Button("Turn On") { Task { await internet.turnOn() } }.buttonStyle(MBButtonStyle(.primary, compact: true))
                        .disabled(internet.serverInput.isEmpty || model.demoMode)
                }
            }
            .padding(.leading, 34)
            if case .failed(let why) = internet.status {
                Text(why).font(MBFont.callout).foregroundStyle(MBColor.danger).padding(.leading, 34)
            } else if case .offline(let why) = internet.status {
                Text("Can’t reach the server right now (\(why)). Retrying; Wi-Fi and Tailscale keep working.").font(MBFont.callout)
                    .foregroundStyle(MBColor.warning).padding(.leading, 34)
            }
            if internet.isOn {
                ForEach(model.connection.trustedDevices.filter(\.isActive)) { device in
                    HStack(spacing: MBSpace.s) {
                        Image(systemName: "iphone").foregroundStyle(MBColor.textSecondary).frame(width: 18)
                        Text(device.name).font(MBFont.body).foregroundStyle(MBColor.textPrimary)
                        StatusPill(enrolment(device), tone: internet.isEnrolled(device.id) ? .live : .neutral)
                        Spacer()
                        if internet.isEnrolled(device.id) {
                            Button("Remove Internet Access") { internet.removeAccess(for: device.id) }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                        }
                    }
                    .padding(.leading, 34)
                }
                Text("A phone is offered internet access the next time it connects over Wi-Fi or Tailscale, and must agree on the phone.")
                    .font(MBFont.callout).foregroundStyle(MBColor.textTertiary).padding(.leading, 34)
            }
        }
    }

    private func enrolment(_ device: TrustedDevice) -> String {
        if model.internet.isEnrolled(device.id) { return "Internet access on" }
        if model.internet.offered[device.id] != nil { return "Offered — waiting for the phone" }
        return "Not offered yet"
    }

    private var status: String {
        let internet = model.internet
        if let s = model.connection.activeSession, s.route == .internetDirect || s.route == .internetRelayed {
            return "Connected · \(s.deviceName)\(s.route == .internetRelayed ? " (relayed)" : "")"
        }
        switch internet.status {
        case .off: return "Off"
        case .signingIn: return "Signing in…"
        case .online: return "Online · \(internet.serverLabel)"
        case .offline: return "Reconnecting…"
        case .failed: return "Error"
        }
    }

    private var tone: MBTone {
        switch model.internet.status {
        case .off: .neutral
        case .signingIn, .offline: .warning
        case .online: .live
        case .failed: .danger
        }
    }
}

struct ConnectionRouteRow<Action: View>: View {
    let symbol: String
    let title: String
    let status: String
    let tone: MBTone
    let detail: String
    @ViewBuilder var action: () -> Action

    init(symbol: String, title: String, status: String, tone: MBTone, detail: String, @ViewBuilder action: @escaping () -> Action = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.status = status
        self.tone = tone
        self.detail = detail
        self.action = action
    }

    var body: some View {
        HStack(alignment: .top, spacing: MBSpace.m) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(tone == .neutral ? MBColor.textSecondary : tone.color)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: MBSpace.s) {
                    Text(title).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                    StatusPill(status, tone: tone)
                }
                Text(detail).font(MBFont.callout).foregroundStyle(MBColor.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: MBSpace.s)
            action()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(status)")
    }
}

struct DevicesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRevoke: TrustedDevice?

    var body: some View {
        let connection = model.connection
        Panel {
            VStack(alignment: .leading, spacing: MBSpace.m) {
                SectionHeader("Devices & permissions", subtitle: "Each permission is separate. Removing one ends the current session.") {
                    Button { connection.openPairing() } label: { Label("Pair a phone", systemImage: "qrcode") }.buttonStyle(MBButtonStyle(.primary, compact: true))
                }
                if connection.trustedDevices.isEmpty {
                    StateView(.empty, title: "No phones paired", message: "Pairing needs your phone on the same Wi-Fi, a QR scan, and your approval here with a matching 6-digit code.")
                }
                ForEach(connection.trustedDevices) { device in
                    VStack(alignment: .leading, spacing: MBSpace.s) {
                        HStack(spacing: MBSpace.m) {
                            Image(systemName: "iphone").font(.system(size: 18)).foregroundStyle(device.isActive ? MBColor.accent : MBColor.textTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                                Text("ID \(device.id.prefix(8))… · paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))\(device.lastSeenAt.map { " · seen \($0.formatted(.relative(presentation: .named)))" } ?? "")")
                                    .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                            }
                            Spacer()
                            if device.isActive {
                                Button("Revoke") { confirmRevoke = device }.buttonStyle(MBButtonStyle(.danger, compact: true))
                            } else {
                                StatusPill("Revoked", tone: .danger)
                                Button("Forget") { connection.forget(device) }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                            }
                        }
                        if device.isActive {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .leading)], alignment: .leading, spacing: MBSpace.xs) {
                                ForEach(Capability.allCases.filter { $0 != .unattended }, id: \.self) { cap in
                                    Toggle(isOn: Binding(get: { device.grant.allows(cap) }, set: { connection.setCapability(cap, enabled: $0, for: device) })) {
                                        HStack(spacing: MBSpace.xs) {
                                            Text(cap.title).font(MBFont.body)
                                            if cap.isSensitive { Image(systemName: "exclamationmark.shield").font(.system(size: 10)).foregroundStyle(MBColor.warning) }
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .disabled(model.demoMode)
                                }
                            }
                            Text("Unattended access is not available in this version.").font(.system(size: 10.5)).foregroundStyle(MBColor.textTertiary)
                        }
                    }
                    .padding(MBSpace.m)
                    .background(RoundedRectangle(cornerRadius: MBRadius.md).fill(MBColor.base.opacity(0.6)))
                }
            }
        }
        .confirmationDialog("Revoke \(confirmRevoke?.name ?? "this phone")?", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } })) {
            Button("Revoke", role: .destructive) { if let d = confirmRevoke { connection.revoke(d) } }
        } message: { Text("Its session ends now and it can’t connect again until you pair it again.") }
    }
}

struct ProvidersSettings: View {
    @Environment(AppModel.self) private var model
    @State private var keyDrafts: [String: String] = [:]

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: MBSpace.m) {
                SectionHeader("AI providers", subtitle: "Keys are stored in the macOS Keychain and used only on this Mac — never sent to your phone")
                ForEach(model.settings.providers) { p in providerRow(p) }
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ p: ProviderConfig) -> some View {
        let index = model.settings.providers.firstIndex { $0.id == p.id }!
        VStack(alignment: .leading, spacing: MBSpace.s) {
            HStack {
                Text(p.displayName).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                if p.id == model.settings.selectedProviderId { StatusPill("Active", tone: .live) }
                Spacer()
                Text(p.privacyLabel).font(MBFont.callout).foregroundStyle(p.isCloud ? MBColor.warning : MBColor.accent)
            }
            Text(p.kind.authDescription).font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
            if p.kind == .ollama || p.kind == .openAICompatible {
                HStack {
                    Text("Endpoint").font(MBFont.callout).foregroundStyle(MBColor.textSecondary).frame(width: 70, alignment: .leading)
                    TextField("http://127.0.0.1:11434", text: Binding(
                        get: { p.endpoint.absoluteString },
                        set: { if let url = URL(string: $0), url.host != nil { model.settings.providers[index].endpoint = url } }))
                        .textFieldStyle(.roundedBorder).font(MBFont.mono)
                    Picker("", selection: Binding(get: { p.trust }, set: { model.settings.providers[index].trust = $0 })) {
                        Text("This Mac only").tag(EndpointTrust.standard)
                        Text("Trust local network").tag(EndpointTrust.userTrustedLocalNetwork)
                        Text("Trust remote HTTPS").tag(EndpointTrust.userTrustedRemote)
                    }
                    .labelsHidden().frame(width: 170)
                }
                if let problem = endpointProblem(p) { Text(problem).font(MBFont.callout).foregroundStyle(MBColor.warning) }
            }
            if p.secret != nil {
                HStack {
                    SecureField(model.ai.hasKey(p) ? "Key saved in Keychain — paste to replace" : "Paste API key", text: Binding(
                        get: { keyDrafts[p.id] ?? "" }, set: { keyDrafts[p.id] = $0 }))
                        .textFieldStyle(.roundedBorder).font(MBFont.mono)
                    Button("Save") { model.ai.setKey(keyDrafts[p.id] ?? "", for: p); keyDrafts[p.id] = "" }
                        .buttonStyle(MBButtonStyle(.secondary, compact: true)).disabled((keyDrafts[p.id] ?? "").isEmpty || model.demoMode)
                    if model.ai.hasKey(p) {
                        Button("Remove") { model.ai.setKey("", for: p) }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                    }
                }
            }
            if p.kind == .anthropic {
                Toggle("Server-side refusal fallback on supported models (beta: fallbacks “default”)", isOn: Binding(
                    get: { p.options.anthropicRefusalFallback }, set: { model.settings.providers[index].options.anthropicRefusalFallback = $0 }))
                    .font(MBFont.callout)
                Toggle("Show reasoning summaries when the model supports them", isOn: Binding(
                    get: { p.options.showReasoningSummaries }, set: { model.settings.providers[index].options.showReasoningSummaries = $0 }))
                    .font(MBFont.callout)
            }
            HStack {
                Button("Use this provider") { model.ai.selectProvider(p.id) }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                    .disabled(p.id == model.settings.selectedProviderId)
            }
        }
        .padding(MBSpace.m)
        .background(RoundedRectangle(cornerRadius: MBRadius.md).fill(MBColor.base.opacity(0.6)))
    }

    private func endpointProblem(_ p: ProviderConfig) -> String? {
        do {
            try EndpointValidator.validate(p.endpoint, kind: p.kind, trust: p.trust)
            return nil
        } catch {
            return error.userMessage
        }
    }
}

struct PrivacySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: MBSpace.m) {
                SectionHeader("Privacy")
                Toggle(isOn: Binding(get: { model.settings.localOnly }, set: { model.settings.localOnly = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Only").font(MBFont.bodyEmphasis)
                        Text("Blocks cloud AI providers before any request is made. Only a model server on this Mac (e.g. Ollama on 127.0.0.1) can be used.")
                            .font(MBFont.callout).foregroundStyle(MBColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                Picker("Keep activity history", selection: Binding(get: { model.settings.activityRetentionDays }, set: {
                    model.settings.activityRetentionDays = $0
                    model.activityLog.retention = TimeInterval($0) * 86_400
                })) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                MetricRow("Telemetry", value: "None")
                MetricRow("Crash reporting", value: "None")
                Text("Screen frames, audio, clipboard text, files, notifications, transcripts and AI conversations are never stored on a server.")
                    .font(MBFont.callout).foregroundStyle(MBColor.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ThisMacSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("This Mac").padding(.bottom, MBSpace.s)
                if let identity = model.identity {
                    MetricRow("Device ID", value: String(identity.deviceId.prefix(16)) + "…")
                    MetricRow("Key fingerprint", value: String(identity.fingerprint.prefix(12)) + "…")
                    MetricRow("Private key", value: model.identityBackend?.rawValue ?? "—", tone: model.identityBackend == .secureEnclave ? .live : .neutral)
                } else {
                    Text(model.identityError ?? "Identity unavailable").font(MBFont.callout).foregroundStyle(MBColor.danger)
                }
                switch model.connection.serverState {
                case .listening(let port): MetricRow("Local network", value: "Listening on port \(port)", tone: .live)
                case .failed(let why): MetricRow("Local network", value: "Error", note: why, tone: .danger)
                case .stopped: MetricRow("Local network", value: model.demoMode ? "Listening on port 47811" : "Not listening", note: model.demoMode ? nil : "Starts when you pair or have a paired phone")
                }
                Toggle("Accept connections from paired phones", isOn: Binding(get: { model.settings.acceptConnections }, set: {
                    model.settings.acceptConnections = $0
                    if $0 { model.connection.startIfNeeded() } else { model.connection.stopServer() }
                }))
                .toggleStyle(.switch).font(MBFont.body).padding(.top, MBSpace.s)
                Toggle(isOn: Binding(get: { model.settings.keepAwakeWhileConnected }, set: { model.settings.keepAwakeWhileConnected = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stay Awake: keep this Mac awake while a phone is connected").font(MBFont.body)
                        Text("The screen and Mac won’t idle-sleep, so your phone keeps a live picture. Closing the lid still sleeps a MacBook unless an external display and power are connected (clamshell mode).")
                            .font(MBFont.callout).foregroundStyle(MBColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch).padding(.top, MBSpace.s)
            }
        }
    }
}

// MARK: - Pairing sheet

struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let connection = model.connection
        VStack(spacing: MBSpace.l) {
            if let request = connection.pendingApproval {
                approval(request)
            } else if let invitation = connection.invitation {
                qr(invitation)
            } else {
                ProgressView("Preparing a pairing code…").controlSize(.small).padding(MBSpace.xxl)
            }
        }
        .padding(MBSpace.xl)
        .frame(width: 520)
        .background(MBColor.surface)
    }

    private func qr(_ invitation: PairingInvitation) -> some View {
        VStack(spacing: MBSpace.l) {
            HStack {
                BrandMark(size: 26, live: true)
                Text("Pair your phone").font(MBFont.title).foregroundStyle(MBColor.textPrimary)
                Spacer()
            }
            Text("Open MyBuddy on your phone, tap Pair, and scan this code. Both screens will then show the same 6-digit number.")
                .font(MBFont.body).foregroundStyle(MBColor.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let cg = QRCodeRenderer.image(for: invitation.url.absoluteString) {
                    Image(decorative: cg, scale: 1).interpolation(.none).resizable().frame(width: 240, height: 240)
                        .padding(MBSpace.m).background(RoundedRectangle(cornerRadius: MBRadius.lg).fill(Color.white))
                        .accessibilityLabel("Pairing QR code")
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let remaining = max(0, Int(invitation.expiresAt.timeIntervalSince(ctx.date)))
                Text(remaining > 0 ? "Single-use code · expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))" : "Code expired")
                    .font(MBFont.callout.monospacedDigit()).foregroundStyle(remaining > 20 ? MBColor.textSecondary : MBColor.warning)
            }
            Text(invitation.addresses.joined(separator: "  ·  ")).font(MBFont.mono).foregroundStyle(MBColor.textTertiary)
            HStack {
                Spacer()
                Button("New code") { model.connection.openPairing() }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                Button("Done") { model.connection.closePairing() }.buttonStyle(MBButtonStyle(.secondary, compact: true))
            }
        }
    }

    private func approval(_ r: PairingApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: MBSpace.l) {
            HStack(spacing: MBSpace.m) {
                Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 22)).foregroundStyle(MBColor.accent)
                    .frame(width: 46, height: 46).background(Circle().fill(MBColor.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow “\(r.deviceName)” to pair?").font(MBFont.title).foregroundStyle(MBColor.textPrimary)
                    Text("\(r.platform.capitalized) · MyBuddy \(r.appVersion) · from \(r.remoteAddress)").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                }
            }
            VStack(alignment: .leading, spacing: MBSpace.s) {
                Eyebrow("Check that your phone shows")
                Text(r.verificationCode.prefix(3) + " " + r.verificationCode.suffix(3))
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(MBColor.textPrimary)
                    .accessibilityLabel("Verification code \(r.verificationCode.map(String.init).joined(separator: " "))")
                Text("If the numbers don’t match, decline — someone else may be trying to pair.").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
            }
            .padding(MBSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: MBRadius.lg).fill(MBColor.elevated))
            VStack(alignment: .leading, spacing: MBSpace.xs) {
                Eyebrow("It will be allowed to")
                ForEach(Capability.defaultGrants.sorted { $0.title < $1.title }, id: \.self) { c in
                    Label(c.title, systemImage: "checkmark").font(MBFont.callout).foregroundStyle(MBColor.textSecondary)
                }
                Text("Control, files, app launching and coding agents stay off until you enable them in Settings.")
                    .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
            }
            HStack {
                Button("Decline") { model.connection.decline() }.buttonStyle(MBButtonStyle(.danger))
                Spacer()
                Button("Approve") { model.connection.approve() }.buttonStyle(MBButtonStyle(.primary)).keyboardShortcut(.defaultAction)
            }
        }
    }
}
