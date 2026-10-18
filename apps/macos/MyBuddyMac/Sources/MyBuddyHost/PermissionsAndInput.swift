import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import MyBuddyCore
import ScreenCaptureKit
import Speech

/// Typed permission states shown in the UI (never inferred from failures alone).
public enum PermissionState: String, Sendable, Equatable {
    case granted, denied, notDetermined, restricted, unavailable

    public var title: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not requested yet"
        case .restricted: "Restricted by policy"
        case .unavailable: "Unavailable"
        }
    }
}

public enum SystemPermissions {
    /// Screen Recording: preflight never prompts.
    public static var screenRecording: PermissionState { CGPreflightScreenCaptureAccess() ? .granted : .notDetermined }

    /// Shows the system Screen Recording prompt (only call from an explicit user action).
    @discardableResult
    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    /// Accessibility (needed to inject remote mouse/keyboard events).
    public static var accessibility: PermissionState { AXIsProcessTrusted() ? .granted : .notDetermined }

    /// Opens the system prompt that leads to System Settings → Privacy → Accessibility.
    public static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary  // value of kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }

    public static var speechRecognition: PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }

    public static func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Lists displays via ScreenCaptureKit (requires Screen Recording permission).
public enum ScreenCatalog {
    public struct Display: Sendable, Identifiable, Equatable {
        public let id: UInt32
        public let width: Int
        public let height: Int
        public let frame: CGRect
    }

    public static func displays() async throws -> [Display] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.displays.map { Display(id: $0.displayID, width: $0.width, height: $0.height, frame: $0.frame) }
    }

    /// Display geometry in global points for input mapping (CGDisplayBounds uses a top-left origin).
    public static func geometry(displayId: UInt32) -> DisplayGeometry {
        let b = CGDisplayBounds(displayId)
        return DisplayGeometry(displayId: String(displayId), originX: b.origin.x, originY: b.origin.y, width: b.width, height: b.height)
    }
}

