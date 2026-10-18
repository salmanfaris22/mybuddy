import MyBuddyCore
import MyBuddyDesign
import MyBuddyHost
import MyBuddyMedia
import SwiftUI

struct RemoteDesktopView: View {
    @Environment(AppModel.self) private var model
    @State private var accessibility: PermissionState = .notDetermined

    var body: some View {
        let share = model.screenShare
        Page {
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    StreamStage()
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: MBRadius.lg, topTrailingRadius: MBRadius.lg))
                    Rectangle().fill(MBColor.border).frame(height: 1)
                    DiagnosticsStrip()
                }
            }

            AdaptiveColumns {
                Panel {
                    VStack(alignment: .leading, spacing: MBSpace.m) {
                        SectionHeader("Permissions on this Mac", subtitle: "Checked live; MyBuddy never bypasses these prompts")
                        PermissionRow(title: "Screen Recording", detail: "Lets a paired phone with “View screen” see the display it asks for.", state: share.permission) {
                            share.requestPermission()
                        }
                        PermissionRow(title: "Accessibility", detail: "Lets a phone with “Control” permission move the pointer and type.", state: accessibility) {
                            SystemPermissions.requestAccessibility()
                        }
                        if share.permission != .granted {
                            Text("Without Screen Recording, a phone that asks to view is told to allow it here. You can also choose a single window or display with the macOS picker below.")
                                .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                        }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: MBSpace.m) {
                        SectionHeader("Session controls")
                        if let s = model.connection.activeSession {
                            MetricRow("Device", value: s.deviceName)
                            MetricRow("Permissions", value: s.grantedCapabilities.map(\.title).sorted().joined(separator: ", "))
                            MetricRow("Remote input", value: s.grantedCapabilities.contains(.inputControl) ? (accessibility == .granted ? "Allowed" : "Allowed, needs Accessibility") : "Not allowed")
                        } else {
                            Text("No active session.").font(MBFont.body).foregroundStyle(MBColor.textTertiary)
                        }
                        if let snap = share.snapshot {
                            MetricRow("Screen", value: snap.status.phase == .live ? "Shared with \(snap.deviceName)" : "Starting for \(snap.deviceName)…", tone: .live)
                            MetricRow("Quality", value: qualityLine(snap.status))
                            Button { share.stop() } label: { Label("Stop Sharing", systemImage: "rectangle.on.rectangle.slash").frame(maxWidth: .infinity) }
                                .buttonStyle(MBButtonStyle(.secondary))
                        }
                        HStack(spacing: MBSpace.s) {
                            Button { share.chooseContent() } label: { Label("Choose What to Share…", systemImage: "macwindow.on.rectangle") }
                                .buttonStyle(MBButtonStyle(.secondary, compact: true))
                                .disabled(model.demoMode)
                                .help("Opens the macOS picker to share one window, app or display instead of the display the phone asked for")
                            if let picked = share.pickedContentDescription {
                                Chip("\(picked) selected", symbol: "checkmark")
                                Button("Clear") { share.clearPickedContent() }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                            }
                        }
                        Button(role: .destructive) { model.emergencyStop() } label: {
                            Label("Emergency Stop", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(MBButtonStyle(.danger))
                        .keyboardShortcut(".", modifiers: [.command, .shift])
                        .help("Ends every session, stops screen sharing, releases held keys and disables remote input immediately")
                    }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func qualityLine(_ s: ScreenStreamStatus) -> String {
        var parts = [s.quality == .auto ? "Auto (\(s.tier?.rawValue ?? "balanced"))" : (s.quality?.rawValue.capitalized ?? "Auto")]
        if let d = s.dimensions { parts.append(d.description) }
        if let fps = s.fps { parts.append("\(fps) fps max") }
        return parts.joined(separator: " · ")
    }

    private func refresh() {
        model.screenShare.refreshPermission()
        accessibility = model.demoMode ? .notDetermined : SystemPermissions.accessibility
    }
}

/// The big canvas: the outgoing stream exactly as the phone receives it, or an honest idle state.
/// Nothing here is ever a placeholder picture.
struct StreamStage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let share = model.screenShare
        let snap = share.snapshot
        let aspect = snap?.status.dimensions.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 16 / 10
        ZStack {
            Rectangle().fill(MBColor.base)
            if let snap, snap.status.phase == .live {
                StreamPreview(controller: share.controller)
                    .accessibilityLabel("Live preview of what \(snap.deviceName) sees")
            } else {
                GridPattern().stroke(MBColor.border.opacity(0.45), lineWidth: 0.5)
                VStack(spacing: MBSpace.m) {
                    BrandMark(size: 56, live: model.connection.activeSession != nil)
                    Text(title).font(MBFont.title).foregroundStyle(MBColor.textPrimary)
                    Text(message).font(MBFont.body).foregroundStyle(MBColor.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                    if snap != nil { ProgressView().controlSize(.small) }
                    if !model.connection.hasTrustedDevice {
                        Button { model.connection.openPairing() } label: { Label("Pair a phone", systemImage: "qrcode") }
                            .buttonStyle(MBButtonStyle(.primary))
                    }
                }
                .padding(MBSpace.xl)
            }
            if let snap {
                VStack {
                    HStack {
                        StatusPill(snap.status.phase == .live ? "Live · \(snap.deviceName) is viewing" : "Starting…", tone: .live, symbol: "record.circle",
                                   pulsing: snap.status.phase == .live)
                        Spacer()
                        Button { share.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(MBButtonStyle(.danger, compact: true))
                    }
                    Spacer()
                }
                .padding(MBSpace.m)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .animation(MBMotion.standard, value: snap?.status.phase)
    }

    private var title: String {
        if let snap = model.screenShare.snapshot { return "Starting the stream for \(snap.deviceName)…" }
        if let s = model.connection.activeSession { return "\(s.deviceName) is connected" }
        return "No phone is viewing this Mac"
    }

    private var message: String {
        if model.screenShare.snapshot != nil { return "Capturing the screen and negotiating an encrypted video connection." }
        guard let s = model.connection.activeSession else {
            return "When a paired phone starts viewing from its Remote tab, the exact picture it receives appears here."
        }
        if !s.grantedCapabilities.contains(.screenView) {
            return "“View screen” is off for this phone. Turn it on in Settings → Devices to let it watch."
        }
        return "It can start viewing from its Remote tab. You’ll see exactly what it sees, and you can stop it here at any time."
    }
}

/// Hosts the libwebrtc renderer attached to the outgoing track.
struct StreamPreview: NSViewRepresentable {
    let controller: ScreenShareController

    func makeCoordinator() -> ScreenShareController { controller }

    func makeNSView(context: Context) -> NSView { controller.makePreviewView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ScreenShareController) {
        coordinator.releasePreviewView(nsView)
    }
}

struct DiagnosticsStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.screenShare.snapshot?.stats
        let live = model.screenShare.isLive
        HStack(spacing: MBSpace.xl) {
            stat("Path", path(stats))
            stat("Encryption", live ? "MBH1 + DTLS-SRTP" : model.connection.activeSession != nil ? "MBH1 · AES-256-GCM" : "—")
            stat("Latency", stats?.roundTripMs.map { String(format: "%.0f ms RTT", $0) }
                 ?? model.connection.activeRoundTripMs.map { "\($0) ms ping" } ?? "not measured")
            stat("Video", video(stats, live: live))
            Spacer()
            StatusPill(live ? "Sharing screen" : model.connection.statusTitle,
                       tone: model.connection.activeSession != nil ? .live : .neutral)
        }
        .padding(.horizontal, MBSpace.l)
        .padding(.vertical, MBSpace.m)
    }

    private func path(_ stats: StreamStatsSample?) -> String {
        guard let session = model.connection.activeSession else { return "—" }
        if session.viaTailnet { return stats?.path == .relayed ? "Tailscale · TURN relay" : "Tailscale" }
        if session.route == .internetDirect || session.route == .internetRelayed {
            return stats?.path == .relayed ? "Internet · TURN relay" : "Internet · direct"
        }
        switch stats?.path {
        case .direct?: return "Direct (\(stats?.localCandidateType ?? "host"))"
        case .relayed?: return "Relayed (TURN)"
        default: return "LAN · direct"
        }
    }

    private func video(_ stats: StreamStatsSample?, live: Bool) -> String {
        guard live, let s = stats else { return "not streaming" }
        var parts: [String] = []
        if let d = s.dimensions { parts.append(d.description) }
        if let f = s.framesPerSecond { parts.append(String(format: "%.0f fps", f)) }
        if let c = s.codec { parts.append(c + (s.hardwareAccelerated == true ? " (hardware)" : "")) }
        if let b = s.bitrateKbps { parts.append(b >= 1000 ? String(format: "%.1f Mbps", b / 1000) : String(format: "%.0f kbps", b)) }
        return parts.isEmpty ? "measuring…" : parts.joined(separator: " · ")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(label)
            Text(value).font(MBFont.callout.monospacedDigit()).foregroundStyle(MBColor.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let state: PermissionState
    let request: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: MBSpace.m) {
            Image(systemName: state == .granted ? "checkmark.seal.fill" : "lock.shield")
                .foregroundStyle(state == .granted ? MBColor.accent : MBColor.warning)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                Text(detail).font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
            }
            Spacer()
            if state == .granted {
                Text(state.title).font(MBFont.callout).foregroundStyle(MBColor.accent)
            } else {
                Button("Allow…", action: request).buttonStyle(MBButtonStyle(.secondary, compact: true))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(state.title)")
    }
}
