import AppKit
import CoreMedia
import CoreVideo
import Foundation
import MyBuddyCore
@preconcurrency import ScreenCaptureKit

/// Captures a display with ScreenCaptureKit, scaled by the window server to the tier's size, as
/// NV12 full-range buffers (what the VideoToolbox H.264 encoder consumes without conversion).
///
/// ScreenCaptureKit only delivers a frame when the screen changes. A static screen would leave a
/// newly connected decoder waiting for its first keyframe, so the last frame is re-sent every
/// 250 ms while nothing changes.
public final class ScreenCaptureKitSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.mybuddy.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var onFrame: (@Sendable (CapturedFrame) -> Void)?
    private var onStop: (@Sendable (String) -> Void)?
    private var lastBuffer: CVPixelBuffer?
    private var lastDeliveredNs: Int64 = 0
    private var repeater: (any DispatchSourceTimer)?
    private var stopping = false
    /// Content chosen at the Mac with the system picker; overrides display selection while set.
    private var pickedFilter: SCContentFilter?

    public override init() { super.init() }

    // MARK: FrameSource

    public func start(_ request: FrameSourceRequest, onFrame: @escaping @Sendable (CapturedFrame) -> Void,
                      onStop: @escaping @Sendable (String) -> Void) async throws -> FrameSourceInfo {
        let (filter, info, config) = try await plan(request)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            throw Self.map(error)
        }
        lock.withLock {
            self.stream = stream
            self.onFrame = onFrame
            self.onStop = onStop
            stopping = false
        }
        startRepeater()
        return info
    }

    public func reconfigure(_ request: FrameSourceRequest) async throws -> FrameSourceInfo {
        guard let stream = lock.withLock({ self.stream }) else { throw FrameSourceError.failed("Capture is not running.") }
        let (filter, info, config) = try await plan(request)
        do {
            try await stream.updateContentFilter(filter)
            try await stream.updateConfiguration(config)
        } catch {
            throw Self.map(error)
        }
        lock.withLock { lastBuffer = nil }
        return info
    }

    public func stop() async {
        let (stream, timer) = lock.withLock { () -> (SCStream?, (any DispatchSourceTimer)?) in
            stopping = true
            defer {
                self.stream = nil
                repeater = nil
                onFrame = nil
                onStop = nil
                lastBuffer = nil
            }
            return (self.stream, repeater)
        }
        timer?.cancel()
        try? await stream?.stopCapture()
    }

    /// Uses content the user picked at the Mac (system picker). `nil` returns to display capture.
    public func setPickedContent(_ filter: SCContentFilter?) {
        lock.withLock { pickedFilter = filter }
    }

    // MARK: Planning

    private func plan(_ request: FrameSourceRequest) async throws -> (SCContentFilter, FrameSourceInfo, SCStreamConfiguration) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.map(error)
        }
        guard !content.displays.isEmpty else { throw FrameSourceError.noDisplay }
        let names = await Self.displayNames()
        let mainId = CGMainDisplayID()
        let displays = content.displays.map { d in
            let scale = Self.pixelScale(d.displayID)
            return StreamDisplay(id: String(d.displayID), name: names[d.displayID] ?? "Display \(d.displayID)",
                                 width: Int(Double(d.width) * scale), height: Int(Double(d.height) * scale), isMain: d.displayID == mainId)
        }

        let filter: SCContentFilter
        let kind: StreamSourceKind
        var displayId: String?
        if let picked = lock.withLock({ pickedFilter }) {
            filter = picked
            kind = picked.style == .window ? .window : picked.style == .application ? .application : .display
        } else {
            let target = request.displayId.flatMap { id in content.displays.first { String($0.displayID) == id } }
                ?? content.displays.first { $0.displayID == mainId } ?? content.displays[0]
            filter = SCContentFilter(display: target, excludingApplications: [], exceptingWindows: [])
            kind = .display
            displayId = String(target.displayID)
        }
        let scale = Double(filter.pointPixelScale)
        let pixels = (width: Int(filter.contentRect.width * scale), height: Int(filter.contentRect.height * scale))
        let dims = StreamGeometry.fit(sourceWidth: pixels.width, sourceHeight: pixels.height, box: request.tier.box)
        let fps = StreamGeometry.fps(tier: request.tier, maxFps: request.maxFps)

        let config = SCStreamConfiguration()
        config.width = dims.width
        config.height = dims.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 3  // fewer frames in flight = less delay; 3 is enough for 60 fps encoding
        config.capturesAudio = false
        return (filter, FrameSourceInfo(source: kind, displayId: displayId, dimensions: dims, fps: fps, displays: displays), config)
    }

    private static func pixelScale(_ id: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    @MainActor
    private static func displayNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[n.uint32Value] = screen.localizedName
            }
        }
        return names
    }

    static func map(_ error: any Error) -> FrameSourceError {
        if let e = error as? FrameSourceError { return e }
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue { return .notAuthorized }
        if !CGPreflightScreenCaptureAccess() { return .notAuthorized }
        return .failed(ns.localizedDescription)
    }

    // MARK: Frames

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = attachments[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status == .complete,
              let buffer = sampleBuffer.imageBuffer
        else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ns = pts.isValid ? Int64(CMTimeGetSeconds(pts) * 1_000_000_000) : CapturedFrame.nowNs
        deliver(buffer, at: ns)
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let (callback, wasStopping) = lock.withLock { (onStop, stopping) }
        guard !wasStopping else { return }
        let ns = error as NSError
        let message = ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userStopped.rawValue
            ? "Screen sharing was stopped from the Mac’s menu bar."
            : "The Mac stopped screen capture (\(ns.localizedDescription))."
        callback?(message)
    }

    private func deliver(_ buffer: CVPixelBuffer, at ns: Int64) {
        let callback: (@Sendable (CapturedFrame) -> Void)? = lock.withLock {
            lastBuffer = buffer
            lastDeliveredNs = ns
            return onFrame
        }
        callback?(CapturedFrame(pixelBuffer: buffer, timestampNs: ns))
    }

    private func startRepeater() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CapturedFrame.nowNs
            let (buffer, callback): (CVPixelBuffer?, (@Sendable (CapturedFrame) -> Void)?) = self.lock.withLock {
                guard let last = self.lastBuffer, now - self.lastDeliveredNs >= 200_000_000 else { return (nil, nil) }
                self.lastDeliveredNs = now
                return (last, self.onFrame)
            }
            if let buffer { callback?(CapturedFrame(pixelBuffer: buffer, timestampNs: now)) }
        }
        lock.withLock { repeater = timer }
        timer.resume()
    }
}