/// Posts remote input as CGEvents. Refuses to do anything unless Accessibility is granted
/// and a session with `input.control` is active (enforced by the caller and re-checked here).
public final class InputInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var pressed = PressedInputTracker()
    private var enabled = false
    private let source = CGEventSource(stateID: .hidSystemState)

    public init() {}

    /// Called when a session gains/loses `input.control` or on emergency stop.
    public func setEnabled(_ on: Bool) {
        let release: Bool = lock.withLock {
            defer { enabled = on }
            return enabled && !on
        }
        if release { releaseAll() }
    }

    public var isEnabled: Bool { lock.withLock { enabled } }

    private func canPost() -> Bool { lock.withLock { enabled } && AXIsProcessTrusted() }

    public func movePointer(to p: (x: Double, y: Double)) {
        guard canPost() else { return }
        let buttonsDown = lock.withLock { pressed.buttons }
        let type: CGEventType = buttonsDown.contains("left") ? .leftMouseDragged : buttonsDown.contains("right") ? .rightMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: p.x, y: p.y), mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    public func button(_ button: String, action: String, at p: (x: Double, y: Double)) {
        guard canPost() else { return }
        let point = CGPoint(x: p.x, y: p.y)
        let (down, up, cg): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case "right": (.rightMouseDown, .rightMouseUp, .right)
        case "middle": (.otherMouseDown, .otherMouseUp, .center)
        default: (.leftMouseDown, .leftMouseUp, .left)
        }
        func post(_ type: CGEventType, clicks: Int64) {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cg)
            e?.setIntegerValueField(.mouseEventClickState, value: clicks)
            e?.post(tap: .cghidEventTap)
        }
        switch action {
        case "down":
            lock.withLock { pressed.buttonDown(button) }
            post(down, clicks: 1)
        case "up":
            lock.withLock { pressed.buttonUp(button) }
            post(up, clicks: 1)
        case "doubleClick":
            post(down, clicks: 1); post(up, clicks: 1); post(down, clicks: 2); post(up, clicks: 2)
        default:
            post(down, clicks: 1); post(up, clicks: 1)
        }
    }

    public func scroll(dx: Double, dy: Double, unit: String) {
        guard canPost() else { return }
        let units: CGScrollEventUnit = unit == "line" ? .line : .pixel
        CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2, wheel1: Int32(-dy.rounded()), wheel2: Int32(-dx.rounded()), wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    public func key(code: String, action: String, modifiers: [String]) {
        guard canPost(), let vk = KeyCodeMap.virtualKey(for: code) else { return }
        var flags: CGEventFlags = []
        if modifiers.contains("shift") { flags.insert(.maskShift) }
        if modifiers.contains("control") { flags.insert(.maskControl) }
        if modifiers.contains("option") { flags.insert(.maskAlternate) }
        if modifiers.contains("command") { flags.insert(.maskCommand) }
        func post(_ down: Bool) {
            let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        switch action {
        case "down":
            lock.withLock { pressed.keyDown(code) }
            post(true)
        case "up":
            lock.withLock { pressed.keyUp(code) }
            post(false)
        default:
            post(true); post(false)
        }
    }

    /// Types Unicode text without mapping to key codes.
    public func text(_ s: String) {
        guard canPost() else { return }
        for chunk in s.utf16.chunked(20) {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Stuck-key cleanup: releases everything still pressed (disconnect, revoke, emergency stop).
    public func releaseAll() {
        let (keys, buttons) = lock.withLock { pressed.releaseAll() }
        guard AXIsProcessTrusted() else { return }
        for code in keys {
            if let vk = KeyCodeMap.virtualKey(for: code) { CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: false)?.post(tap: .cghidEventTap) }
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        for b in buttons {
            let (type, cg): (CGEventType, CGMouseButton) = b == "right" ? (.rightMouseUp, .right) : b == "middle" ? (.otherMouseUp, .center) : (.leftMouseUp, .left)
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: cg)?.post(tap: .cghidEventTap)
        }
    }
}

/// Applies one validated, authorized `input.*` envelope to a display. Shared by the MBH1 control channel and
/// the WebRTC input data channels so both behave identically.
public enum RemoteInput {
    /// Whether events can be posted right now (Accessibility granted and a session holding `input.control`).
    public static func canInject(_ injector: InputInjector) -> Bool {
        SystemPermissions.accessibility == .granted && injector.isEnabled
    }

    public static func apply(_ e: Envelope, injector: InputInjector, display: DisplayGeometry) {
        let p = e.payload
        let point = CoordinateMapper.point(x: p["x"]?.numberValue ?? 0, y: p["y"]?.numberValue ?? 0, on: display)
        switch e.type {
        case .inputPointer: injector.movePointer(to: point)
        case .inputButton: injector.button(p["button"]?.stringValue ?? "left", action: p["action"]?.stringValue ?? "click", at: point)
        case .inputScroll: injector.scroll(dx: p["dx"]?.numberValue ?? 0, dy: p["dy"]?.numberValue ?? 0, unit: p["unit"]?.stringValue ?? "pixel")
        case .inputKey: injector.key(code: p["code"]?.stringValue ?? "", action: p["action"]?.stringValue ?? "press",
                                     modifiers: p["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        case .inputText: injector.text(p["text"]?.stringValue ?? "")
        default: break
        }
    }

    /// The display a session's input lands on: the display being streamed to it, else the main display.
    /// Returns nil when a single window/app is shared (its on-screen position can't be mapped reliably).
    public static func targetDisplay(streamedDisplayId: String?, source: StreamSourceKind?) -> DisplayGeometry? {
        switch source {
        case .window?, .application?: return nil
        case .display?:
            if let id = streamedDisplayId.flatMap(UInt32.init) { return ScreenCatalog.geometry(displayId: id) }
            return ScreenCatalog.geometry(displayId: CGMainDisplayID())
        default:
            return ScreenCatalog.geometry(displayId: CGMainDisplayID())
        }
    }
}

extension Collection {
    func chunked(_ size: Int) -> [[Element]] {
        var out: [[Element]] = []
        var current: [Element] = []
        for e in self {
            current.append(e)
            if current.count == size {
                out.append(current)
                current = []
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
