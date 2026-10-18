import Foundation

/// Collection status of one metric. Unavailable data is never filled in with guesses.
public enum MetricStatus: Sendable, Equatable, Codable {
    case available
    case estimated(String)
    case unavailable(String)
    case notPermitted(String)

    private enum CodingKeys: String, CodingKey { case state, note }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        switch try c.decode(String.self, forKey: .state) {
        case "available": self = .available
        case "estimated": self = .estimated(note)
        case "notPermitted": self = .notPermitted(note)
        default: self = .unavailable(note)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available: try c.encode("available", forKey: .state)
        case .estimated(let n): try c.encode("estimated", forKey: .state); try c.encode(n, forKey: .note)
        case .unavailable(let n): try c.encode("unavailable", forKey: .state); try c.encode(n, forKey: .note)
        case .notPermitted(let n): try c.encode("notPermitted", forKey: .state); try c.encode(n, forKey: .note)
        }
    }

    public var isUsable: Bool {
        switch self {
        case .available, .estimated: true
        default: false
        }
    }

    public var note: String? {
        switch self {
        case .available: nil
        case .estimated(let n), .unavailable(let n), .notPermitted(let n): n
        }
    }
}

/// Whether a value was read from the OS or computed by MyBuddy.
public enum MetricOrigin: String, Codable, Sendable {
    case osReported
    case derived
}

public struct HealthMetric<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var value: Value?
    public var status: MetricStatus
    public var source: String
    public var origin: MetricOrigin
    public var formula: String?
    public var collectedAt: Date

    public static func reported(_ value: Value, source: String, at date: Date) -> Self {
        Self(value: value, status: .available, source: source, origin: .osReported, formula: nil, collectedAt: date)
    }

    public static func derived(_ value: Value, formula: String, source: String, at date: Date) -> Self {
        Self(value: value, status: .available, source: source, origin: .derived, formula: formula, collectedAt: date)
    }

    public static func estimated(_ value: Value, note: String, source: String, at date: Date) -> Self {
        Self(value: value, status: .estimated(note), source: source, origin: .derived, formula: nil, collectedAt: date)
    }

    public static func unavailable(_ reason: String, source: String, at date: Date) -> Self {
        Self(value: nil, status: .unavailable(reason), source: source, origin: .osReported, formula: nil, collectedAt: date)
    }

    public static func notPermitted(_ reason: String, source: String, at date: Date) -> Self {
        Self(value: nil, status: .notPermitted(reason), source: source, origin: .osReported, formula: nil, collectedAt: date)
    }

    /// The value only when the status allows showing it.
    public var usableValue: Value? { status.isUsable ? value : nil }
}

public enum TimeRemainingKind: String, Codable, Sendable { case toEmpty, toFull }

public struct BatteryHealth: Codable, Sendable, Equatable {
    public var present: HealthMetric<Bool>
    public var levelPercent: HealthMetric<Int>
    public var isCharging: HealthMetric<Bool>
    public var powerSource: HealthMetric<String>
    public var timeRemainingMinutes: HealthMetric<Int>
    public var timeRemainingKind: TimeRemainingKind?
    public var condition: HealthMetric<String>
    public var cycleCount: HealthMetric<Int>
    public var maximumCapacityPercent: HealthMetric<Int>

    public init(present: HealthMetric<Bool>, levelPercent: HealthMetric<Int>, isCharging: HealthMetric<Bool>,
                powerSource: HealthMetric<String>, timeRemainingMinutes: HealthMetric<Int>, timeRemainingKind: TimeRemainingKind?,
                condition: HealthMetric<String>, cycleCount: HealthMetric<Int>, maximumCapacityPercent: HealthMetric<Int>) {
        self.present = present
        self.levelPercent = levelPercent
        self.isCharging = isCharging
        self.powerSource = powerSource
        self.timeRemainingMinutes = timeRemainingMinutes
        self.timeRemainingKind = timeRemainingKind
        self.condition = condition
        self.cycleCount = cycleCount
        self.maximumCapacityPercent = maximumCapacityPercent
    }
}

