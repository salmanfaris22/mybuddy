import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import MyBuddyCore
import MyBuddyMedia

/// Test-only frame source: a clearly labelled synthetic picture ("TEST PATTERN — not a screen capture")
/// with corner markers, a moving bar and a frame counter. It exercises the real encode → WebRTC →
/// decode → render path without Screen Recording permission. Never linked into MyBuddy.app.
public final class TestPatternSource: FrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.mybuddy.test-pattern", qos: .userInteractive)
    private let native: (width: Int, height: Int)
    private var timer: (any DispatchSourceTimer)?
    private var pool: CVPixelBufferPool?
    private var dimensions = StreamDimensions(width: 2, height: 2)
    private var fps = 30
    private var frameIndex = 0
    private var onFrame: (@Sendable (CapturedFrame) -> Void)?
    public private(set) var framesProduced = 0

    /// `nativeWidth`×`nativeHeight` plays the role of the display's pixel size (default: a 13" Retina panel).
    public init(nativeWidth: Int = 2560, nativeHeight: Int = 1600) {
        native = (nativeWidth, nativeHeight)
    }

    public func start(_ request: FrameSourceRequest, onFrame: @escaping @Sendable (CapturedFrame) -> Void,
                      onStop: @escaping @Sendable (String) -> Void) async throws -> FrameSourceInfo {
        let info = apply(request)
        lock.withLock { self.onFrame = onFrame }
        restartTimer()
        return info
    }

    public func reconfigure(_ request: FrameSourceRequest) async throws -> FrameSourceInfo {
        let info = apply(request)
        restartTimer()
        return info
    }

    public func stop() async {
        let t = lock.withLock { () -> (any DispatchSourceTimer)? in
            defer {
                timer = nil
                onFrame = nil
            }
            return timer
        }
        t?.cancel()
    }

    private func apply(_ request: FrameSourceRequest) -> FrameSourceInfo {
        let dims = StreamGeometry.fit(sourceWidth: native.width, sourceHeight: native.height, box: request.tier.box)
        let rate = StreamGeometry.fps(tier: request.tier, maxFps: request.maxFps)
        var newPool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: dims.width,
            kCVPixelBufferHeightKey as String: dims.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
        lock.withLock {
            dimensions = dims
            fps = rate
            pool = newPool
        }
        let display = StreamDisplay(id: "test", name: "Test pattern", width: native.width, height: native.height, isMain: true)
        return FrameSourceInfo(source: .testPattern, displayId: "test", dimensions: dims, fps: rate, displays: [display])
    }

    private func restartTimer() {
        let rate = lock.withLock { fps }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / rate))
        t.setEventHandler { [weak self] in self?.tick() }
        let old = lock.withLock { () -> (any DispatchSourceTimer)? in
            defer { timer = t }
            return timer
        }
        old?.cancel()
        t.resume()
    }

    private func tick() {
        let (pool, dims, index, callback) = lock.withLock { () -> (CVPixelBufferPool?, StreamDimensions, Int, (@Sendable (CapturedFrame) -> Void)?) in
            frameIndex += 1
            return (self.pool, dimensions, frameIndex, onFrame)
        }
        guard let pool, let callback else { return }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let buffer = out else { return }
        Self.draw(into: buffer, size: dims, frame: index)
        lock.withLock { framesProduced += 1 }
        callback(CapturedFrame(pixelBuffer: buffer, timestampNs: CapturedFrame.nowNs))
    }

    static func draw(into buffer: CVPixelBuffer, size: StreamDimensions, frame: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base, width: size.width, height: size.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let w = CGFloat(size.width), h = CGFloat(size.height)
        // Flip to a top-left origin so the labels read like a screen.
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        ctx.setFillColor(color(0x0A0C10))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(color(0x27303B))
        ctx.setLineWidth(1)
        let step = max(16, w / 24)
        var x: CGFloat = 0
        while x < w { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h)); x += step }
        var y: CGFloat = 0
        while y < h { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y)); y += step }
        ctx.strokePath()
        // A bar sweeping left → right once every 4 s at 30 fps makes motion and frame drops visible.
        let barX = CGFloat(frame % 120) / 120 * w
        ctx.setFillColor(color(0xB8F36B, 0.85))
        ctx.fill(CGRect(x: barX, y: h * 0.72, width: max(6, w / 80), height: h * 0.2))
        // Corner markers show orientation and that nothing is cropped.
        let m = max(24, w / 20)
        for (i, corner) in [CGPoint(x: 0, y: 0), CGPoint(x: w - m, y: 0), CGPoint(x: 0, y: h - m), CGPoint(x: w - m, y: h - m)].enumerated() {
            ctx.setFillColor(color([0x6CDCF5, 0xF4BE62, 0xFF6B76, 0xB8F36B][i]))
            ctx.fill(CGRect(origin: corner, size: CGSize(width: m, height: m)))
        }
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        text(ctx, "MyBuddy TEST PATTERN", at: CGPoint(x: w * 0.08, y: h * 0.16), size: h * 0.075, color: color(0xF4F7FB))
        text(ctx, "Not a screen capture — synthetic frames from the interop test host", at: CGPoint(x: w * 0.08, y: h * 0.30),
             size: h * 0.035, color: color(0x9AA6B5))
        text(ctx, "\(size.width)×\(size.height)  ·  frame \(frame)  ·  \(time)", at: CGPoint(x: w * 0.08, y: h * 0.42),
             size: h * 0.045, color: color(0x6CDCF5))
        text(ctx, "TOP LEFT", at: CGPoint(x: m * 1.3, y: m * 0.25), size: m * 0.45, color: color(0xF4F7FB))
    }

    private static func text(_ ctx: CGContext, _ string: String, at point: CGPoint, size: CGFloat, color: CGColor) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.saveGState()
        // Text draws in a bottom-up space; undo the flip locally.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: point.x, y: point.y + size)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
