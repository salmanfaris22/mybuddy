import Foundation
import MyBuddyCore
import MyBuddyHost

/// Believable fixtures for Preview/Demo mode ONLY (`--demo` or `--snapshot`). Every screen showing
/// them also shows the "Preview data" badge, and snapshots are flagged `isPreviewData`.
enum DemoData {
    static let now = Date()
    static let phone = SoftwareIdentity()

    /// Preview-only shared notes.
    static var notes: [Note] {
        let ms = Note.nowMs()
        return [
            Note(id: "6f1c2b9e-1d2a-4c7e-9a51-3b8f0d2e4a10", text: "Weekend groceries\n- coffee beans\n- oat milk\n- basil", updatedAt: ms - 120_000),
            Note(id: "0b7e9a44-5c21-4f0e-8d9b-7a6c5e4d3b21", text: "Release checklist\nNotarize the Mac build, then send the APK", updatedAt: ms - 3_600_000),
        ]
    }

    /// Preview-only mirrored notifications (shown with the "Preview data" badge).
    static var phoneNotifications: [NotificationsStore.PhoneNotification] {
        let now = Date()
        return [
            .init(id: "n_demo1", deviceName: "Vivo X300", appLabel: "Messages", title: "Asha", text: "Running 10 min late, order me a coffee?", redaction: "none",
                  receivedAt: now.addingTimeInterval(-90)),
            .init(id: "n_demo2", deviceName: "Vivo X300", appLabel: "Bank", title: "Sign-in attempt", text: "Your verification code is ••••••. Don’t share it.",
                  redaction: "partial", receivedAt: now.addingTimeInterval(-600)),
            .init(id: "n_demo3", deviceName: "Vivo X300", appLabel: "Calendar", title: nil, text: nil, redaction: "content_hidden",
                  receivedAt: now.addingTimeInterval(-1800)),
        ]
    }

    static var settings: AppSettings {
        var s = AppSettings()
        s.selectedProviderId = "anthropic"
        s.providers[0].selectedModel = "claude-opus-5-5"
        s.providers[0].models = models
        s.clipboardMode = .ask
        s.allowInternet = true
        s.connectServer = "https://connect.example.com"
        s.connectEnrollments = [trustedDevices.first?.id ?? "": "pr_demo"]
        return s
    }

    static var trustedDevices: [TrustedDevice] {
        var grant = PermissionGrant()
        grant.set(.inputControl, enabled: true)
        grant.set(.filesBrowse, enabled: true)
        grant.set(.notificationsMirror, enabled: true)
        return [TrustedDevice(id: phone.deviceId, publicKeySPKI: phone.publicKeySPKI, name: "Vivo X300", platform: "android",
                              pairedAt: now.addingTimeInterval(-86_400 * 6), lastSeenAt: now.addingTimeInterval(-40), grant: grant, revokedAt: nil)]
    }

    static func sessions(for devices: [TrustedDevice]) -> [ActiveSessionInfo] {
        devices.filter(\.isActive).map {
            ActiveSessionInfo(id: "s_demo000001", deviceId: $0.id, deviceName: $0.name, platform: $0.platform,
                              startedAt: now.addingTimeInterval(-620), grantedCapabilities: $0.grant.capabilities, remoteAddress: "192.168.1.34:52110")
        }
    }

    static var invitation: PairingInvitation {
        PairingInvitation(addresses: ["192.168.1.20:47811"], hostFingerprint: SoftwareIdentity().fingerprint,
                          secret: Data(repeating: 7, count: 32), expiresAt: now.addingTimeInterval(104), displayName: "MacBook Air")
    }

    static var activity: [ActivityEvent] {
        [
            ActivityEvent(date: now.addingTimeInterval(-40), kind: .session, title: "Session started with Vivo X300", detail: "View screen, Read Mac health, Clipboard sync"),
            ActivityEvent(date: now.addingTimeInterval(-180), kind: .clipboard, title: "Clipboard updated from Vivo X300", detail: "42 bytes"),
            ActivityEvent(date: now.addingTimeInterval(-900), kind: .voice, title: "Show battery health", detail: "succeeded"),
            ActivityEvent(date: now.addingTimeInterval(-1_900), kind: .ai, title: "Anthropic API · claude-opus-5-5", detail: "end_turn"),
            ActivityEvent(date: now.addingTimeInterval(-4_000), kind: .transfer, title: "Received Quarterly report.pdf", detail: "2.1 MB · SHA-256 verified"),
            ActivityEvent(date: now.addingTimeInterval(-9_000), kind: .security, title: "Refused unknown or revoked device", detail: "192.168.1.77"),
            ActivityEvent(date: now.addingTimeInterval(-86_400), kind: .pairing, title: "Paired with Vivo X300", detail: "Verification code confirmed on the Mac"),
        ]
    }

