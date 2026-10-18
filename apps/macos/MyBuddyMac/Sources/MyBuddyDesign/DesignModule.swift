import SwiftUI

/// MyBuddy design system namespace (tokens documented in docs/PRODUCT_DESIGN.md).
public enum MyBuddyDesign {}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Color tokens. Never use raw colors in views — always these.
public enum MBColor {
    public static let base = Color(hex: 0x0A0C10)
    public static let surface = Color(hex: 0x11151B)
    public static let elevated = Color(hex: 0x171D25)
    public static let elevatedHover = Color(hex: 0x1C232D)
    public static let border = Color(hex: 0x27303B)
    public static let borderStrong = Color(hex: 0x35404D)
    public static let textPrimary = Color(hex: 0xF4F7FB)
    public static let textSecondary = Color(hex: 0x9AA6B5)
    public static let textTertiary = Color(hex: 0x7A8595)
    public static let accent = Color(hex: 0xB8F36B)
    public static let info = Color(hex: 0x6CDCF5)
    public static let warning = Color(hex: 0xF4BE62)
    public static let danger = Color(hex: 0xFF6B76)
    public static let onAccent = Color(hex: 0x0A0C10)
    public static let highlight = Color.white.opacity(0.04)
}

public enum MBSpace {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48
}

public enum MBRadius {
    public static let sm: CGFloat = 6
    public static let md: CGFloat = 10
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
}

public enum MBFont {
    public static let display = Font.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit()
    public static let hero = Font.system(size: 26, weight: .semibold, design: .default)
    public static let title = Font.system(size: 20, weight: .semibold)
    public static let headline = Font.system(size: 15, weight: .semibold)
    public static let body = Font.system(size: 13)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    public static let callout = Font.system(size: 12)
    public static let label = Font.system(size: 10.5, weight: .semibold)
    public static let mono = Font.system(size: 12, design: .monospaced)
    public static let metric = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
}

public enum MBTone: Sendable, Equatable {
    case neutral, live, info, warning, danger

    public var color: Color {
        switch self {
        case .neutral: MBColor.textSecondary
        case .live: MBColor.accent
        case .info: MBColor.info
        case .warning: MBColor.warning
        case .danger: MBColor.danger
        }
    }
}

/// Motion tokens; each respects Reduce Motion via `MBMotion.animation(_:reduce:)`.
public enum MBMotion {
    public static let quick = Animation.easeOut(duration: 0.12)
    public static let standard = Animation.spring(response: 0.35, dampingFraction: 0.86)
    public static let emphasized = Animation.spring(response: 0.5, dampingFraction: 0.8)

    public static func animation(_ a: Animation, reduce: Bool) -> Animation {
        reduce ? .easeInOut(duration: 0.15) : a
    }
}
