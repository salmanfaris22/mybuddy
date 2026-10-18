import Foundation

/// A captured display in global screen points (top-left origin, as used by CGEvent).
public struct DisplayGeometry: Sendable, Equatable {
    public let displayId: String
    public let originX: Double
    public let originY: Double
    public let width: Double
    public let height: Double

    public init(displayId: String, originX: Double, originY: Double, width: Double, height: Double) {
        self.displayId = displayId
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }
}

public enum CoordinateMapper {
    /// Maps normalized frame coordinates (0…1, top-left origin) to global display points, clamped
    /// inside the display so input can never land on another screen.
    public static func point(x: Double, y: Double, on d: DisplayGeometry) -> (x: Double, y: Double) {
        let nx = x.isFinite ? min(max(x, 0), 1) : 0
        let ny = y.isFinite ? min(max(y, 0), 1) : 0
        let px = d.originX + nx * d.width
        let py = d.originY + ny * d.height
        return (min(px, d.originX + d.width - 1), min(py, d.originY + d.height - 1))
    }

    /// Inverse mapping (Mac pointer → frame) for pointer visualization.
    public static func normalized(x: Double, y: Double, on d: DisplayGeometry) -> (x: Double, y: Double) {
        (min(max((x - d.originX) / d.width, 0), 1), min(max((y - d.originY) / d.height, 0), 1))
    }
}

/// W3C `KeyboardEvent.code` → macOS virtual key code (HIToolbox kVK_*). Only allowlisted keys exist.
public enum KeyCodeMap {
    public static let macVirtualKeys: [String: UInt16] = [
        "KeyA": 0x00, "KeyS": 0x01, "KeyD": 0x02, "KeyF": 0x03, "KeyH": 0x04, "KeyG": 0x05, "KeyZ": 0x06, "KeyX": 0x07,
        "KeyC": 0x08, "KeyV": 0x09, "KeyB": 0x0B, "KeyQ": 0x0C, "KeyW": 0x0D, "KeyE": 0x0E, "KeyR": 0x0F, "KeyY": 0x10,
        "KeyT": 0x11, "Digit1": 0x12, "Digit2": 0x13, "Digit3": 0x14, "Digit4": 0x15, "Digit6": 0x16, "Digit5": 0x17,
        "Equal": 0x18, "Digit9": 0x19, "Digit7": 0x1A, "Minus": 0x1B, "Digit8": 0x1C, "Digit0": 0x1D, "BracketRight": 0x1E,
        "KeyO": 0x1F, "KeyU": 0x20, "BracketLeft": 0x21, "KeyI": 0x22, "KeyP": 0x23, "Enter": 0x24, "KeyL": 0x25, "KeyJ": 0x26,
        "Quote": 0x27, "KeyK": 0x28, "Semicolon": 0x29, "Backslash": 0x2A, "Comma": 0x2B, "Slash": 0x2C, "KeyN": 0x2D,
        "KeyM": 0x2E, "Period": 0x2F, "Tab": 0x30, "Space": 0x31, "Backquote": 0x32, "Backspace": 0x33, "Escape": 0x35,
        "MetaRight": 0x36, "MetaLeft": 0x37, "ShiftLeft": 0x38, "CapsLock": 0x39, "AltLeft": 0x3A, "ControlLeft": 0x3B,
        "ShiftRight": 0x3C, "AltRight": 0x3D, "ControlRight": 0x3E,
        "F5": 0x60, "F6": 0x61, "F7": 0x62, "F3": 0x63, "F8": 0x64, "F9": 0x65, "F11": 0x67, "F10": 0x6D, "F12": 0x6F,
        "Home": 0x73, "PageUp": 0x74, "Delete": 0x75, "F4": 0x76, "End": 0x77, "F2": 0x78, "PageDown": 0x79, "F1": 0x7A,
        "ArrowLeft": 0x7B, "ArrowRight": 0x7C, "ArrowDown": 0x7D, "ArrowUp": 0x7E,
    ]

    public static func virtualKey(for code: String) -> UInt16? { macVirtualKeys[code] }
}

/// Tracks pressed keys/buttons so everything can be released on disconnect (stuck-key cleanup).
public struct PressedInputTracker: Sendable {
    public private(set) var keys: Set<String> = []
    public private(set) var buttons: Set<String> = []
    public init() {}

    public mutating func keyDown(_ code: String) { keys.insert(code) }
    public mutating func keyUp(_ code: String) { keys.remove(code) }
    public mutating func buttonDown(_ b: String) { buttons.insert(b) }
    public mutating func buttonUp(_ b: String) { buttons.remove(b) }

    /// Returns everything still pressed and clears the state.
    public mutating func releaseAll() -> (keys: [String], buttons: [String]) {
        defer {
            keys = []
            buttons = []
        }
        return (keys.sorted(), buttons.sorted())
    }
}

/// Per-session input rate limits (docs/PROTOCOL.md §5.3).
public struct InputRateLimiter: Sendable {
    private var windows: [EventType: (start: Date, count: Int)] = [:]
    public static let limits: [EventType: Int] = [.inputPointer: 240, .inputScroll: 240, .inputButton: 60, .inputKey: 60, .inputText: 20]
    public init() {}

    public mutating func allow(_ type: EventType, now: Date = Date()) -> Bool {
        guard let limit = Self.limits[type] else { return true }
        var w = windows[type] ?? (now, 0)
        if now.timeIntervalSince(w.start) >= 1 { w = (now, 0) }
        guard w.count < limit else {
            windows[type] = w
            return false
        }
        w.count += 1
        windows[type] = w
        return true
    }
}
