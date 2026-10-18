import Darwin
import Foundation
import IOKit.ps
import MyBuddyCore
import Network
import SystemConfiguration

/// Tracks memory-pressure events (documented DispatchSource API). There is no supported
/// synchronous query, so until the first event the level is reported as an estimate.
public final class MemoryPressureMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.mybuddy.memory-pressure")
    private var source: (any DispatchSourceMemoryPressure)?
    private let lock = NSLock()
    private var level: String?
    private var since = Date()

    public init() {}

    public func start() {
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        s.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            let e = s.data
            let value = e.contains(.critical) ? "critical" : e.contains(.warning) ? "warning" : "normal"
            self.lock.withLock {
                self.level = value
                self.since = Date()
            }
        }
        s.resume()
        source = s
    }

    public var current: (level: String?, since: Date) { lock.withLock { (level, since) } }
}

/// Collects a `HealthSnapshot` from public APIs, concurrently, with per-metric status and source.
public struct SystemHealthCollector: Sendable {
    public var cpuSampleInterval: TimeInterval = 1.0
    public var includeSystemProfiler = true
    private let pressure: MemoryPressureMonitor?

    public init(pressure: MemoryPressureMonitor? = nil) { self.pressure = pressure }

    public func collect(host: HostDiagnostics) async -> HealthSnapshot {
        let started = Date()
        async let profiler = includeSystemProfiler ? Self.batteryHealthFromSystemProfiler() : nil
        async let cpuSample = Self.sampleCPU(interval: cpuSampleInterval)
        async let net = Self.network()
        let now = Date()
        let battery = Self.battery(now: now, profiler: await profiler)
        let storage = Self.storage(now: now)
        let memory = Self.memory(now: now, pressure: pressure)
        let cpu = await cpuSample
        let thermal = Self.thermal(now: now)
        let system = Self.system(now: now)
        let network = await net
        return HealthSnapshot(collectedAt: now, collectionDurationMs: Int(Date().timeIntervalSince(started) * 1000), isPreviewData: false,
                              battery: battery, storage: storage, memory: memory, cpu: cpu, thermal: thermal, system: system,
                              network: network, host: host)
    }

    // MARK: Battery

    struct ProfilerBattery: Sendable {
        var cycleCount: Int?
        var condition: String?
        var maximumCapacityPercent: Int?
        var error: String?
    }

    static func batteryHealthFromSystemProfiler() async -> ProfilerBattery {
        let r = await ProcessRunner.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"], timeout: 15, maxOutput: 4 << 20)
        guard r.exitCode == 0, !r.timedOut else { return ProfilerBattery(error: r.timedOut ? "system_profiler timed out" : "system_profiler failed") }
        return parseSystemProfiler(r.stdout)
    }

