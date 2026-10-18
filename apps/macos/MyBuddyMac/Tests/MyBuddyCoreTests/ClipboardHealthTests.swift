import Foundation
import Testing
@testable import MyBuddyCore

@Suite("Clipboard policy")
struct ClipboardTests {
    @Test func modesAndLoopPrevention() {
        var loop = ClipboardLoopGuard()
        let auto = ClipboardPolicy(mode: .trustedAuto)
        #expect(auto.evaluate(text: "hello", pasteboardTypes: ["public.utf8-plain-text"], loopGuard: loop) == .offerAutomatically)
        #expect(ClipboardPolicy(mode: .ask).evaluate(text: "hello", pasteboardTypes: [], loopGuard: loop) == .askUser(reason: nil))
        #expect(ClipboardPolicy(mode: .off).evaluate(text: "hello", pasteboardTypes: [], loopGuard: loop) == .skip(reason: "Clipboard sync is off"))
        #expect(ClipboardPolicy(mode: .trustedAuto, paused: true).evaluate(text: "hello", pasteboardTypes: [], loopGuard: loop) == .skip(reason: "Clipboard sync is paused"))

        loop.noteApplied(hash: ClipboardPolicy.hash("from phone"))
        if case .skip = auto.evaluate(text: "from phone", pasteboardTypes: [], loopGuard: loop) {} else {
            Issue.record("content applied from the peer must not bounce back")
        }
    }

    @Test func secretsAreNeverAutoSynced() {
        let auto = ClipboardPolicy(mode: .trustedAuto)
        let loop = ClipboardLoopGuard()
        if case .skip = auto.evaluate(text: "hunter2", pasteboardTypes: ["org.nspasteboard.ConcealedType"], loopGuard: loop) {} else {
            Issue.record("concealed pasteboard items must be skipped")
        }
        for secret in ["sk-" + "ant-abcdefghijklmnopqrstuvwxyz", "ghp_abcdefghijklmnopqrstuvwxyz123456", "AK" + "IAABCDEFGHIJKLMNOP",
                       "-----BEGIN OPENSSH " + "PRIVATE KEY-----\nabc"] {
            if case .askUser(let reason) = auto.evaluate(text: secret, pasteboardTypes: [], loopGuard: loop) {
                #expect(reason != nil)
            } else {
                Issue.record("credential-like text must require confirmation: \(secret.prefix(8))")
            }
        }
        if case .skip = auto.evaluate(text: String(repeating: "x", count: 70_000), pasteboardTypes: [], loopGuard: loop) {} else {
            Issue.record("oversized text must be skipped")
        }
    }
}

