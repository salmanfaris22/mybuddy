import AppKit
import CoreGraphics
import Foundation
import MyBuddyCore
import MyBuddyHost
import MyBuddyMedia
import Observation
import os
@preconcurrency import ScreenCaptureKit

/// Thread-safe handle to the running LAN host, so media signaling (ICE candidates arrive on libwebrtc's
/// thread) is sent directly and in order instead of hopping through the main actor.
final class ServerRef: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LANHostServer?
    var server: LANHostServer? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// The capture source of the current stream (for applying a selection made in the system picker).
final class SourceRef: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ScreenCaptureKitSource?
    private var picked: SCContentFilter?

    func make() -> ScreenCaptureKitSource {
        let source = ScreenCaptureKitSource()
        lock.withLock {
            source.setPickedContent(picked)
            value = source
        }
        return source
    }

    func pick(_ filter: SCContentFilter?) {
        let source = lock.withLock { () -> ScreenCaptureKitSource? in
            picked = filter
            return value
        }
        source?.setPickedContent(filter)
    }

    var hasPick: Bool { lock.withLock { picked != nil } }
}

/// Screen sharing on the Mac: owns the stream controller, mirrors its state for the UI and the activity
/// log, and offers the system content picker. Streams start only when an authorized phone asks.
@MainActor
@Observable
final class ScreenShareStore {
    @ObservationIgnored var app: AppModel!
    let demo: Bool
    private(set) var snapshot: ScreenShareSnapshot?
    private(set) var permission: PermissionState = .notDetermined
    private(set) var pickedContentDescription: String?

    @ObservationIgnored let serverRef: ServerRef
    @ObservationIgnored private let sources = SourceRef()
    @ObservationIgnored private(set) var controller: ScreenShareController!
    @ObservationIgnored private var knownSessions: Set<String> = []
    @ObservationIgnored private var picker: ContentPicker?
    @ObservationIgnored private var appliedSnapshot = 0

    private nonisolated static let streamLog = Logger(subsystem: "app.mybuddy.mac", category: "screen")

    init(demo: Bool, injector: InputInjector, serverRef: ServerRef, iceProvider: (@Sendable (String) async -> [ICEServerConfig])? = nil) {
        self.demo = demo
        self.serverRef = serverRef
        let serverRef = serverRef, sources = sources, sequencer = Sequencer(), warnings = Throttle(seconds: 1)
        let warn: @Sendable (String, String, String) -> Void = { session, code, message in
            guard warnings.allow() else { return }
            serverRef.server?.send(OutgoingEvent(.error, ["code": .string(code), "message": .string(message), "retryable": .bool(false)]), toSession: session)
        }
        var options = ScreenShareOptions()
        options.iceProvider = iceProvider  // internet sessions use the Connect server's STUN/TURN
        // Auto quality starts sharp on Wi-Fi/LAN and Tailscale (it steps down if the link can't keep up);
        // a TURN-relayed internet session starts at Balanced to spare the relay.
        options.autoStartTier = { session in
            serverRef.server?.activeSessions.first { $0.id == session }?.route == .internetRelayed ? .balanced : .high
        }
        controller = ScreenShareController(
            options: options,
            permission: { CGPreflightScreenCaptureAccess() || sources.hasPick },
            makeSource: { sources.make() },
            send: { event, session in serverRef.server?.send(event, toSession: session) },
            onSnapshot: { [weak self] snapshot in
                // Numbered so a late task can never overwrite a newer state.
                let n = sequencer.next()
                Task { @MainActor in self?.apply(snapshot, sequence: n) }
            },
            // Stream lifecycle only (states, ICE, quality changes) — never frames, input or contents. `log stream
            // --predicate 'subsystem == "app.mybuddy.mac"'` shows it.
            log: { line in Self.streamLog.info("\(line, privacy: .public)") },
            // Input on the WebRTC data channels obeys the same rules as on the encrypted control channel.
            authorizeInput: { session in
                serverRef.server?.activeSessions.first { $0.id == session }?.grantedCapabilities.contains(.inputControl) == true
            },
            onInput: { envelope, target in
                guard let display = RemoteInput.targetDisplay(streamedDisplayId: target.displayId, source: target.source) else {
                    return warn(target.sessionId, "window_share_no_input", "Remote control works when a whole display is shared, not a single window.")
                }
                guard RemoteInput.canInject(injector) else {
                    return warn(target.sessionId, "accessibility_required", "Allow MyBuddy in System Settings → Privacy & Security → Accessibility on the Mac.")
                }
                RemoteInput.apply(envelope, injector: injector, display: display)
            },
            onInputEnded: { injector.releaseAll() })
        refreshPermission()
    }