    /// Reads only the battery health block (never model/serial information).
    static func parseSystemProfiler(_ data: Data) -> ProfilerBattery {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["SPPowerDataType"] as? [[String: Any]],
              let battery = entries.first(where: { $0["_name"] as? String == "spbattery_information" }),
              let health = battery["sppower_battery_health_info"] as? [String: Any]
        else { return ProfilerBattery(error: "no battery information reported") }
        var out = ProfilerBattery()
        out.cycleCount = (health["sppower_battery_cycle_count"] as? NSNumber)?.intValue
        out.condition = health["sppower_battery_health"] as? String
        if let max = health["sppower_battery_health_maximum_capacity"] as? String {
            out.maximumCapacityPercent = Int(max.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        }
        return out
    }

    /// Battery level and charging state only (IOKit power sources; cheap enough to poll every couple of minutes).
    public static func currentBattery() -> BatteryHealth { battery(now: Date(), profiler: nil) }

    static func battery(now: Date, profiler: ProfilerBattery?) -> BatteryHealth {
        let src = "IOKit IOPSCopyPowerSourcesInfo"
        let sp = "system_profiler SPPowerDataType"
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            let u = "Power source information unavailable"
            return BatteryHealth(present: .unavailable(u, source: src, at: now), levelPercent: .unavailable(u, source: src, at: now),
                                 isCharging: .unavailable(u, source: src, at: now), powerSource: .unavailable(u, source: src, at: now),
                                 timeRemainingMinutes: .unavailable(u, source: src, at: now), timeRemainingKind: nil,
                                 condition: .unavailable(u, source: src, at: now), cycleCount: .unavailable(u, source: sp, at: now),
                                 maximumCapacityPercent: .unavailable(u, source: sp, at: now))
        }
        let descriptions = list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
        let internalBattery = descriptions.first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?

        guard let b = internalBattery, (b[kIOPSIsPresentKey] as? Bool) != false else {
            let none = "This Mac has no internal battery"
            return BatteryHealth(present: .reported(false, source: src, at: now), levelPercent: .unavailable(none, source: src, at: now),
                                 isCharging: .unavailable(none, source: src, at: now),
                                 powerSource: providing.map { .reported($0, source: "IOPSGetProvidingPowerSourceType", at: now) } ?? .unavailable(none, source: src, at: now),
                                 timeRemainingMinutes: .unavailable(none, source: src, at: now), timeRemainingKind: nil,
                                 condition: .unavailable(none, source: src, at: now), cycleCount: .unavailable(none, source: sp, at: now),
                                 maximumCapacityPercent: .unavailable(none, source: sp, at: now))
        }

        let current = b[kIOPSCurrentCapacityKey] as? Int
        let max = b[kIOPSMaxCapacityKey] as? Int
        let level: HealthMetric<Int>
        if let current, let max, max > 0 {
            level = max == 100 ? .reported(current, source: src, at: now)
                               : .derived(Int((Double(current) / Double(max) * 100).rounded()), formula: "Current Capacity ÷ Max Capacity", source: src, at: now)
        } else {
            level = .unavailable("Capacity not reported", source: src, at: now)
        }
        let charging = b[kIOPSIsChargingKey] as? Bool
        let state = b[kIOPSPowerSourceStateKey] as? String
        var remaining: HealthMetric<Int> = .unavailable("Not reported", source: src, at: now)
        var kind: TimeRemainingKind?
        if charging == true, let t = b[kIOPSTimeToFullChargeKey] as? Int {
            remaining = t >= 0 ? .reported(t, source: src, at: now) : .unavailable("macOS is still calculating", source: src, at: now)
            kind = .toFull
        } else if state == kIOPSBatteryPowerValue, let t = b[kIOPSTimeToEmptyKey] as? Int {
            remaining = t >= 0 ? .reported(t, source: src, at: now) : .unavailable("macOS is still calculating", source: src, at: now)
            kind = .toEmpty
        } else if state == kIOPSACPowerValue {
            remaining = .unavailable("On power adapter", source: src, at: now)
        }

        let condition: HealthMetric<String>
        if let c = profiler?.condition {
            condition = .reported(c, source: sp, at: now)
        } else if let c = b[kIOPSBatteryHealthKey] as? String {
            condition = .reported(c, source: src, at: now)
        } else {
            condition = .unavailable(profiler?.error ?? "Not reported by macOS", source: sp, at: now)
        }
        let reason = profiler?.error ?? "Not reported by macOS"
        return BatteryHealth(
            present: .reported(true, source: src, at: now), levelPercent: level,
            isCharging: charging.map { HealthMetric<Bool>.reported($0, source: src, at: now) } ?? .unavailable("Not reported", source: src, at: now),
            powerSource: state.map { HealthMetric<String>.reported($0, source: src, at: now) } ?? .unavailable("Not reported", source: src, at: now),
            timeRemainingMinutes: remaining, timeRemainingKind: kind, condition: condition,
            cycleCount: profiler?.cycleCount.map { HealthMetric<Int>.reported($0, source: sp, at: now) } ?? .unavailable(reason, source: sp, at: now),
            maximumCapacityPercent: profiler?.maximumCapacityPercent.map { HealthMetric<Int>.reported($0, source: sp, at: now) } ?? .unavailable(reason, source: sp, at: now))
    }

    // MARK: Storage

