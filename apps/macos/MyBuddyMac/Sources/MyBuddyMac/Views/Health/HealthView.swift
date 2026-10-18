import Charts
import MyBuddyCore
import MyBuddyDesign
import MyBuddyHost
import SwiftUI

struct HealthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let health = model.health
        Page {
            HStack(spacing: MBSpace.m) {
                if let s = health.snapshot {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Measured \(s.collectedAt.formatted(date: .abbreviated, time: .standard))").font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                        Text("Collection took \(s.collectionDurationMs) ms · schema v\(s.schemaVersion) · stays on this Mac unless you export it")
                            .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                    }
                }
                Spacer()
                Button { Task { await health.refresh() } } label: { Label(health.isRefreshing ? "Measuring…" : "Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(MBButtonStyle(.secondary, compact: true)).disabled(health.isRefreshing || model.demoMode)
                Menu {
                    ForEach(HealthStore.ExportFormat.allCases, id: \.self) { f in Button("Export \(f.rawValue)…") { health.export(f) } }
                    Divider()
                    Toggle("Hide paths", isOn: Binding(get: { model.settings.redaction.hidePaths }, set: { model.settings.redaction.hidePaths = $0 }))
                    Toggle("Hide network addresses", isOn: Binding(get: { model.settings.redaction.hideNetworkAddresses }, set: { model.settings.redaction.hideNetworkAddresses = $0 }))
                    Toggle("Hide host name", isOn: Binding(get: { model.settings.redaction.hideHostName }, set: { model.settings.redaction.hideHostName = $0 }))
                    Toggle("Hide model identifier", isOn: Binding(get: { model.settings.redaction.hideModelIdentifier }, set: { model.settings.redaction.hideModelIdentifier = $0 }))
                } label: { Label("Export report", systemImage: "square.and.arrow.up") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(health.snapshot == nil)
            }
            if let msg = health.exportMessage { Text(msg).font(MBFont.callout).foregroundStyle(MBColor.accent) }

            switch health.state {
            case .idle, .loading:
                Panel { VStack(spacing: MBSpace.m) { Skeleton(height: 18); Skeleton(); Skeleton(); Skeleton(height: 8) } }
            case .loaded(let s):
                HealthContent(snapshot: s, history: health.history)
            case .failed(let m), .unavailable(let m), .notAuthorized(let m):
                StateView(.error, title: "Couldn’t measure this Mac", message: m)
            }
        }
        .task { if health.snapshot == nil { await health.refresh() } }
    }
}

struct HealthContent: View {
    let snapshot: HealthSnapshot
    let history: [HealthSnapshot]

