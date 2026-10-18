import Foundation

/// Quality the phone asks for (`screen.start` / `screen.update`). `auto` lets the host move between tiers.
public enum StreamQuality: String, Sendable, CaseIterable, Codable {
    case auto, smooth, high, balanced, low

    /// The tier a stream starts at.
    public var initialTier: StreamTier {
        switch self {
        case .auto, .balanced: .balanced
        case .smooth: .smooth
        case .high: .high
        case .low: .low
        }
    }
}

/// A concrete encoding tier: output box, frame rate and bitrate ceiling. Targets, not guarantees —
/// WebRTC congestion control can always send less.
public enum StreamTier: String, Sendable, CaseIterable, Codable, Comparable {
    /// `smooth` is a fixed choice for interaction (60 fps at 1280×800); `auto` moves along low → balanced → high.
    case low, balanced, smooth, high

    /// The captured frame is scaled to fit this box (pixels), never upscaled.
    public var box: (width: Int, height: Int) {
        switch self {
        case .low: (960, 600)
        case .balanced, .smooth: (1280, 800)
        case .high: (1920, 1200)
        }
    }

    public var fps: Int {
        switch self {
        case .low: 15
        case .balanced, .high: 30
        case .smooth: 60
        }
    }

    public var maxBitrateBps: Int {
        switch self {
        case .low: 800_000
        case .balanced: 2_500_000
        case .smooth: 5_000_000
        case .high: 6_000_000
        }
    }

    public var lower: StreamTier? {
        switch self {
        case .low: nil
        case .balanced: .low
        case .smooth, .high: .balanced
        }
    }

    /// The next step up the auto ladder (`smooth` is never reached automatically).
    public var higher: StreamTier? {
        switch self {
        case .low: .balanced
        case .balanced: .high
        case .smooth, .high: nil
        }
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .balanced: 1
        case .smooth: 2
        case .high: 3
        }
    }

    public static func < (a: StreamTier, b: StreamTier) -> Bool { a.rank < b.rank }
}

public struct StreamDimensions: Sendable, Equatable, CustomStringConvertible {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)×\(height)" }
}

public enum StreamGeometry {
    /// Scales a `sourceWidth`×`sourceHeight` pixel source to fit `box`, keeping the aspect ratio, never
    /// upscaling, with even dimensions (4:2:0 video needs them) of at least 2×2.
    public static func fit(sourceWidth: Int, sourceHeight: Int, box: (width: Int, height: Int)) -> StreamDimensions {
        let sw = max(2, sourceWidth), sh = max(2, sourceHeight)
        let scale = min(1, min(Double(box.width) / Double(sw), Double(box.height) / Double(sh)))
        func even(_ v: Double) -> Int { max(2, Int(v.rounded(.down)) & ~1) }
        return StreamDimensions(width: even(Double(sw) * scale), height: even(Double(sh) * scale))
    }

    /// Frame rate actually used: the tier's rate, lowered further by an explicit phone cap.
    public static func fps(tier: StreamTier, maxFps: Int?) -> Int {
        guard let maxFps else { return tier.fps }
        return max(1, min(tier.fps, maxFps))
    }
}

/// A display the phone may choose (`screen.state.displays`). Names are what macOS calls the display;
/// no serial numbers or other hardware identifiers are sent.
public struct StreamDisplay: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let width: Int
    public let height: Int
    public let isMain: Bool

    public init(id: String, name: String, width: Int, height: Int, isMain: Bool) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.isMain = isMain
    }

    var payload: JSONValue {
        .object(["displayId": .string(String(id.prefix(32))), "name": .string(String(name.prefix(64)).isEmpty ? "Display" : String(name.prefix(64))),
                 "width": .int(Int64(min(max(width, 1), 16384))), "height": .int(Int64(min(max(height, 1), 16384))), "main": .bool(isMain)])
    }
}

/// What is being captured.
public enum StreamSourceKind: String, Sendable, Equatable {
    case display, window, application
    /// Synthetic frames from the test-only interop host. Never produced by MyBuddy.app.
    case testPattern = "test_pattern"
}

/// The host's stream lifecycle, mirrored to the phone as `screen.state`.
public enum ScreenStreamPhase: String, Sendable, Equatable {
    case starting
    case awaitingSelection = "awaiting_selection"
    case live, stopped, failed
}

/// Well-known `screen.state.reason` values (the field is an open snake_case string so new reasons
/// stay compatible with older phones, which fall back to `message`).
public enum ScreenStreamReason {
    public static let notAuthorized = "not_authorized"
    public static let busy = "busy"
    public static let noDisplay = "no_display"
    public static let captureFailed = "capture_failed"
    public static let captureStopped = "capture_stopped"
    public static let connectionFailed = "connection_failed"
    public static let negotiationFailed = "negotiation_failed"
    public static let stoppedOnMac = "stopped_on_mac"
    public static let emergencyStop = "emergency_stop"
    public static let replaced = "replaced"
    public static let selectionCancelled = "selection_cancelled"
    public static let user = "user"
    public static let background = "background"
    public static let qualityChanged = "quality_changed"
}

