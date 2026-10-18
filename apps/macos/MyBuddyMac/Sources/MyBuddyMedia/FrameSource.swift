import CoreMedia
import CoreVideo
import Foundation
import MyBuddyCore

/// A frame handed to the encoder. `timestampNs` is host time (the clock libwebrtc uses on macOS).
public struct CapturedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let timestampNs: Int64

    public init(pixelBuffer: CVPixelBuffer, timestampNs: Int64) {
        self.pixelBuffer = pixelBuffer
        self.timestampNs = timestampNs
    }

    /// Now, on the host clock.
    public static var nowNs: Int64 {
        Int64(CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1_000_000_000)
    }
}

/// What the stream should capture and how large.
public struct FrameSourceRequest: Sendable, Equatable {
    public var displayId: String?
    public var tier: StreamTier
    public var maxFps: Int?

    public init(displayId: String? = nil, tier: StreamTier, maxFps: Int? = nil) {
        self.displayId = displayId
        self.tier = tier
        self.maxFps = maxFps
    }
}

/// What the source is actually producing.
public struct FrameSourceInfo: Sendable, Equatable {
    public var source: StreamSourceKind
    public var displayId: String?
    public var dimensions: StreamDimensions
    public var fps: Int
    public var displays: [StreamDisplay]

    public init(source: StreamSourceKind, displayId: String?, dimensions: StreamDimensions, fps: Int, displays: [StreamDisplay]) {
        self.source = source
        self.displayId = displayId
        self.dimensions = dimensions
        self.fps = fps
        self.displays = displays
    }
}

public enum FrameSourceError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Screen Recording is not allowed for this app (System Settings → Privacy & Security).
    case notAuthorized
    case noDisplay
    case failed(String)

    public var description: String {
        switch self {
        case .notAuthorized: "Screen Recording is not allowed for MyBuddy on this Mac."
        case .noDisplay: "No display is available to capture."
        case .failed(let why): why
        }
    }
}

/// Produces frames for one stream. Implementations: `ScreenCaptureKitSource` (the app) and the
/// test-only `TestPatternSource` (interop host and tests, never linked into MyBuddy.app).
public protocol FrameSource: AnyObject, Sendable {
    /// Starts capturing. `onFrame` and `onStop` may be called on any queue; `onStop` reports a capture
    /// that ended on its own (display unplugged, permission revoked, stopped from the system menu).
    func start(_ request: FrameSourceRequest, onFrame: @escaping @Sendable (CapturedFrame) -> Void,
               onStop: @escaping @Sendable (String) -> Void) async throws -> FrameSourceInfo
    /// Applies a new size / frame rate / display to the running capture.
    func reconfigure(_ request: FrameSourceRequest) async throws -> FrameSourceInfo
    func stop() async
}