    var isSharing: Bool { snapshot != nil }
    var isLive: Bool { snapshot?.status.phase == .live }

    func refreshPermission() {
        permission = demo ? .granted : SystemPermissions.screenRecording
    }

    /// Shows the system Screen Recording prompt (explicit user action only).
    func requestPermission() {
        SystemPermissions.requestScreenRecording()
        refreshPermission()
    }

    func handle(_ e: Envelope, device: TrustedDevice) async -> [OutgoingEvent] {
        guard !demo else { return [] }
        refreshPermission()
        return await controller.handle(e, deviceName: device.name)
    }

    /// Ends the stream of any session that went away (disconnect, revoke, timeout).
    func sessionsChanged(_ sessions: [ActiveSessionInfo]) {
        let now = Set(sessions.map(\.id))
        for ended in knownSessions.subtracting(now) {
            Task { await controller.sessionEnded(ended) }
        }
        knownSessions = now
    }

    func stop() {
        Task { await controller.stopFromMac() }
    }

    func emergencyStop() {
        Task { await controller.stopFromMac(emergency: true) }
    }

    // MARK: System picker

    /// Lets the person at the Mac choose a display, window or app with the macOS picker. The current
    /// stream (if any) switches to it; later streams use it until cleared.
    func chooseContent() {
        let picker = self.picker ?? ContentPicker { [weak self] filter, description in
            Task { @MainActor in self?.picked(filter, description: description) }
        }
        self.picker = picker
        picker.present()
    }

    func clearPickedContent() {
        sources.pick(nil)
        pickedContentDescription = nil
        Task { await controller.refreshSource() }
    }

    private func picked(_ filter: SCContentFilter, description: String) {
        sources.pick(filter)
        pickedContentDescription = description
        app.activityLog.record(.security, "Shared content chosen on the Mac", detail: description)
        Task { await controller.refreshSource() }
    }

    // MARK: State

    private func apply(_ new: ScreenShareSnapshot?, sequence: Int) {
        guard sequence > appliedSnapshot else { return }
        appliedSnapshot = sequence
        let old = snapshot
        snapshot = new
        switch (old, new) {
        case (nil, let s?):
            app.activityLog.record(.session, "\(s.deviceName) asked to view the screen", detail: "Quality: \(s.status.quality?.rawValue ?? "auto")")
        case (let o?, let s?) where o.status.phase != .live && s.status.phase == .live:
            let size = s.status.dimensions.map { " · \($0)" } ?? ""
            app.activityLog.record(.session, "Screen shared with \(s.deviceName)", detail: "\(s.status.source?.rawValue ?? "display")\(size)")
        case (let o?, nil):
            app.activityLog.record(.session, "Screen sharing ended", detail: o.deviceName)
        default:
            break
        }
    }
}

/// Lets one event through per interval (e.g. one warning per second).
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last = Date.distantPast
    init(seconds: TimeInterval) { interval = seconds }
    func allow() -> Bool {
        lock.withLock {
            guard Date().timeIntervalSince(last) >= interval else { return false }
            last = Date()
            return true
        }
    }
}

final class Sequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Wraps `SCContentSharingPicker` (macOS 14+): the system UI where the user picks what to share.
final class ContentPicker: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private let onPick: @Sendable (SCContentFilter, String) -> Void

    init(onPick: @escaping @Sendable (SCContentFilter, String) -> Void) {
        self.onPick = onPick
        super.init()
    }

    @MainActor func present() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        if let id = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [id] }
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let description = switch filter.style {
        case .window: "A window"
        case .application: "An app’s windows"
        case .display: "A display"
        default: "Picked content"
        }
        onPick(filter, description)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {}

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {}
}
