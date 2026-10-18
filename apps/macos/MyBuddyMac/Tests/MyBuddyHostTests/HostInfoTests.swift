import Foundation
import Testing
import MyBuddyCore
import Network
@testable import MyBuddyHost

@Test func hostInfoIsStable() {
    #expect(HostInfo.bundleIdentifier == "app.mybuddy.mac")
}

@Suite("Keychain (live, throw-away items)", .serialized)
struct KeychainTests {
    @Test func secretStoreRoundTrip() throws {
        let store = KeychainSecretStore()
        let ref = SecretReference(service: "app.mybuddy.tests", account: "test-\(UUID().uuidString)")
        defer { try? store.delete(ref) }
        #expect(try store.read(ref) == nil)
        try store.write("sk-test-value-1", for: ref)
        try store.write("sk-test-value-2", for: ref)  // update path
        #expect(try store.read(ref) == "sk-test-value-2")
        try store.delete(ref)
        #expect(try store.read(ref) == nil)
    }

    @Test func identityIsCreatedOnceAndSigns() throws {
        let account = "test-identity-\(UUID().uuidString)"
        defer { try? KeychainIdentityStore.reset(account: account) }
        let (first, backend) = try KeychainIdentityStore.loadOrCreate(account: account)
        let (again, backend2) = try KeychainIdentityStore.loadOrCreate(account: account)
        #expect(first.publicKeySPKI == again.publicKeySPKI, "identity persists")
        #expect(backend == backend2)
        let message = Data("MBH1/host-sig test".utf8)
        let sig = try first.sign(message)
        #expect(IdentityMath.verify(spki: first.publicKeySPKI, message: message, derSignature: sig))
        print("identity backend on this Mac: \(backend.rawValue)")
    }

    @Test func trustStorageRoundTrip() throws {
        let storage = KeychainTrustStorage(account: "test-trust-\(UUID().uuidString)")
        defer { try? storage.deleteAll() }
        let store = TrustStore(storage: storage)
        let phone = SoftwareIdentity()
        try store.trust(spki: phone.publicKeySPKI, name: "Vivo X300", platform: "android")
        let reloaded = TrustStore(storage: storage)
        #expect(reloaded.isTrusted(spki: phone.publicKeySPKI))
    }
}

@Suite("Process runner")
struct ProcessRunnerTests {
    @Test func runsWithoutShellAndCapturesOutput() async {
        let r = await ProcessRunner.run("/bin/echo", ["hello; rm -rf /"])
        #expect(r.exitCode == 0 && r.stdoutString == "hello; rm -rf /\n", "arguments are passed literally, no shell")
    }

    @Test func enforcesTimeout() async {
        let start = Date()
        let r = await ProcessRunner.run("/bin/sleep", ["30"], timeout: 0.5)
        #expect(r.timedOut && Date().timeIntervalSince(start) < 5)
    }

    @Test func refusesRelativeOrMissingExecutables() async {
        #expect(await ProcessRunner.run("echo", ["x"]).exitCode == 127)
        #expect(await ProcessRunner.run("/nonexistent/tool", []).exitCode == 127)
    }

    @Test func environmentIsAllowlisted() {
        let env = ProcessRunner.environment(executable: "/opt/homebrew/bin/codex")
        #expect(env["ANTHROPIC_API_KEY"] == nil && env["OPENAI_API_KEY"] == nil && env["CODEX_API_KEY"] == nil)
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin") == true)
        #expect(env["HOME"] == NSHomeDirectory())
    }

    @Test func streamingProcessDeliversLinesAndCancels() async throws {
        let p = try StreamingProcess(executable: "/bin/cat", arguments: [], cwd: URL(fileURLWithPath: "/tmp"), stdin: Data("one\ntwo\n".utf8))
        var lines: [String] = []
        for await l in p.lines { lines.append(l) }
        #expect(lines == ["one", "two"])
        #expect(await p.waitForExit() == 0)

        let sleeper = try StreamingProcess(executable: "/bin/sleep", arguments: ["30"], cwd: URL(fileURLWithPath: "/tmp"), stdin: Data())
        sleeper.cancel()
        let code = await sleeper.waitForExit()
        #expect(code != 0, "cancelled process exits via signal")
    }
}