public struct VolumeUsage: Codable, Sendable, Equatable, Identifiable {
    public var id: String { mountPoint }
    public var name: String
    public var mountPoint: String
    public var totalBytes: Int64
    public var availableBytes: Int64
    public var isRoot: Bool
    public var isInternal: Bool?
    public var fileSystem: String?

    public init(name: String, mountPoint: String, totalBytes: Int64, availableBytes: Int64, isRoot: Bool, isInternal: Bool?, fileSystem: String?) {
        self.name = name
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isRoot = isRoot
        self.isInternal = isInternal
        self.fileSystem = fileSystem
    }

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    public var freeFraction: Double { totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 0 }
}

public struct MemoryHealth: Codable, Sendable, Equatable {
    public var physicalBytes: HealthMetric<UInt64>
    public var usedBytes: HealthMetric<UInt64>
    public var compressedBytes: HealthMetric<UInt64>
    public var wiredBytes: HealthMetric<UInt64>
    public var swapUsedBytes: HealthMetric<UInt64>
    public var pressure: HealthMetric<String>

    public init(physicalBytes: HealthMetric<UInt64>, usedBytes: HealthMetric<UInt64>, compressedBytes: HealthMetric<UInt64>,
                wiredBytes: HealthMetric<UInt64>, swapUsedBytes: HealthMetric<UInt64>, pressure: HealthMetric<String>) {
        self.physicalBytes = physicalBytes
        self.usedBytes = usedBytes
        self.compressedBytes = compressedBytes
        self.wiredBytes = wiredBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }
}

public struct CPUHealth: Codable, Sendable, Equatable {
    public var logicalCores: HealthMetric<Int>
    public var systemUsagePercent: HealthMetric<Double>
    public var loadAverage: HealthMetric<[Double]>
    public var appProcessUsagePercent: HealthMetric<Double>
    public var appProcessMemoryBytes: HealthMetric<UInt64>

    public init(logicalCores: HealthMetric<Int>, systemUsagePercent: HealthMetric<Double>, loadAverage: HealthMetric<[Double]>,
                appProcessUsagePercent: HealthMetric<Double>, appProcessMemoryBytes: HealthMetric<UInt64>) {
        self.logicalCores = logicalCores
        self.systemUsagePercent = systemUsagePercent
        self.loadAverage = loadAverage
        self.appProcessUsagePercent = appProcessUsagePercent
        self.appProcessMemoryBytes = appProcessMemoryBytes
    }
}

public struct ThermalHealth: Codable, Sendable, Equatable {
    public var thermalState: HealthMetric<String>
    /// Always unavailable: Apple Silicon exposes no supported public API for temperatures or fan RPM.
    public var temperatures: HealthMetric<String>

    public init(thermalState: HealthMetric<String>, temperatures: HealthMetric<String>) {
        self.thermalState = thermalState
        self.temperatures = temperatures
    }
}

public struct SystemInfo: Codable, Sendable, Equatable {
    public var osVersion: HealthMetric<String>
    public var modelIdentifier: HealthMetric<String>
    public var chip: HealthMetric<String>
    public var uptimeSeconds: HealthMetric<Int64>
    public var hostName: HealthMetric<String>

    public init(osVersion: HealthMetric<String>, modelIdentifier: HealthMetric<String>, chip: HealthMetric<String>,
                uptimeSeconds: HealthMetric<Int64>, hostName: HealthMetric<String>) {
        self.osVersion = osVersion
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.uptimeSeconds = uptimeSeconds
        self.hostName = hostName
    }
}

public struct NetworkInterfaceInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var kind: String
    public var addresses: [String]

    public init(name: String, kind: String, addresses: [String]) {
        self.name = name
        self.kind = kind
        self.addresses = addresses
    }
}

public struct NetworkHealth: Codable, Sendable, Equatable {
    public var pathStatus: HealthMetric<String>
    public var interfaces: HealthMetric<[NetworkInterfaceInfo]>
    public var isExpensive: HealthMetric<Bool>
    public var isConstrained: HealthMetric<Bool>

