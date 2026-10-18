import SwiftUI

// MARK: - Brand mark

/// The MyBuddy "companion orbit": a core, an orbit ring and one satellite. Orbits while live.
public struct BrandMark: View {
    let size: CGFloat
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 28, live: Bool = false) {
        self.size = size
        self.live = live
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !live || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = (live && !reduceMotion) ? (t.truncatingRemainder(dividingBy: 8) / 8) * 2 * .pi : -.pi / 4
            Canvas { ctx, canvas in
                let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                let r = canvas.width * 0.38
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(MBColor.textSecondary.opacity(0.45)), lineWidth: max(1, canvas.width * 0.045))
                let core = canvas.width * 0.17
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: 2 * core, height: 2 * core)), with: .color(MBColor.accent))
                let s = canvas.width * 0.095
                let p = CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - s, y: p.y - s, width: 2 * s, height: 2 * s)), with: .color(MBColor.info))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Containers

/// Elevated panel with hairline border and a faint top highlight (no drop shadows on dark).
public struct Panel<Content: View>: View {
    let padding: CGFloat
    let content: Content

    public init(padding: CGFloat = MBSpace.l, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MBRadius.lg, style: .continuous)
                    .fill(MBColor.elevated)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: MBRadius.lg, style: .continuous)
                            .fill(LinearGradient(colors: [MBColor.highlight, .clear], startPoint: .top, endPoint: .center))
                    }
            )
            .overlay(RoundedRectangle(cornerRadius: MBRadius.lg, style: .continuous).strokeBorder(MBColor.border, lineWidth: 1))
    }
}

public struct SectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MBSpace.m) {
            VStack(alignment: .leading, spacing: MBSpace.xxs) {
                Text(title).font(MBFont.headline).foregroundStyle(MBColor.textPrimary)
                if let subtitle { Text(subtitle).font(MBFont.callout).foregroundStyle(MBColor.textSecondary) }
            }
            Spacer(minLength: 0)
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small uppercase label used above groups.
public struct Eyebrow: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased()).font(MBFont.label).tracking(0.6).foregroundStyle(MBColor.textTertiary)
    }
}

// MARK: - Status

public struct StatusPill: View {
    let text: String
    let tone: MBTone
    let symbol: String?
    let pulsing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(_ text: String, tone: MBTone, symbol: String? = nil, pulsing: Bool = false) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
        self.pulsing = pulsing
    }

    public var body: some View {
        HStack(spacing: MBSpace.xs + 2) {
            ZStack {
                if pulsing && !reduceMotion {
                    Circle().fill(tone.color.opacity(0.35)).frame(width: 14, height: 14)
                        .scaleEffect(pulse ? 1 : 0.4).opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                }
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tone.color)
                } else {
                    Circle().fill(tone.color).frame(width: 7, height: 7)
                }
            }
            .frame(width: 14, height: 14)
            Text(text).font(MBFont.callout.weight(.medium)).foregroundStyle(MBColor.textPrimary).lineLimit(1)
        }
        .padding(.horizontal, MBSpace.s + 2)
        .padding(.vertical, MBSpace.xs + 1)
        .background(Capsule().fill(tone.color.opacity(0.10)))
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.28), lineWidth: 1))
        .onAppear { pulse = pulsing }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// "Preview data" marker shown whenever demo fixtures are on screen.
public struct PreviewBadge: View {
    public init() {}
    public var body: some View {
        Label("Preview data", systemImage: "eye.trianglebadge.exclamationmark")
            .font(MBFont.label).tracking(0.4)
            .foregroundStyle(MBColor.warning)
            .padding(.horizontal, MBSpace.s).padding(.vertical, MBSpace.xs)
            .background(Capsule().fill(MBColor.warning.opacity(0.12)))
            .accessibilityLabel("Preview data, not measured")
    }
}

/// A source/provenance caption.
public struct SourceCaption: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Label(text, systemImage: "info.circle")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10.5))
            .foregroundStyle(MBColor.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

// MARK: - Metrics

public struct RingGauge: View {
    let value: Double?
    let tone: MBTone
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(value: Double?, tone: MBTone = .live, lineWidth: CGFloat = 10) {
        self.value = value
        self.tone = tone
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle().stroke(MBColor.border, lineWidth: lineWidth)
            if let value {
                Circle()
                    .trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(tone.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(MBMotion.animation(MBMotion.emphasized, reduce: reduceMotion), value: value)
            } else {
                Circle().trim(from: 0, to: 0.25).stroke(MBColor.textTertiary.opacity(0.4), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [2, 6]))
            }
        }
    }
}

public struct UsageBar: View {
    let fraction: Double
    let tone: MBTone
    public init(fraction: Double, tone: MBTone = .info) {
        self.fraction = fraction
        self.tone = tone
    }