    static func storage(now: Date) -> HealthMetric<[VolumeUsage]> {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey,
                                      .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return .unavailable("Mounted volumes could not be listed", source: "FileManager.mountedVolumeURLs", at: now)
        }
        var volumes: [VolumeUsage] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  // Read-only volumes (mounted disk images, discs) can't fill up, so they aren't storage health.
                  v.volumeIsReadOnly != true || v.volumeIsRootFileSystem == true,
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            volumes.append(VolumeUsage(name: v.volumeName ?? url.lastPathComponent, mountPoint: url.path, totalBytes: Int64(total),
                                       availableBytes: available, isRoot: v.volumeIsRootFileSystem ?? false, isInternal: v.volumeIsInternal,
                                       fileSystem: v.volumeLocalizedFormatDescription))
        }
        volumes.sort { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
        return .reported(volumes, source: "URLResourceValues (available for important usage)", at: now)
    }

    static func cString(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Memory

    static func pageSize() -> UInt64 {
        var size: vm_size_t = 0
        return host_page_size(mach_host_self(), &size) == KERN_SUCCESS ? UInt64(size) : UInt64(getpagesize())
    }

    static func memory(now: Date, pressure: MemoryPressureMonitor?) -> MemoryHealth {
        let src = "host_statistics64 (HOST_VM_INFO64)"
        let physical: HealthMetric<UInt64> = .reported(ProcessInfo.processInfo.physicalMemory, source: "ProcessInfo.physicalMemory", at: now)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        var swap: HealthMetric<UInt64> = .unavailable("Not reported", source: "sysctl vm.swapusage", at: now)
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 { swap = .reported(xsw.xsu_used, source: "sysctl vm.swapusage", at: now) }

        let pressureMetric: HealthMetric<String>
        if let (level, since) = pressure?.current, let level {
            pressureMetric = .reported(level, source: "DispatchSource memory-pressure events (last event \(Timestamp.string(from: since)))", at: now)
        } else if pressure != nil {
            pressureMetric = .estimated("normal", note: "No memory-pressure events since MyBuddy started", source: "DispatchSource memory-pressure events", at: now)
        } else {
            pressureMetric = .unavailable("Monitor not running", source: "DispatchSource memory-pressure events", at: now)
        }
        guard kr == KERN_SUCCESS else {
            let u = "host_statistics64 failed (\(kr))"
            return MemoryHealth(physicalBytes: physical, usedBytes: .unavailable(u, source: src, at: now), compressedBytes: .unavailable(u, source: src, at: now),
                                wiredBytes: .unavailable(u, source: src, at: now), swapUsedBytes: swap, pressure: pressureMetric)
        }
        let page = pageSize()
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let app = (UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))) * page
        return MemoryHealth(physicalBytes: physical,
                            usedBytes: .derived(app + wired + compressed, formula: "(internal − purgeable) + wired + compressed pages × page size", source: src, at: now),
                            compressedBytes: .reported(compressed, source: src, at: now), wiredBytes: .reported(wired, source: src, at: now),
                            swapUsedBytes: swap, pressure: pressureMetric)
    }

    // MARK: CPU

    static func cpuTicks() -> (busy: UInt64, total: UInt64, cores: Int)? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * cpu
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total, Int(cpuCount))
    }

    static func processCPUTime() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func processFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func sampleCPU(interval: TimeInterval) async -> CPUHealth {
        let src = "host_processor_info (PROCESSOR_CPU_LOAD_INFO)"
        let first = cpuTicks()
        let cpu0 = processCPUTime()
        let wall0 = Date()
        try? await Task.sleep(for: .seconds(interval))
        let now = Date()
        let second = cpuTicks()
        let elapsed = now.timeIntervalSince(wall0)
        let cores = ProcessInfo.processInfo.activeProcessorCount

        var system: HealthMetric<Double> = .unavailable("CPU counters unavailable", source: src, at: now)
        if let a = first, let b = second, b.total > a.total {
            let pct = Double(b.busy - a.busy) / Double(b.total - a.total) * 100
            system = .derived((pct * 10).rounded() / 10, formula: "Δbusy ticks ÷ Δtotal ticks over \(String(format: "%.1f", elapsed)) s, all cores", source: src, at: now)
        }
        var loads = [Double](repeating: 0, count: 3)
        let load: HealthMetric<[Double]> = getloadavg(&loads, 3) == 3 ? .reported(loads, source: "getloadavg", at: now) : .unavailable("Not reported", source: "getloadavg", at: now)
        let appPct = elapsed > 0 ? (processCPUTime() - cpu0) / elapsed * 100 : 0
        return CPUHealth(logicalCores: .reported(cores, source: "ProcessInfo.activeProcessorCount", at: now), systemUsagePercent: system,
                         loadAverage: load,
                         appProcessUsagePercent: .derived((appPct * 10).rounded() / 10, formula: "Δ(user+system CPU time) ÷ Δwall time, % of one core", source: "getrusage(RUSAGE_SELF)", at: now),
                         appProcessMemoryBytes: processFootprint().map { .reported($0, source: "task_info (TASK_VM_INFO phys_footprint)", at: now) }
                            ?? .unavailable("Not reported", source: "task_info", at: now))
    }

    // MARK: Thermal & system

    static func thermal(now: Date) -> ThermalHealth {
        let state: String = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        return ThermalHealth(thermalState: .reported(state, source: "ProcessInfo.thermalState", at: now),
                             temperatures: .unavailable("Apple Silicon exposes no supported public API for CPU/GPU temperatures or fan speed", source: "—", at: now))
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return cString(buffer)
    }

    static func system(now: Date) -> SystemInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let build = sysctlString("kern.osversion")
        let os = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" + (build.map { " (\($0))" } ?? "")
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        let uptime: HealthMetric<Int64> = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0
            ? .reported(Int64(now.timeIntervalSince1970) - Int64(boot.tv_sec), source: "sysctl kern.boottime", at: now)
            : .unavailable("Not reported", source: "sysctl kern.boottime", at: now)
        var hostBuffer = [CChar](repeating: 0, count: 256)
        let hostName: HealthMetric<String> = gethostname(&hostBuffer, 255) == 0
            ? .reported(cString(hostBuffer), source: "gethostname", at: now)
            : .unavailable("Not reported", source: "gethostname", at: now)
        return SystemInfo(osVersion: .reported(os, source: "ProcessInfo.operatingSystemVersion + sysctl kern.osversion", at: now),
                          modelIdentifier: sysctlString("hw.model").map { .reported($0, source: "sysctl hw.model", at: now) } ?? .unavailable("Not reported", source: "sysctl hw.model", at: now),
                          chip: sysctlString("machdep.cpu.brand_string").map { .reported($0, source: "sysctl machdep.cpu.brand_string", at: now) } ?? .unavailable("Not reported", source: "sysctl", at: now),
                          uptimeSeconds: uptime, hostName: hostName)
    }

    // MARK: Network

    static func network() async -> NetworkHealth {
        let src = "Network.framework NWPathMonitor"
        let path = await currentPath(timeout: 1.5)
        let now = Date()
        var kinds: [String: String] = [:]
        if let path {
            for iface in path.availableInterfaces {
                kinds[iface.name] = switch iface.type {
                case .wifi: "Wi-Fi"
                case .wiredEthernet: "Ethernet"
                case .cellular: "Cellular"
                case .loopback: "Loopback"
                default: "Other"
                }
            }
        }
        let interfaces = interfaceAddresses().map { NetworkInterfaceInfo(name: $0.key, kind: kinds[$0.key] ?? "Other", addresses: $0.value) }
            .sorted { $0.name < $1.name }
        guard let path else {
            let u = "No path update within 1.5 s"
            return NetworkHealth(pathStatus: .unavailable(u, source: src, at: now), interfaces: .reported(interfaces, source: "getifaddrs", at: now),
                                 isExpensive: .unavailable(u, source: src, at: now), isConstrained: .unavailable(u, source: src, at: now))
        }
        let status: String = switch path.status {
        case .satisfied: "connected"
        case .unsatisfied: "no connection"
        case .requiresConnection: "requires connection"
        @unknown default: "unknown"
        }
        return NetworkHealth(pathStatus: .reported(status, source: src, at: now), interfaces: .reported(interfaces, source: "getifaddrs + NWPathMonitor", at: now),
                             isExpensive: .reported(path.isExpensive, source: src, at: now), isConstrained: .reported(path.isConstrained, source: src, at: now))
    }

    static func currentPath(timeout: TimeInterval) async -> NWPath? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NWPath?, Never>) in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "app.mybuddy.path")
            let once = OnceFlag()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    /// Up, non-loopback interfaces with their IPv4/IPv6 addresses (link-local IPv6 omitted).
    public static func interfaceAddresses() -> [String: [String]] {
        var result: [String: [String]] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = ifa.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == UInt8(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = cString(host)
            if address.hasPrefix("fe80") { continue }
            result[String(validatingCString: ifa.pointee.ifa_name) ?? "?", default: []].append(address)
        }
        return result
    }

    /// LAN IPv4 addresses suitable for the pairing QR code.
    /// Private IPv4 addresses a phone on the same network can dial, best first (see `orderedLANAddresses`).
    public static func lanIPv4Addresses() -> [String] {
        orderedLANAddresses(interfaceAddresses(), primaryInterface: primaryInterfaceName())
    }

    /// The interface carrying the default route leads, then other Wi-Fi/Ethernet (`en*`), then bridges
    /// (Internet Sharing, virtual machines) — a phone on the Wi-Fi should not wait out timeouts on a
    /// bridge address before reaching the right one.
    public static func orderedLANAddresses(_ byInterface: [String: [String]], primaryInterface: String?) -> [String] {
        func rank(_ name: String) -> Int { name == primaryInterface ? 0 : name.hasPrefix("en") ? 1 : 2 }
        var seen = Set<String>()
        return byInterface.filter { $0.key.hasPrefix("en") || $0.key.hasPrefix("bridge") }
            .sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
            .flatMap { $0.value.filter { !$0.contains(":") }.sorted() }
            .filter { EndpointValidator.classify(host: $0) == .privateNetwork && seen.insert($0).inserted }
    }

    /// The primary network interface (e.g. `en0`) from the system's network state.
    public static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "MyBuddy" as CFString, nil, nil),
              let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return state["PrimaryInterface"] as? String
    }
}
