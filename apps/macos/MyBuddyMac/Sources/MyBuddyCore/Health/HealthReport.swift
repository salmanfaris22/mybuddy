import Foundation

/// What to hide when exporting or sharing a health report. Defaults hide everything identifying.
public struct RedactionOptions: Sendable, Equatable, Codable {
    public var hidePaths = true
    public var hideNetworkAddresses = true
    public var hideHostName = true
    public var hideModelIdentifier = false

    public init(hidePaths: Bool = true, hideNetworkAddresses: Bool = true, hideHostName: Bool = true, hideModelIdentifier: Bool = false) {
        self.hidePaths = hidePaths
        self.hideNetworkAddresses = hideNetworkAddresses
        self.hideHostName = hideHostName
        self.hideModelIdentifier = hideModelIdentifier
    }

    public static let none = RedactionOptions(hidePaths: false, hideNetworkAddresses: false, hideHostName: false, hideModelIdentifier: false)
}

/// Renders a `HealthSnapshot` to JSON (schema-versioned) or Markdown. Never sends anything anywhere.
public enum HealthReport {
    public static func redacted(_ snapshot: HealthSnapshot, options: RedactionOptions, homeDirectory: String = NSHomeDirectory()) -> HealthSnapshot {
        var s = snapshot
        if options.hidePaths, var volumes = s.storage.value {
            for i in volumes.indices {
                volumes[i].mountPoint = volumes[i].isRoot ? "/" : "<volume \(i + 1)>"
                if volumes[i].name.contains(homeDirectory) { volumes[i].name = "<volume \(i + 1)>" }
            }
            s.storage.value = volumes
        }
        if options.hideNetworkAddresses, var ifaces = s.network.interfaces.value {
            for i in ifaces.indices { ifaces[i].addresses = ifaces[i].addresses.isEmpty ? [] : ["<redacted>"] }
            s.network.interfaces.value = ifaces
        }
        if options.hideHostName, s.system.hostName.value != nil {
            s.system.hostName.value = "<redacted>"
        }
        if options.hideModelIdentifier, s.system.modelIdentifier.value != nil {
            s.system.modelIdentifier.value = "<redacted>"
        }
        return s
    }

    public static func json(_ snapshot: HealthSnapshot, options: RedactionOptions = RedactionOptions()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(redacted(snapshot, options: options))
    }