    public var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(MBColor.border)
                Capsule().fill(tone.color).frame(width: max(4, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// One measured value with its label, provenance and (optional) status note.
public struct MetricRow: View {
    let label: String
    let value: String
    let note: String?
    let source: String?
    let tone: MBTone

    public init(_ label: String, value: String, note: String? = nil, source: String? = nil, tone: MBTone = .neutral) {
        self.label = label
        self.value = value
        self.note = note
        self.source = source
        self.tone = tone
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MBSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(MBFont.body).foregroundStyle(MBColor.textSecondary)
                if let source { SourceCaption(source) }
            }
            Spacer(minLength: MBSpace.m)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(MBFont.bodyEmphasis.monospacedDigit()).foregroundStyle(tone == .neutral ? MBColor.textPrimary : tone.color)
                if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(MBColor.textTertiary).multilineTextAlignment(.trailing) }
            }
        }
        .padding(.vertical, MBSpace.xs + 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - States

public enum StateKind: Sendable {
    case loading, empty, error, notAuthorized, unavailable, offline
}

/// Designed empty/loading/error/permission states (never raw exception text).
public struct StateView<Actions: View>: View {
    let kind: StateKind
    let title: String
    let message: String
    let actions: Actions

    public init(_ kind: StateKind, title: String, message: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var symbol: String {
        switch kind {
        case .loading: "hourglass"
        case .empty: "sparkles"
        case .error: "exclamationmark.triangle"
        case .notAuthorized: "lock.shield"
        case .unavailable: "slash.circle"
        case .offline: "wifi.slash"
        }
    }

    var tone: MBTone {
        switch kind {
        case .error: .danger
        case .notAuthorized, .offline: .warning
        case .loading, .empty: .info
        case .unavailable: .neutral
        }
    }

    public var body: some View {
        VStack(spacing: MBSpace.m) {
            if kind == .loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(tone.color)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(tone.color.opacity(0.10)))
            }
            Text(title).font(MBFont.headline).foregroundStyle(MBColor.textPrimary).multilineTextAlignment(.center)
            Text(message).font(MBFont.body).foregroundStyle(MBColor.textSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
            actions.padding(.top, MBSpace.xs)
        }
        .padding(MBSpace.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Shimmering placeholder while data loads (static under Reduce Motion).
public struct Skeleton: View {
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    public init(height: CGFloat = 14) { self.height = height }

    public var body: some View {
        RoundedRectangle(cornerRadius: MBRadius.sm)
            .fill(MBColor.border.opacity(0.6))
            .overlay {
                if !reduceMotion {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, Color.white.opacity(0.06), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.5)
                            .offset(x: phase * g.size.width)
                    }
                    .clipped()
                }
            }
            .frame(height: height)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.5 }
            }
            .accessibilityLabel("Loading")
    }
}

// MARK: - Timeline

public struct TimelineRow: View {
    let symbol: String
    let tone: MBTone
    let title: String
    let detail: String?
    let date: Date

    public init(symbol: String, tone: MBTone, title: String, detail: String?, date: Date) {
        self.symbol = symbol
        self.tone = tone
        self.title = title
        self.detail = detail
        self.date = date
    }

    public var body: some View {
        HStack(alignment: .top, spacing: MBSpace.m) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tone.color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: MBRadius.sm + 1).fill(tone.color.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(MBFont.body).foregroundStyle(MBColor.textPrimary).lineLimit(1)
                if let detail { Text(detail).font(MBFont.callout).foregroundStyle(MBColor.textTertiary).lineLimit(1) }
            }
            Spacer(minLength: MBSpace.s)
            Text(date, style: .relative).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(MBColor.textTertiary)
        }
        .padding(.vertical, MBSpace.xs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons

public struct MBButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, ghost, danger }
    let kind: Kind
    let compact: Bool
    public init(_ kind: Kind = .secondary, compact: Bool = false) {
        self.kind = kind
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, compact: compact)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let (fg, bg, stroke): (Color, Color, Color) = switch kind {
            case .primary: (MBColor.onAccent, MBColor.accent, .clear)
            case .secondary: (MBColor.textPrimary, hovering ? MBColor.elevatedHover : MBColor.elevated, MBColor.borderStrong)
            case .ghost: (MBColor.textSecondary, hovering ? MBColor.elevated : .clear, .clear)
            case .danger: (MBColor.danger, MBColor.danger.opacity(hovering ? 0.18 : 0.12), MBColor.danger.opacity(0.35))
            }
            configuration.label
                .font(compact ? MBFont.callout.weight(.semibold) : MBFont.body.weight(.semibold))
                .foregroundStyle(fg)
                .padding(.horizontal, compact ? MBSpace.m : MBSpace.l)
                .padding(.vertical, compact ? MBSpace.xs + 1 : MBSpace.s)
                .background(RoundedRectangle(cornerRadius: MBRadius.md, style: .continuous).fill(bg))
                .overlay(RoundedRectangle(cornerRadius: MBRadius.md, style: .continuous).strokeBorder(stroke, lineWidth: 1))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(MBMotion.quick, value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Chips

public struct Chip: View {
    let text: String
    let symbol: String?
    let selected: Bool
    public init(_ text: String, symbol: String? = nil, selected: Bool = false) {
        self.text = text
        self.symbol = symbol
        self.selected = selected
    }

    public var body: some View {
        HStack(spacing: MBSpace.xs) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(MBFont.callout.weight(.medium))
        }
        .foregroundStyle(selected ? MBColor.onAccent : MBColor.textSecondary)
        .padding(.horizontal, MBSpace.m - 2).padding(.vertical, MBSpace.xs + 1)
        .background(Capsule().fill(selected ? MBColor.accent : MBColor.elevated))
        .overlay(Capsule().strokeBorder(selected ? .clear : MBColor.border, lineWidth: 1))
    }
}

/// Background with restrained lighting (one radial glow, ≤ 6% opacity).
public struct AmbientBackground: View {
    public init() {}
    public var body: some View {
        ZStack {
            MBColor.base
            RadialGradient(colors: [MBColor.accent.opacity(0.05), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [MBColor.info.opacity(0.035), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 800)
        }
        .ignoresSafeArea()
    }
}