    public init(pathStatus: HealthMetric<String>, interfaces: HealthMetric<[NetworkInterfaceInfo]>, isExpensive: HealthMetric<Bool>, isConstrained: HealthMetric<Bool>) {
        self.pathStatus = pathStatus
        self.interfaces = interfaces
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

public struct HostDiagnostics: Codable, Sendable, Equatable {
    public var appVersion: String
    public var lanListener: HealthMetric<String>
    public var trustedDevices: Int
    public var activeSessions: Int

    public init(appVersion: String, lanListener: HealthMetric<String>, trustedDevices: Int, activeSessions: Int) {
        self.appVersion = appVersion
        self.lanListener = lanListener
        self.trustedDevices = trustedDevices
        self.activeSessions = activeSessions
    }
}

public struct HealthSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var collectedAt: Date
    public var collectionDurationMs: Int
    /// True only for Preview/Demo data. Production snapshots are always false.
    public var isPreviewData: Bool
    public var battery: BatteryHealth
    public var storage: HealthMetric<[VolumeUsage]>
    public var memory: MemoryHealth
    public var cpu: CPUHealth
    public var thermal: ThermalHealth
    public var system: SystemInfo
    public var network: NetworkHealth
    public var host: HostDiagnostics

    public init(collectedAt: Date, collectionDurationMs: Int, isPreviewData: Bool, battery: BatteryHealth, storage: HealthMetric<[VolumeUsage]>,
                memory: MemoryHealth, cpu: CPUHealth, thermal: ThermalHealth, system: SystemInfo, network: NetworkHealth, host: HostDiagnostics) {
        schemaVersion = Self.currentSchemaVersion
        self.collectedAt = collectedAt
        self.collectionDurationMs = collectionDurationMs
        self.isPreviewData = isPreviewData
        self.battery = battery
        self.storage = storage
        self.memory = memory
        self.cpu = cpu
        self.thermal = thermal
        self.system = system
        self.network = network
        self.host = host
    }

    public var rootVolume: VolumeUsage? { storage.usableValue?.first(where: \.isRoot) }
}

// MARK: - Explainable assessment (instead of an opaque score)

public struct HealthFinding: Sendable, Equatable, Identifiable {
    public enum Level: Int, Sendable, Comparable {
        case ok, info, attention, critical
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { area + title }
    public let area: String
    public let level: Level
    public let title: String
    public let rule: String
}

/// Turns a snapshot into findings, each with the exact rule used. No hidden weighting.
public enum HealthAssessment {
    public static func findings(for s: HealthSnapshot) -> [HealthFinding] {
        var out: [HealthFinding] = []
        if let root = s.rootVolume {
            let free = root.freeFraction
            let level: HealthFinding.Level = free < 0.05 ? .critical : free < 0.15 ? .attention : .ok
            out.append(HealthFinding(area: "Storage", level: level, title: "\(Int((free * 100).rounded()))% free on \(root.name)",
                                     rule: "critical < 5% free, attention < 15% free (available-for-important-usage ÷ total)"))
        }
        if let condition = s.battery.condition.usableValue {
            let normal = ["normal", "good"].contains(condition.lowercased())
            out.append(HealthFinding(area: "Battery", level: normal ? .ok : .attention, title: "Condition: \(condition)",
                                     rule: "OS-reported condition; anything other than Normal/Good needs attention"))
        }
        if let pressure = s.memory.pressure.usableValue {
            let level: HealthFinding.Level = pressure == "critical" ? .critical : pressure == "warning" ? .attention : .ok
            out.append(HealthFinding(area: "Memory", level: level, title: "Pressure \(pressure)", rule: "OS memory-pressure level"))
        }
        if let thermal = s.thermal.thermalState.usableValue {
            let level: HealthFinding.Level = thermal == "critical" ? .critical : thermal == "serious" ? .attention : thermal == "fair" ? .info : .ok
            out.append(HealthFinding(area: "Thermal", level: level, title: "State \(thermal)", rule: "ProcessInfo.thermalState as reported by macOS"))
        }
        return out.sorted { $0.level > $1.level }
    }
}
