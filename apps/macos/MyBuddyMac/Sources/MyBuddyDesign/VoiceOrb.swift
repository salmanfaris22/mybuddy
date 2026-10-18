import SwiftUI

public enum VoiceOrbPhase: Sendable, Equatable {
    case idle, listening, thinking, speaking, error
}

/// MyBuddy Voice orb: a soft core with level-reactive rings. Under Reduce Motion it becomes a
/// static ring whose thickness reflects the level.
public struct VoiceOrb: View {
    let phase: VoiceOrbPhase
    let level: Double
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(phase: VoiceOrbPhase, level: Double = 0, size: CGFloat = 220) {
        self.phase = phase
        self.level = level
        self.size = size
    }

    private var tint: Color {
        switch phase {
        case .idle: MBColor.textSecondary
        case .listening: MBColor.accent
        case .thinking: MBColor.info
        case .speaking: MBColor.info
        case .error: MBColor.danger
        }
    }

    public var body: some View {
        Group {
            if reduceMotion {
                staticOrb
            } else {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: phase == .idle && level == 0)) { ctx in
                    animatedOrb(t: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch phase {
        case .idle: "Voice assistant idle"
        case .listening: "Listening"
        case .thinking: "Working on it"
        case .speaking: "Speaking"
        case .error: "Voice error"
        }
    }

    private var staticOrb: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [tint.opacity(0.35), MBColor.elevated], center: .center, startRadius: 0, endRadius: size / 2))
            Circle().strokeBorder(tint, lineWidth: 2 + 10 * min(max(level, 0), 1))
        }
    }

    private func animatedOrb(t: Double) -> some View {
        let lvl = min(max(level, 0), 1)
        let breathe = 0.5 + 0.5 * sin(t * (phase == .speaking ? 5 : 1.4))
        return ZStack {
            // Outer level rings
            ForEach(0..<3) { i in
                let base = 0.62 + Double(i) * 0.13
                let wobble = phase == .listening ? lvl * 0.10 * (1 - Double(i) * 0.25) : (phase == .speaking ? 0.04 * breathe : 0.015 * breathe)
                Circle()
                    .stroke(tint.opacity(0.22 - Double(i) * 0.06), lineWidth: 1.5)
                    .scaleEffect(base + wobble)
            }
            // Core glow
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.55), tint.opacity(0.12), .clear], center: .center, startRadius: 0, endRadius: size * 0.42))
                .scaleEffect(0.78 + (phase == .listening ? lvl * 0.12 : 0.04 * breathe))
            // Core
            Circle()
                .fill(LinearGradient(colors: [MBColor.accent.opacity(phase == .idle ? 0.55 : 0.95), MBColor.info.opacity(phase == .idle ? 0.45 : 0.9)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.34, height: size * 0.34)
                .overlay(Circle().fill(Color.white.opacity(0.12)).scaleEffect(0.55).offset(x: -size * 0.03, y: -size * 0.03).blur(radius: 6))
                .scaleEffect(1 + (phase == .listening ? lvl * 0.08 : 0.02 * breathe))
            // Thinking arc
            if phase == .thinking {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(MBColor.info, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.radians(t * 3))
                    .scaleEffect(0.5)
            }
        }
    }
}

/// A compact live audio level meter (used next to captions).
public struct LevelMeter: View {
    let level: Double
    let bars: Int
    public init(level: Double, bars: Int = 12) {
        self.level = level
        self.bars = bars
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let threshold = Double(i + 1) / Double(bars)
                Capsule().fill(level >= threshold ? MBColor.accent : MBColor.border)
                    .frame(width: 3, height: 6 + CGFloat(i % 4) * 3)
            }
        }
        .animation(MBMotion.quick, value: level)
        .accessibilityLabel("Microphone level \(Int(level * 100)) percent")
    }
}