    public static func markdown(_ snapshot: HealthSnapshot, options: RedactionOptions = RedactionOptions()) -> String {
        let s = redacted(snapshot, options: options)
        var lines: [String] = []
        lines.append("# Mac Health Report")
        lines.append("")
        lines.append("- Collected: \(Timestamp.string(from: s.collectedAt)) (took \(s.collectionDurationMs) ms)")
        lines.append("- Report schema: v\(s.schemaVersion) · MyBuddy \(s.host.appVersion)")
        if s.isPreviewData { lines.append("- **PREVIEW DATA — not measured on this Mac**") }
        lines.append("- Redaction: paths \(onOff(options.hidePaths)), network addresses \(onOff(options.hideNetworkAddresses)), host name \(onOff(options.hideHostName)), model \(onOff(options.hideModelIdentifier))")
        lines.append("")
        lines.append("Legend: **OS-reported** values come straight from macOS APIs; **Derived** values are computed by MyBuddy (formula shown).")

        let findings = HealthAssessment.findings(for: s)
        if !findings.isEmpty {
            lines.append("")
            lines.append("## Summary")
            for f in findings { lines.append("- \(levelLabel(f.level)) **\(f.area):** \(f.title) — _rule: \(f.rule)_") }
        }

        section(&lines, "Battery", [
            row("Battery present", s.battery.present) { $0 ? "Yes" : "No" },
            row("Charge level", s.battery.levelPercent) { "\($0)%" },
            row("Charging", s.battery.isCharging) { $0 ? "Yes" : "No" },
            row("Power source", s.battery.powerSource) { $0 },
            row(s.battery.timeRemainingKind == .toFull ? "Time to full" : "Time remaining", s.battery.timeRemainingMinutes) { minutes($0) },
            row("Condition", s.battery.condition) { $0 },
            row("Cycle count", s.battery.cycleCount) { "\($0)" },
            row("Maximum capacity", s.battery.maximumCapacityPercent) { "\($0)%" },
        ])

        lines.append("")
        lines.append("## Storage")
        if let volumes = s.storage.usableValue {
            lines.append("")
            lines.append("| Volume | Mount | Used | Free | Total |")
            lines.append("|---|---|---|---|---|")
            for v in volumes {
                lines.append("| \(v.name) | \(v.mountPoint) | \(bytes(v.usedBytes)) | \(bytes(v.availableBytes)) | \(bytes(v.totalBytes)) |")
            }
            lines.append("")
            lines.append("_Source: \(s.storage.source)_")
        } else {
            lines.append("")
            lines.append("Unavailable: \(s.storage.status.note ?? "unknown")")
        }

        section(&lines, "Memory", [
            row("Physical memory", s.memory.physicalBytes) { bytes(Int64($0)) },
            row("In use", s.memory.usedBytes) { bytes(Int64($0)) },
            row("Compressed", s.memory.compressedBytes) { bytes(Int64($0)) },
            row("Wired", s.memory.wiredBytes) { bytes(Int64($0)) },
            row("Swap used", s.memory.swapUsedBytes) { bytes(Int64($0)) },
            row("Memory pressure", s.memory.pressure) { $0 },
        ])
        section(&lines, "CPU", [
            row("Logical cores", s.cpu.logicalCores) { "\($0)" },
            row("System CPU usage", s.cpu.systemUsagePercent) { String(format: "%.1f%%", $0) },
            row("Load average (1/5/15 min)", s.cpu.loadAverage) { $0.map { String(format: "%.2f", $0) }.joined(separator: " / ") },
            row("MyBuddy process CPU", s.cpu.appProcessUsagePercent) { String(format: "%.1f%%", $0) },
            row("MyBuddy process memory", s.cpu.appProcessMemoryBytes) { bytes(Int64($0)) },
        ])
        section(&lines, "Thermal", [
            row("Thermal state", s.thermal.thermalState) { $0 },
            row("Temperatures / fan speed", s.thermal.temperatures) { $0 },
        ])
        section(&lines, "System", [
            row("macOS", s.system.osVersion) { $0 },
            row("Model", s.system.modelIdentifier) { $0 },
            row("Chip", s.system.chip) { $0 },
            row("Uptime", s.system.uptimeSeconds) { duration($0) },
            row("Host name", s.system.hostName) { $0 },
        ])
        section(&lines, "Network", [
            row("Connectivity", s.network.pathStatus) { $0 },
            row("Interfaces", s.network.interfaces) { $0.map { "\($0.name) (\($0.kind)) \($0.addresses.joined(separator: ", "))" }.joined(separator: "; ") },
            row("Expensive (hotspot/cellular)", s.network.isExpensive) { $0 ? "Yes" : "No" },
            row("Low Data Mode", s.network.isConstrained) { $0 ? "Yes" : "No" },
        ])
        lines.append("")
        lines.append("## MyBuddy host")
        lines.append("")
        lines.append("- LAN listener: \(s.host.lanListener.usableValue ?? (s.host.lanListener.status.note ?? "unavailable"))")
        lines.append("- Trusted devices: \(s.host.trustedDevices) · Active sessions: \(s.host.activeSessions)")
        lines.append("")
        lines.append("---")
        lines.append("Generated locally by MyBuddy. This report was not sent to any server or AI provider.")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: helpers

    private struct Row { let name: String; let value: String; let status: String; let origin: String; let source: String }

    private static func row<V>(_ name: String, _ m: HealthMetric<V>, _ format: (V) -> String) -> Row {
        let value: String
        let status: String
        switch m.status {
        case .available:
            value = m.value.map(format) ?? "—"
            status = "OK"
        case .estimated(let note):
            value = m.value.map(format) ?? "—"
            status = "Estimated: \(note)"
        case .unavailable(let why):
            value = "Unavailable"
            status = why
        case .notPermitted(let why):
            value = "Not permitted"
            status = why
        }
        let origin = m.origin == .derived ? "Derived" + (m.formula.map { " (\($0))" } ?? "") : "OS-reported"
        return Row(name: name, value: value, status: status, origin: origin, source: m.source)
    }

    private static func section(_ lines: inout [String], _ title: String, _ rows: [Row]) {
        lines.append("")
        lines.append("## \(title)")
        lines.append("")
        lines.append("| Metric | Value | Status | Origin | Source |")
        lines.append("|---|---|---|---|---|")
        for r in rows {
            lines.append("| \(r.name) | \(escape(r.value)) | \(escape(r.status)) | \(escape(r.origin)) | \(escape(r.source)) |")
        }
    }

    private static func escape(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
    private static func onOff(_ b: Bool) -> String { b ? "hidden" : "shown" }

    private static func levelLabel(_ l: HealthFinding.Level) -> String {
        switch l {
        case .ok: "OK"
        case .info: "Info"
        case .attention: "Attention"
        case .critical: "Critical"
        }
    }

    public static func bytes(_ n: Int64) -> String { n.formatted(.byteCount(style: .file)) }

    public static func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }

    public static func duration(_ seconds: Int64) -> String {
        let d = seconds / 86_400, h = (seconds % 86_400) / 3_600, m = (seconds % 3_600) / 60
        return d > 0 ? "\(d) d \(h) h" : h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}
