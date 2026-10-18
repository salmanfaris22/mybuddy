import MyBuddyCore
import MyBuddyDesign
import MyBuddyHost
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page {
            HeroPanel()
            AdaptiveColumns {
                RemotePreviewCard().layoutPriority(1)
                HealthSummaryCard()
            }
            AdaptiveColumns {
                ActivityCard()
                AIProviderCard()
            }
            QuickActions()
        }
        .task { if model.health.snapshot == nil { await model.health.refresh() } }
    }
}

/// Two columns that collapse to one when the window is narrow.
struct AdaptiveColumns<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: MBSpace.l) { content }
                .frame(minWidth: 720)
            VStack(alignment: .leading, spacing: MBSpace.l) { content }
        }
    }
}

struct HeroPanel: View {
    @Environment(AppModel.self) private var model

    var headline: String {
        if let s = model.connection.activeSession { return "\(s.deviceName) is connected to this Mac." }
        if model.connection.hasTrustedDevice { return "Your Mac is ready. Your phone isn’t connected right now." }
        return "Your Mac is ready. Pair your phone to begin."
    }

    var body: some View {
        let snapshot = model.health.snapshot
        Panel(padding: MBSpace.xl) {
            HStack(alignment: .center, spacing: MBSpace.xxl) {
                VStack(alignment: .leading, spacing: MBSpace.m) {
                    Eyebrow("This Mac")
                    Text(headline).font(MBFont.hero).foregroundStyle(MBColor.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle(snapshot)).font(MBFont.body).foregroundStyle(MBColor.textSecondary)
                    HStack(spacing: MBSpace.s) {
                        hostPill
                        if let device = model.connection.primaryDevice {
                            StatusPill(model.connection.activeSession != nil ? "\(device.name) · live" : "\(device.name) · paired",
                                       tone: model.connection.activeSession != nil ? .live : .neutral, symbol: "iphone")
                        }
                        StatusPill(model.ai.selectedProvider.isCloud ? "AI: \(model.ai.selectedProvider.displayName)" : "AI: local", tone: .info, symbol: "sparkles")
                    }
                    HStack(spacing: MBSpace.s) {
                        if !model.connection.hasTrustedDevice {
                            Button { model.connection.openPairing() } label: { Label("Pair a phone", systemImage: "qrcode") }
                                .buttonStyle(MBButtonStyle(.primary))
                        } else {
                            Button { model.selection = .remote } label: { Label("View desktop session", systemImage: "display") }
                                .buttonStyle(MBButtonStyle(.primary))
                        }
                        Button { model.selection = .ai } label: { Label("Ask MyBuddy", systemImage: "sparkles") }
                            .buttonStyle(MBButtonStyle(.secondary))
                    }
                    .padding(.top, MBSpace.xs)
                }
                Spacer(minLength: 0)
                BatteryRing(snapshot: snapshot)
            }
        }
    }