@Suite("Health model and report")
struct HealthReportTests {
    static func fixture(rootFree: Int64 = 50_000_000_000, condition: String = "Normal") -> HealthSnapshot {
        let t = Date(timeIntervalSince1970: 1_792_131_000)
        return HealthSnapshot(
            collectedAt: t, collectionDurationMs: 840, isPreviewData: false,
            battery: BatteryHealth(
                present: .reported(true, source: "IOPS", at: t), levelPercent: .reported(81, source: "IOPS", at: t),
                isCharging: .reported(false, source: "IOPS", at: t), powerSource: .reported("Battery Power", source: "IOPS", at: t),
                timeRemainingMinutes: .reported(312, source: "IOPS", at: t), timeRemainingKind: .toEmpty,
                condition: .reported(condition, source: "system_profiler SPPowerDataType", at: t),
                cycleCount: .reported(412, source: "system_profiler SPPowerDataType", at: t),
                maximumCapacityPercent: .reported(88, source: "system_profiler SPPowerDataType", at: t)),
            storage: .reported([VolumeUsage(name: "Macintosh HD", mountPoint: "/", totalBytes: 245_000_000_000, availableBytes: rootFree, isRoot: true, isInternal: true, fileSystem: "apfs"),
                                VolumeUsage(name: "Backup", mountPoint: "/Volumes/Backup", totalBytes: 1_000_000_000_000, availableBytes: 400_000_000_000, isRoot: false, isInternal: false, fileSystem: "apfs")],
                               source: "URLResourceValues", at: t),
            memory: MemoryHealth(physicalBytes: .reported(8 << 30, source: "ProcessInfo", at: t),
                                 usedBytes: .derived(5 << 30, formula: "active + wired + compressed", source: "host_statistics64", at: t),
                                 compressedBytes: .reported(1 << 30, source: "host_statistics64", at: t),
                                 wiredBytes: .reported(2 << 30, source: "host_statistics64", at: t),
                                 swapUsedBytes: .reported(0, source: "sysctl vm.swapusage", at: t),
                                 pressure: .estimated("normal", note: "No pressure events since start", source: "DispatchSource", at: t)),
            cpu: CPUHealth(logicalCores: .reported(8, source: "ProcessInfo", at: t), systemUsagePercent: .derived(12.5, formula: "Δbusy ÷ Δtotal ticks over 1 s", source: "host_processor_info", at: t),
                           loadAverage: .reported([1.2, 1.1, 0.9], source: "getloadavg", at: t), appProcessUsagePercent: .derived(0.4, formula: "Δcpu time ÷ Δwall", source: "getrusage", at: t),
                           appProcessMemoryBytes: .reported(80_000_000, source: "task_info", at: t)),
            thermal: ThermalHealth(thermalState: .reported("nominal", source: "ProcessInfo.thermalState", at: t),
                                   temperatures: .unavailable("No supported public API on Apple Silicon", source: "—", at: t)),
            system: SystemInfo(osVersion: .reported("macOS 26.4.1 (25E253)", source: "ProcessInfo", at: t), modelIdentifier: .reported("MacBookAir10,1", source: "sysctl hw.model", at: t),
                               chip: .reported("Apple M1", source: "sysctl machdep.cpu.brand_string", at: t), uptimeSeconds: .reported(93_784, source: "sysctl kern.boottime", at: t),
                               hostName: .reported("Salmans-MacBook-Air.local", source: "ProcessInfo.hostName", at: t)),
            network: NetworkHealth(pathStatus: .reported("satisfied", source: "NWPathMonitor", at: t),
                                   interfaces: .reported([NetworkInterfaceInfo(name: "en0", kind: "wifi", addresses: ["192.168.1.20"])], source: "getifaddrs", at: t),
                                   isExpensive: .reported(false, source: "NWPathMonitor", at: t), isConstrained: .reported(false, source: "NWPathMonitor", at: t)),
            host: HostDiagnostics(appVersion: "0.1.0", lanListener: .reported("listening on port 47811", source: "Network.framework", at: t), trustedDevices: 1, activeSessions: 0))
    }

    @Test func jsonExportIsVersionedAndRedacted() throws {
        let json = String(decoding: try HealthReport.json(Self.fixture()), as: UTF8.self)
        #expect(json.contains("\"schemaVersion\" : 1"))
        #expect(!json.contains("192.168.1.20"), "IP hidden by default")
        #expect(!json.contains("Salmans-MacBook-Air"), "host name hidden by default")
        #expect(!json.contains("/Volumes/Backup"), "mount paths hidden by default")
        let decoded = try JSONDecoder.iso8601.decode(HealthSnapshot.self, from: HealthReport.json(Self.fixture(), options: .none))
        #expect(decoded == Self.fixture())
    }

    @Test func markdownDistinguishesReportedDerivedAndUnavailable() {
        let md = HealthReport.markdown(Self.fixture())
        #expect(md.contains("| Cycle count | 412 | OK | OS-reported | system_profiler SPPowerDataType |"))
        #expect(md.contains("Derived (active + wired + compressed)"))
        #expect(md.contains("| Temperatures / fan speed | Unavailable | No supported public API on Apple Silicon |"))
        #expect(md.contains("Estimated: No pressure events since start"))
        #expect(!md.contains("PREVIEW DATA"))
        #expect(md.contains("not sent to any server or AI provider"))
    }

    @Test func assessmentExplainsEveryFinding() {
        let low = HealthAssessment.findings(for: Self.fixture(rootFree: 25_000_000_000, condition: "Service Recommended"))
        #expect(low.first?.level == .attention)
        #expect(low.contains { $0.area == "Battery" && $0.level == .attention })
        #expect(low.allSatisfy { !$0.rule.isEmpty })
        let critical = HealthAssessment.findings(for: Self.fixture(rootFree: 5_000_000_000))
        #expect(critical.first?.area == "Storage" && critical.first?.level == .critical)
    }

    @Test func unavailableValuesAreNeverShownAsData() {
        let m = HealthMetric<Int>(value: 99, status: .unavailable("denied"), source: "x", origin: .osReported, formula: nil, collectedAt: Date())
        #expect(m.usableValue == nil)
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