@Suite("Health collector (live on this Mac)")
struct HealthCollectorTests {
    @Test func systemProfilerParserReadsOnlyHealthBlock() {
        let json = #"{"SPPowerDataType":[{"_name":"spbattery_information","sppower_battery_health_info":{"sppower_battery_cycle_count":524,"sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"84%"},"sppower_battery_model_info":{"sppower_battery_serial_number":"SECRET123"}}]}"#
        let parsed = SystemHealthCollector.parseSystemProfiler(Data(json.utf8))
        #expect(parsed.cycleCount == 524 && parsed.condition == "Good" && parsed.maximumCapacityPercent == 84 && parsed.error == nil)
        let none = SystemHealthCollector.parseSystemProfiler(Data(#"{"SPPowerDataType":[{"_name":"sppower_ac_charger_information"}]}"#.utf8))
        #expect(none.error != nil && none.cycleCount == nil)
    }

    @Test func collectsARealSnapshot() async throws {
        let monitor = MemoryPressureMonitor()
        monitor.start()
        let snapshot = await SystemHealthCollector(pressure: monitor).collect(
            host: HostDiagnostics(appVersion: "test", lanListener: .unavailable("not started", source: "test", at: Date()), trustedDevices: 0, activeSessions: 0))
        #expect(!snapshot.isPreviewData)
        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.system.osVersion.usableValue?.hasPrefix("macOS ") == true)
        #expect(snapshot.cpu.logicalCores.usableValue ?? 0 > 0)
        #expect(snapshot.memory.physicalBytes.usableValue ?? 0 > 1 << 30)
        #expect(snapshot.rootVolume != nil, "root volume reported")
        #expect(snapshot.thermal.temperatures.usableValue == nil, "temperatures are never fabricated")
        if let pct = snapshot.cpu.systemUsagePercent.usableValue { #expect((0...100).contains(pct)) }
        if snapshot.battery.present.usableValue == true {
            let level = try #require(snapshot.battery.levelPercent.usableValue)
            #expect((0...100).contains(level))
        }
        // Print a redacted summary so the test log records what this Mac actually reported.
        print(HealthReport.markdown(snapshot).split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Metric") }.prefix(12).joined(separator: "\n"))
    }
}

@Suite("Coding agent detection (live, read-only status commands)")
struct AgentDetectionTests {
    @Test(arguments: AgentKind.allCases)
    func detectsInstalledCLIsWithoutLeakingAccountData(_ kind: AgentKind) async {
        let d = await AgentService.detect(kind)
        print("\(kind.displayName): path=\(d.executablePath.map { Redactor.redact($0) } ?? "not found") version=\(d.version ?? "?") auth=\(d.auth.title)")
        if d.executablePath != nil { #expect(d.version != nil, "version parsed") }
        #expect(!d.auth.title.contains("@"), "no e-mail addresses in status")
        #expect(!d.auth.title.contains("sk-"), "no key fragments in status")
    }
}

@Suite("LAN addresses for pairing")
struct LANAddressOrderTests {
    @Test func primaryInterfaceFirstBridgesLastPrivateIPv4Only() {
        let interfaces = ["bridge100": ["192.168.2.1"], "en0": ["192.168.1.231", "fe80::1c2a"], "en5": ["10.0.0.4"],
                          "utun3": ["10.8.0.2"], "lo0": ["127.0.0.1"], "en7": ["203.0.113.9"]]
        #expect(SystemHealthCollector.orderedLANAddresses(interfaces, primaryInterface: "en0") == ["192.168.1.231", "10.0.0.4", "192.168.2.1"])
        #expect(SystemHealthCollector.orderedLANAddresses(interfaces, primaryInterface: "en5") == ["10.0.0.4", "192.168.1.231", "192.168.2.1"])
        #expect(SystemHealthCollector.orderedLANAddresses(interfaces, primaryInterface: nil).last == "192.168.2.1")
    }

    @Test func liveAddressesOnThisMacArePrivateAndLeadWithThePrimaryInterface() {
        let live = SystemHealthCollector.lanIPv4Addresses()
        #expect(live.allSatisfy { EndpointValidator.classify(host: $0) == .privateNetwork })
        if let primary = SystemHealthCollector.primaryInterfaceName(),
           let first = SystemHealthCollector.interfaceAddresses()[primary]?.first(where: { !$0.contains(":") && EndpointValidator.classify(host: $0) == .privateNetwork }) {
            #expect(live.first == first)
        }
        print("pairing addresses on this Mac: \(live.count) (primary interface: \(SystemHealthCollector.primaryInterfaceName() ?? "none"))")
    }
}

@Suite("Tailscale status")
struct TailscaleStatusTests {
    let confirmed = ["utun4": ["100.101.102.103", "fd7a:115c:a1e0::4f2b"]]
    let cgnatOnly = ["en0": ["100.72.10.20"]]  // e.g. a carrier-grade-NAT network, not Tailscale

    @Test func connectedOnlyWhenTailnetTrafficLeavesFromTheTunnel() {
        #expect(TailscaleStatus.evaluate(interfaces: confirmed, installed: false, routedSource: "100.101.102.103").address == "100.101.102.103")
        // Stopped Tailscale keeps the interface address but traffic goes out over Wi-Fi: not connected.
        #expect(TailscaleStatus.evaluate(interfaces: confirmed, installed: true, routedSource: "192.168.1.231").state == .installedNotConnected)
        #expect(TailscaleStatus.evaluate(interfaces: confirmed, installed: false, routedSource: nil).state == .installedNotConnected)
    }

    @Test func plainCGNATAddressCountsOnlyWhenTailscaleIsInstalled() {
        #expect(TailscaleStatus.evaluate(interfaces: cgnatOnly, installed: false, routedSource: "100.72.10.20").state == .notInstalled)
        #expect(TailscaleStatus.evaluate(interfaces: cgnatOnly, installed: true, routedSource: "100.72.10.20").address == "100.72.10.20")
    }

    @Test func installedButDown() {
        #expect(TailscaleStatus.evaluate(interfaces: ["en0": ["192.168.1.231"]], installed: true, routedSource: "192.168.1.231").state == .installedNotConnected)
        #expect(TailscaleStatus.evaluate(interfaces: ["en0": ["192.168.1.231"]], installed: false, routedSource: "192.168.1.231").state == .notInstalled)
    }

    @Test func routedSourceIsALocalAddress() {
        // Reaching a LAN-style address goes out over some local interface (no packet is sent).
        if let source = TailscaleStatus.routedSourceAddress(to: "192.0.2.1") {
            #expect(SystemHealthCollector.interfaceAddresses().values.contains { $0.contains(source) })
        }
    }

    @Test func thisMacReportsHonestly() {
        let status = TailscaleStatus.current()
        print("Tailscale on this Mac: \(status.state)")
        if case .connected(let i) = status.state { #expect(Tailnet.isTailnetIPv4(i.ipv4)) }
    }

    @Test func remoteHostOfAConnectionIsParsedWithoutPortOrScope() {
        #expect(LANHostServer.remoteHost(.hostPort(host: .ipv4(IPv4Address("100.101.102.103")!), port: 52110)) == "100.101.102.103")
        #expect(LANHostServer.remoteHost(.hostPort(host: .ipv6(IPv6Address("fd7a:115c:a1e0::5")!), port: 52110)).map(Tailnet.isTailnetIPv6) == true)
        #expect(LANHostServer.remoteHost(.hostPort(host: .ipv4(IPv4Address("192.168.1.34")!), port: 1)).map(Tailnet.isTailnetAddress) == false)
    }
}