    private func subtitle(_ s: HealthSnapshot?) -> String {
        guard let s else { return "Collecting system information…" }
        return [s.system.chip.usableValue, s.system.osVersion.usableValue, s.system.uptimeSeconds.usableValue.map { "up \(HealthReport.duration($0))" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var hostPill: some View {
        switch model.connection.serverState {
        case .listening: StatusPill("Host listening", tone: .live, symbol: "dot.radiowaves.left.and.right")
        case .failed: StatusPill("Host error", tone: .danger, symbol: "exclamationmark")
        case .stopped: StatusPill(model.demoMode ? "Host listening" : "Host idle", tone: model.demoMode ? .live : .neutral, symbol: "dot.radiowaves.left.and.right")
        }
    }
}

struct BatteryRing: View {
    let snapshot: HealthSnapshot?

    var body: some View {
        let battery = snapshot?.battery
        let level = battery?.levelPercent.usableValue
        let charging = battery?.isCharging.usableValue == true
        let tone: MBTone = level.map { $0 <= 15 ? .danger : $0 <= 30 ? .warning : .live } ?? .neutral
        VStack(spacing: MBSpace.s) {
            ZStack {
                RingGauge(value: level.map { Double($0) / 100 }, tone: tone, lineWidth: 11)
                VStack(spacing: 0) {
                    if let level {
                        Text("\(level)%").font(MBFont.display).foregroundStyle(MBColor.textPrimary)
                        Label(charging ? "Charging" : (battery?.powerSource.usableValue ?? ""), systemImage: charging ? "bolt.fill" : "battery.75")
                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(MBColor.textSecondary).labelStyle(.titleAndIcon)
                    } else if snapshot == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("—").font(MBFont.display).foregroundStyle(MBColor.textTertiary)
                        Text("No battery data").font(.system(size: 10.5)).foregroundStyle(MBColor.textTertiary)
                    }
                }
            }
            .frame(width: 132, height: 132)
            if let condition = battery?.condition.usableValue {
                Text("Condition \(condition)" + (battery?.maximumCapacityPercent.usableValue.map { " · \($0)% max" } ?? ""))
                    .font(MBFont.callout).foregroundStyle(MBColor.textSecondary)
            }
            if let source = battery?.levelPercent.source { SourceCaption(source).frame(maxWidth: 170) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(level.map { "Battery \($0) percent\(charging ? ", charging" : "")" } ?? "Battery level unavailable")
    }
}

struct RemotePreviewCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: MBSpace.m) {
                SectionHeader("Remote session", subtitle: model.connection.activeSession.map { "Started \($0.startedAt.formatted(.relative(presentation: .named)))" } ?? "No phone is viewing this Mac") {
                    Button("Open") { model.selection = .remote }.buttonStyle(MBButtonStyle(.secondary, compact: true))
                }
                ZStack {
                    RoundedRectangle(cornerRadius: MBRadius.md, style: .continuous).fill(MBColor.base)
                    GridPattern().stroke(MBColor.border.opacity(0.5), lineWidth: 0.5).clipShape(RoundedRectangle(cornerRadius: MBRadius.md))
                    VStack(spacing: MBSpace.s) {
                        BrandMark(size: 40, live: model.connection.activeSession != nil)
                        Text(remoteLine).font(MBFont.callout).foregroundStyle(MBColor.textSecondary)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: MBRadius.md).strokeBorder(MBColor.border))
                .accessibilityLabel("Remote session: \(remoteLine)")
            }
        }
    }

    private var remoteLine: String {
        if let snap = model.screenShare.snapshot {
            return snap.status.phase == .live ? "Screen shared with \(snap.deviceName) — open to see the live picture" : "Starting a stream for \(snap.deviceName)…"
        }
        return model.connection.activeSession != nil ? "Phone connected · not viewing the screen" : "Not streaming"
    }
}

struct GridPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 22
        stride(from: rect.minX, through: rect.maxX, by: step).forEach { x in p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY)) }
        stride(from: rect.minY, through: rect.maxY, by: step).forEach { y in p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y)) }
        return p
    }
}

struct HealthSummaryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: MBSpace.m) {
                SectionHeader("Mac health", subtitle: model.health.snapshot.map { "Measured \($0.collectedAt.formatted(date: .omitted, time: .shortened))" }) {
                    Button("Details") { model.selection = .health }.buttonStyle(MBButtonStyle(.secondary, compact: true))
                }
                if let s = model.health.snapshot {
                    ForEach(HealthAssessment.findings(for: s).prefix(4)) { f in
                        HStack(spacing: MBSpace.s) {
                            Image(systemName: f.level == .ok ? "checkmark.circle.fill" : f.level == .critical ? "xmark.octagon.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(f.level == .ok ? MBColor.accent : f.level == .critical ? MBColor.danger : MBColor.warning)
                            Text(f.title).font(MBFont.body).foregroundStyle(MBColor.textPrimary)
                            Spacer()
                            Text(f.area).font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let root = s.rootVolume {
                        VStack(alignment: .leading, spacing: MBSpace.xs) {
                            HStack {
                                Text("Storage").font(MBFont.callout).foregroundStyle(MBColor.textSecondary)
                                Spacer()
                                Text("\(HealthReport.bytes(root.availableBytes)) free of \(HealthReport.bytes(root.totalBytes))").font(MBFont.callout.monospacedDigit()).foregroundStyle(MBColor.textSecondary)
                            }
                            UsageBar(fraction: 1 - root.freeFraction, tone: root.freeFraction < 0.15 ? .warning : .info)
                        }
                        .padding(.top, MBSpace.xs)
                    }
                } else {
                    VStack(spacing: MBSpace.s) { Skeleton(); Skeleton(); Skeleton(height: 8) }
                }
            }
        }
        .frame(minWidth: 300)
    }
}