    var body: some View {
        let s = snapshot
        let findings = HealthAssessment.findings(for: s)
        Panel {
            VStack(alignment: .leading, spacing: MBSpace.s) {
                SectionHeader("Summary", subtitle: "Explicit rules, no hidden score")
                ForEach(findings) { f in
                    HStack(alignment: .top, spacing: MBSpace.s) {
                        Circle().fill(color(f.level)).frame(width: 8, height: 8).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.title).font(MBFont.body).foregroundStyle(MBColor.textPrimary)
                            Text("Rule: \(f.rule)").font(.system(size: 10.5)).foregroundStyle(MBColor.textTertiary)
                        }
                        Spacer(minLength: MBSpace.s)
                        Text(f.area).font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                    }
                }
            }
        }

        AdaptiveColumns {
            Panel {
                VStack(alignment: .leading, spacing: MBSpace.s) {
                    SectionHeader("Battery")
                    HStack(alignment: .top, spacing: MBSpace.l) {
                        BatteryRing(snapshot: s)
                        VStack(spacing: 0) {
                            metric("Power source", s.battery.powerSource) { $0 }
                            metric(s.battery.timeRemainingKind == .toFull ? "Time to full" : "Time remaining", s.battery.timeRemainingMinutes) { HealthReport.minutes($0) }
                            metric("Condition", s.battery.condition) { $0 }
                            metric("Cycle count", s.battery.cycleCount) { "\($0)" }
                            metric("Maximum capacity", s.battery.maximumCapacityPercent) { "\($0)%" }
                        }
                    }
                    Text("Maximum capacity is macOS’s own figure, not derived from the charge level.").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: MBSpace.m) {
                    SectionHeader("Storage", subtitle: s.storage.source)
                    if let volumes = s.storage.usableValue {
                        ForEach(volumes) { v in
                            VStack(alignment: .leading, spacing: MBSpace.xs) {
                                HStack {
                                    Image(systemName: v.isRoot ? "internaldrive" : "externaldrive").foregroundStyle(MBColor.info)
                                    Text(v.name).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                                    Spacer()
                                    Text("\(HealthReport.bytes(v.availableBytes)) free of \(HealthReport.bytes(v.totalBytes))").font(MBFont.callout.monospacedDigit()).foregroundStyle(MBColor.textSecondary)
                                }
                                UsageBar(fraction: v.totalBytes > 0 ? Double(v.usedBytes) / Double(v.totalBytes) : 0, tone: v.freeFraction < 0.15 ? .warning : .info)
                            }
                        }
                    } else {
                        Text(s.storage.status.note ?? "Unavailable").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                    }
                }
            }
        }

        AdaptiveColumns {
            Panel {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader("Memory & CPU").padding(.bottom, MBSpace.s)
                    metric("Physical memory", s.memory.physicalBytes) { HealthReport.bytes(Int64($0)) }
                    metric("Memory in use", s.memory.usedBytes) { HealthReport.bytes(Int64($0)) }
                    metric("Compressed", s.memory.compressedBytes) { HealthReport.bytes(Int64($0)) }
                    metric("Swap used", s.memory.swapUsedBytes) { HealthReport.bytes(Int64($0)) }
                    metric("Memory pressure", s.memory.pressure) { $0.capitalized }
                    metric("CPU (all cores)", s.cpu.systemUsagePercent) { String(format: "%.1f%%", $0) }
                    metric("Load average 1/5/15 min", s.cpu.loadAverage) { $0.map { String(format: "%.2f", $0) }.joined(separator: " / ") }
                    metric("MyBuddy process", s.cpu.appProcessUsagePercent) { String(format: "%.1f%% of one core", $0) }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader("Connectivity & system").padding(.bottom, MBSpace.s)
                    metric("Network", s.network.pathStatus) { $0.capitalized }
                    metric("Interfaces", s.network.interfaces) { $0.map { "\($0.name) (\($0.kind))" }.joined(separator: ", ") }
                    metric("Hotspot / cellular", s.network.isExpensive) { $0 ? "Yes" : "No" }
                    metric("Thermal state", s.thermal.thermalState) { $0.capitalized }
                    metric("Temperatures & fans", s.thermal.temperatures) { $0 }
                    metric("macOS", s.system.osVersion) { $0 }
                    metric("Model", s.system.modelIdentifier) { $0 }
                    metric("Uptime", s.system.uptimeSeconds) { HealthReport.duration($0) }
                }
            }
        }

        if history.count >= 2 {
            Panel {
                VStack(alignment: .leading, spacing: MBSpace.m) {
                    SectionHeader("History", subtitle: "Local to this Mac · \(history.count) measurements")
                    Chart {
                        ForEach(Array(history.enumerated()), id: \.offset) { _, h in
                            if let level = h.battery.levelPercent.usableValue {
                                LineMark(x: .value("Time", h.collectedAt), y: .value("Battery %", level), series: .value("Metric", "Battery %"))
                                    .foregroundStyle(MBColor.accent).interpolationMethod(.monotone)
                            }
                            if let cpu = h.cpu.systemUsagePercent.usableValue {
                                LineMark(x: .value("Time", h.collectedAt), y: .value("CPU %", cpu), series: .value("Metric", "CPU %"))
                                    .foregroundStyle(MBColor.info).interpolationMethod(.monotone)
                            }
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartForegroundStyleScale(["Battery %": MBColor.accent, "CPU %": MBColor.info])
                    .frame(height: 160)
                    .accessibilityLabel("Battery and CPU history chart")
                }
            }
        }

        Panel {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("MyBuddy host").padding(.bottom, MBSpace.s)
                metric("LAN listener", s.host.lanListener) { $0 }
                MetricRow("Trusted devices", value: "\(s.host.trustedDevices)")
                MetricRow("Active sessions", value: "\(s.host.activeSessions)")
                MetricRow("App version", value: s.host.appVersion)
            }
        }
    }

    private func color(_ l: HealthFinding.Level) -> Color {
        switch l {
        case .ok: MBColor.accent
        case .info: MBColor.info
        case .attention: MBColor.warning
        case .critical: MBColor.danger
        }
    }

    @ViewBuilder
    private func metric<V>(_ label: String, _ m: HealthMetric<V>, _ format: (V) -> String) -> some View {
        switch m.status {
        case .available:
            MetricRow(label, value: m.value.map(format) ?? "—", note: m.origin == .derived ? "Derived: \(m.formula ?? "")" : nil, source: m.source)
        case .estimated(let note):
            MetricRow(label, value: m.value.map(format) ?? "—", note: "Estimate — \(note)", source: m.source, tone: .warning)
        case .unavailable(let why):
            MetricRow(label, value: "Unavailable", note: why, source: m.source, tone: .neutral)
        case .notPermitted(let why):
            MetricRow(label, value: "Not permitted", note: why, source: m.source, tone: .warning)
        }
    }
}