    static var models: [ModelDescriptor] {
        [ModelDescriptor(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", contextWindow: 1_000_000, maxOutputTokens: 128_000, supportsVision: true, supportsAdaptiveThinking: true, supportsEffort: true, source: "GET /v1/models"),
         ModelDescriptor(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", contextWindow: 1_000_000, maxOutputTokens: 128_000, source: "GET /v1/models"),
         ModelDescriptor(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", contextWindow: 1_000_000, maxOutputTokens: 128_000, source: "GET /v1/models")]
    }

    static var chat: [ChatTurn] {
        [ChatTurn(role: .user, text: "Is my battery healthy enough to skip a replacement this year?"),
         ChatTurn(role: .assistant, text: "Probably, yes. macOS reports the condition as Normal with a maximum capacity of 88% after 412 cycles. Apple's design target is 80% at 1,000 cycles, so you have headroom. Keep an eye on the maximum capacity value in Mac Health — if it drops under 80%, plan a replacement.",
                  status: .complete, servedBy: "claude-opus-5-5", providerName: "Anthropic API", usage: TokenUsage(inputTokens: 312, outputTokens: 74))]
    }

    static var agentDetections: [AgentKind: LoadState<AgentDetection>] {
        [.claudeCode: .loaded(AgentDetection(kind: .claudeCode, executablePath: "~/.local/bin/claude", version: "2.1.301", auth: .signedIn(method: "claude.ai"), checkedAt: now)),
         .codex: .loaded(AgentDetection(kind: .codex, executablePath: "/opt/homebrew/bin/codex", version: "0.160.0", auth: .signedIn(method: "API key"), checkedAt: now))]
    }

    static var agentLog: [AgentLogLine] {
        [AgentLogLine(event: .started(sessionId: "8f2c…", model: "claude-opus-5-5")),
         AgentLogLine(event: .assistantText("I’ll look at how the pairing window expires before suggesting a change.")),
         AgentLogLine(event: .toolProposed(name: "Read", summary: "Sources/MyBuddyCore/Pairing/Pairing.swift")),
         AgentLogLine(event: .toolProposed(name: "Grep", summary: "expiresAt")),
         AgentLogLine(event: .finished(success: true, summary: "The window already closes on expiry and after 5 failed proofs; no change needed.", costUSD: 0.04))]
    }

    static var voiceHistory: [VoiceOutcome] {
        [VoiceOutcome(transcript: "Show my Mac battery health", intent: .showBatteryHealth, status: .succeeded,
                      summary: "Battery at 81 percent, condition Normal, 412 cycles, maximum capacity 88 percent."),
         VoiceOutcome(transcript: "Delete my downloads", intent: nil, status: .rejected, summary: "MyBuddy Voice can’t do that (“delete”).")]
    }

    static var folders: [GrantedFolder] {
        [GrantedFolder(id: "downloads", displayName: "Downloads", path: "/Users/you/Downloads"),
         GrantedFolder(id: "projects", displayName: "Projects", path: "/Users/you/Projects")]
    }

    static var folderEntries: [[String: JSONValue]] {
        [["name": .string("Invoices"), "kind": .string("folder")],
         ["name": .string("Quarterly report.pdf"), "kind": .string("file"), "size": .int(2_204_311), "modifiedAt": .string(Timestamp.string(from: now.addingTimeInterval(-4_000)))],
         ["name": .string("Screenshot 2026-10-15.png"), "kind": .string("file"), "size": .int(842_113), "modifiedAt": .string(Timestamp.string(from: now.addingTimeInterval(-90_000)))],
         ["name": .string("notes.md"), "kind": .string("file"), "size": .int(3_412), "modifiedAt": .string(Timestamp.string(from: now.addingTimeInterval(-200_000)))]]
    }

    static var transfers: [TransferService.Item] {
        [TransferService.Item(id: UUID(), name: "IMG_2041.HEIC", size: 3_812_000, direction: .toMac, sessionId: "demo", deviceName: "Vivo X300",
                              state: .inProgress(received: 2_400_000, total: 3_812_000), updatedAt: Date()),
         TransferService.Item(id: UUID(), name: "Quarterly report.pdf", size: 2_204_311, direction: .toMac, sessionId: "demo", deviceName: "Vivo X300",
                              state: .completed(URL(fileURLWithPath: "/tmp/x")), updatedAt: Date().addingTimeInterval(-600))]
    }

    static var health: HealthSnapshot {
        let t = now
        func r<V>(_ v: V, _ s: String) -> HealthMetric<V> { .reported(v, source: s, at: t) }
        return HealthSnapshot(
            collectedAt: t, collectionDurationMs: 1_112, isPreviewData: true,
            battery: BatteryHealth(present: r(true, "IOKit IOPSCopyPowerSourcesInfo"), levelPercent: r(81, "IOKit IOPSCopyPowerSourcesInfo"),
                                   isCharging: r(false, "IOKit IOPSCopyPowerSourcesInfo"), powerSource: r("Battery Power", "IOKit IOPSCopyPowerSourcesInfo"),
                                   timeRemainingMinutes: r(312, "IOKit IOPSCopyPowerSourcesInfo"), timeRemainingKind: .toEmpty,
                                   condition: r("Normal", "system_profiler SPPowerDataType"), cycleCount: r(412, "system_profiler SPPowerDataType"),
                                   maximumCapacityPercent: r(88, "system_profiler SPPowerDataType")),
            storage: r([VolumeUsage(name: "Macintosh HD", mountPoint: "/", totalBytes: 245_107_195_904, availableBytes: 61_400_000_000, isRoot: true, isInternal: true, fileSystem: "APFS"),
                        VolumeUsage(name: "Backup", mountPoint: "/Volumes/Backup", totalBytes: 1_000_000_000_000, availableBytes: 412_000_000_000, isRoot: false, isInternal: false, fileSystem: "APFS")],
                       "URLResourceValues (available for important usage)"),
            memory: MemoryHealth(physicalBytes: r(8 << 30, "ProcessInfo.physicalMemory"),
                                 usedBytes: .derived(5_900_000_000, formula: "(internal − purgeable) + wired + compressed pages × page size", source: "host_statistics64", at: t),
                                 compressedBytes: r(1_200_000_000, "host_statistics64"), wiredBytes: r(1_700_000_000, "host_statistics64"),
                                 swapUsedBytes: r(410_000_000, "sysctl vm.swapusage"),
                                 pressure: .estimated("normal", note: "No memory-pressure events since MyBuddy started", source: "DispatchSource memory-pressure events", at: t)),
            cpu: CPUHealth(logicalCores: r(8, "ProcessInfo.activeProcessorCount"),
                           systemUsagePercent: .derived(14.2, formula: "Δbusy ticks ÷ Δtotal ticks over 1.0 s, all cores", source: "host_processor_info", at: t),
                           loadAverage: r([1.84, 1.62, 1.41], "getloadavg"),
                           appProcessUsagePercent: .derived(0.6, formula: "Δ(user+system CPU time) ÷ Δwall time", source: "getrusage", at: t),
                           appProcessMemoryBytes: r(86_000_000, "task_info")),
            thermal: ThermalHealth(thermalState: r("nominal", "ProcessInfo.thermalState"),
                                   temperatures: .unavailable("Apple Silicon exposes no supported public API for CPU/GPU temperatures or fan speed", source: "—", at: t)),
            system: SystemInfo(osVersion: r("macOS 26.4.1 (25E253)", "ProcessInfo.operatingSystemVersion"), modelIdentifier: r("MacBookAir10,1", "sysctl hw.model"),
                               chip: r("Apple M1", "sysctl machdep.cpu.brand_string"), uptimeSeconds: r(273_600, "sysctl kern.boottime"),
                               hostName: r("MacBook-Air.local", "gethostname")),
            network: NetworkHealth(pathStatus: r("connected", "NWPathMonitor"),
                                   interfaces: r([NetworkInterfaceInfo(name: "en0", kind: "Wi-Fi", addresses: ["192.168.1.20"])], "getifaddrs"),
                                   isExpensive: r(false, "NWPathMonitor"), isConstrained: r(false, "NWPathMonitor")),
            host: HostDiagnostics(appVersion: HostInfo.appVersion, lanListener: r("Listening on port 47811", "NWListener"), trustedDevices: 1, activeSessions: 1))
    }

    static var healthHistory: [HealthSnapshot] {
        (0..<24).map { i in
            var s = health
            s.collectedAt = now.addingTimeInterval(Double(i - 24) * 600)
            s.battery.levelPercent = .reported(100 - i * 2, source: "IOKit", at: s.collectedAt)
            s.cpu.systemUsagePercent = .derived(8 + Double((i * 37) % 23), formula: "Δbusy ÷ Δtotal", source: "host_processor_info", at: s.collectedAt)
            return s
        }
    }
}