struct ActivityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: MBSpace.s) {
                SectionHeader("Live activity") {
                    Button("See all") { model.selection = .activity }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                }
                if model.activity.events.isEmpty {
                    Text("Nothing yet. Pairing, sessions, transfers and voice commands will appear here — content is never recorded.")
                        .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                } else {
                    ForEach(model.activity.events.prefix(6)) { e in ActivityRow(event: e) }
                }
            }
        }
    }
}

struct ActivityRow: View {
    let event: ActivityEvent
    var body: some View {
        TimelineRow(symbol: Self.symbol(event.kind), tone: Self.tone(event.kind), title: event.title, detail: event.detail, date: event.date)
    }

    static func symbol(_ k: ActivityKind) -> String {
        switch k {
        case .session: "display"
        case .pairing: "qrcode"
        case .transfer: "arrow.down.doc"
        case .clipboard: "doc.on.clipboard"
        case .notification: "bell"
        case .ai: "sparkles"
        case .voice: "waveform"
        case .health: "heart.text.square"
        case .security: "lock.shield"
        }
    }

    static func tone(_ k: ActivityKind) -> MBTone {
        switch k {
        case .security: .warning
        case .session, .pairing: .live
        default: .info
        }
    }
}

struct AIProviderCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.ai.selectedProvider
        Panel {
            VStack(alignment: .leading, spacing: MBSpace.m) {
                SectionHeader("Assistant", subtitle: "Chat model used by MyBuddy and your phone") {
                    Button("Studio") { model.selection = .ai }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                }
                HStack(spacing: MBSpace.m) {
                    Image(systemName: p.isCloud ? "cloud" : "desktopcomputer")
                        .font(.system(size: 16)).foregroundStyle(MBColor.info)
                        .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: MBRadius.md).fill(MBColor.info.opacity(0.1)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.displayName).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                        Text(p.selectedModel ?? "No model selected").font(MBFont.mono).foregroundStyle(MBColor.textSecondary)
                    }
                    Spacer()
                }
                Label(p.privacyLabel, systemImage: p.isCloud ? "arrow.up.forward.circle" : "lock.circle")
                    .font(MBFont.callout).foregroundStyle(p.isCloud ? MBColor.warning : MBColor.accent)
                HStack {
                    Button {
                        Task { await model.ai.testConnection() }
                    } label: { Label(model.ai.isTesting ? "Testing…" : "Test connection", systemImage: "bolt.horizontal") }
                        .buttonStyle(MBButtonStyle(.secondary, compact: true))
                        .disabled(model.ai.isTesting || model.demoMode)
                    if let r = model.ai.testResult ?? p.lastTest {
                        Text(r.message).font(MBFont.callout).foregroundStyle(r.outcome == .ok ? MBColor.accent : MBColor.danger).lineLimit(2)
                    }
                }
            }
        }
    }
}

struct QuickActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: MBSpace.s) {
            Eyebrow("Quick actions")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: MBSpace.s)], spacing: MBSpace.s) {
                action("Connect phone", "qrcode") { model.connection.openPairing() }
                action("App & device access", "square.grid.3x3") { model.selection = .settings }
                action("Share a folder", "folder.badge.plus") { model.selection = .files }
                action("Clipboard", "doc.on.clipboard") { model.selection = .files }
                action("Ask MyBuddy", "waveform") { model.selection = .voice }
                action("Health report", "doc.text.magnifyingglass") { model.selection = .health }
            }
        }
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: MBSpace.s) {
                Image(systemName: symbol).foregroundStyle(MBColor.accent).frame(width: 18)
                Text(title).foregroundStyle(MBColor.textPrimary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MBButtonStyle(.secondary))
    }
}