/// One `screen.state` message.
public struct ScreenStreamStatus: Sendable, Equatable {
    public var phase: ScreenStreamPhase
    public var reason: String?
    public var message: String?
    public var quality: StreamQuality?
    public var tier: StreamTier?
    public var displayId: String?
    public var dimensions: StreamDimensions?
    public var fps: Int?
    public var source: StreamSourceKind?
    public var displays: [StreamDisplay]

    public init(phase: ScreenStreamPhase, reason: String? = nil, message: String? = nil, quality: StreamQuality? = nil, tier: StreamTier? = nil,
                displayId: String? = nil, dimensions: StreamDimensions? = nil, fps: Int? = nil, source: StreamSourceKind? = nil,
                displays: [StreamDisplay] = []) {
        self.phase = phase
        self.reason = reason
        self.message = message
        self.quality = quality
        self.tier = tier
        self.displayId = displayId
        self.dimensions = dimensions
        self.fps = fps
        self.source = source
        self.displays = displays
    }

    /// The `screen.state` payload, clamped to the catalog limits.
    public var payload: [String: JSONValue] {
        var p: [String: JSONValue] = ["state": .string(phase.rawValue)]
        if let reason, !reason.isEmpty, reason.count <= 64,
           reason.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }) {
            p["reason"] = .string(reason)
        }
        if let message { p["message"] = .string(String(message.prefix(300))) }
        if let quality { p["quality"] = .string(quality.rawValue) }
        if let tier { p["tier"] = .string(tier.rawValue) }
        if let displayId { p["displayId"] = .string(String(displayId.prefix(32))) }
        if let d = dimensions, d.width >= 2, d.height >= 2 {
            p["width"] = .int(Int64(min(d.width, 8192)))
            p["height"] = .int(Int64(min(d.height, 8192)))
        }
        if let fps { p["fps"] = .int(Int64(min(max(fps, 1), 60))) }
        if let source { p["source"] = .string(source.rawValue) }
        if !displays.isEmpty { p["displays"] = .array(displays.prefix(16).map(\.payload)) }
        return p
    }
}

/// Why the encoder is sending less than it could (`outbound-rtp.qualityLimitationReason`).
public enum QualityLimitation: String, Sendable, Equatable {
    case none, bandwidth, cpu, other
}

/// Moves an `auto` stream between tiers using the sender's own statistics, with hysteresis so the
/// picture does not flap: step down after 4 s of sustained limitation, step up after 20 s of headroom,
/// and hold every change for at least 10 s. Fixed-quality streams never change tier.
public struct AdaptiveQualityController: Sendable {
    public private(set) var tier: StreamTier
    public let quality: StreamQuality
    private var limitedSamples = 0
    private var headroomSamples = 0
    private var holdSamples = 0

    public static let downAfter = 4
    public static let upAfter = 20
    public static let holdAfterChange = 10

    /// `startTier` overrides where an `auto` stream begins (e.g. `high` on a direct local path, stepping down on
    /// limitation instead of climbing for 20 s); fixed qualities always start at their own tier.
    public init(quality: StreamQuality, startTier: StreamTier? = nil) {
        self.quality = quality
        tier = quality == .auto ? (startTier ?? quality.initialTier) : quality.initialTier
    }

    /// Feed one sample per second. Returns the new tier when it should change.
    public mutating func observe(limitation: QualityLimitation, availableOutgoingBitrateBps: Double?) -> StreamTier? {
        guard quality == .auto else { return nil }
        if holdSamples > 0 {
            holdSamples -= 1
            return nil
        }
        switch limitation {
        case .bandwidth, .cpu:
            headroomSamples = 0
            limitedSamples += 1
            if limitedSamples >= Self.downAfter, let lower = tier.lower { return change(to: lower) }
        case .none:
            limitedSamples = 0
            guard let higher = tier.higher else { return nil }
            // Only climb when the network estimate (if known) clearly fits the next tier.
            let fits = availableOutgoingBitrateBps.map { $0 >= Double(higher.maxBitrateBps) * 1.2 } ?? true
            headroomSamples = fits ? headroomSamples + 1 : 0
            if headroomSamples >= Self.upAfter { return change(to: higher) }
        case .other:
            break
        }
        return nil
    }

    private mutating func change(to new: StreamTier) -> StreamTier {
        tier = new
        limitedSamples = 0
        headroomSamples = 0
        holdSamples = Self.holdAfterChange
        return new
    }
}
