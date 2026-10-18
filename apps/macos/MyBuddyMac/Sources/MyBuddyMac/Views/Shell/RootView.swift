import MyBuddyCore
import MyBuddyDesign
import MyBuddyHost
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    static let inspectorMinWindowWidth: CGFloat = 1180
    static let compactSidebarBelow: CGFloat = 1080

    var body: some View {
        @Bindable var connection = model.connection
        @Bindable var ai = model.ai
        GeometryReader { geo in
            let compact = geo.size.width < Self.compactSidebarBelow
            let showInspector = model.showInspector && geo.size.width >= Self.inspectorMinWindowWidth
            HStack(spacing: 0) {
                Sidebar(compact: compact)
                    .frame(width: compact ? 68 : 228)
                Rectangle().fill(MBColor.border).frame(width: 1).ignoresSafeArea()
                VStack(spacing: 0) {
                    TopBar(inspectorAvailable: geo.size.width >= Self.inspectorMinWindowWidth)
                    Rectangle().fill(MBColor.border).frame(height: 1)
                    SectionContent(section: model.selection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                if showInspector {
                    Rectangle().fill(MBColor.border).frame(width: 1).ignoresSafeArea()
                    InspectorView(section: model.selection)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(MBMotion.standard, value: showInspector)
        }
        .background(AmbientBackground())
        .sheet(isPresented: $connection.showPairingSheet) { PairingSheet().environment(model) }
        .sheet(item: $ai.pendingPhoneAgent) { request in PhoneAgentApprovalSheet(request: request).environment(model) }
        .tint(MBColor.accent)
        .onAppear { model.connection.reloadDevices() }
    }
}

struct SectionContent: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .overview: OverviewView()
        case .remote: RemoteDesktopView()
        case .ai: AIStudioView()
        case .voice: VoiceView()
        case .files: FilesClipboardView()
        case .notes: NotesView()
        case .notifications: NotificationsView()
        case .health: HealthView()
        case .activity: ActivityView()
        case .settings: SettingsView()
        }
    }
}

/// Standard scrolling page with consistent gutters.
struct Page<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MBSpace.l) { content }
                .padding(.horizontal, MBSpace.xl)
                .padding(.vertical, MBSpace.l)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    let compact: Bool

    var body: some View {
        VStack(alignment: compact ? .center : .leading, spacing: 0) {
            HStack(spacing: MBSpace.m) {
                BrandMark(size: 30, live: !model.connection.sessions.isEmpty)
                if !compact {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MyBuddy").font(.system(size: 15, weight: .semibold)).foregroundStyle(MBColor.textPrimary)
                        Text(model.connection.statusTitle).font(.system(size: 11)).foregroundStyle(MBColor.textTertiary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, compact ? 0 : MBSpace.l)
            .padding(.top, MBSpace.s)
            .padding(.bottom, MBSpace.l)
            .accessibilityElement(children: .combine)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(AppSection.allCases) { section in
                        SidebarItem(section: section, compact: compact)
                    }
                }
                .padding(.horizontal, MBSpace.s + 2)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            VStack(alignment: compact ? .center : .leading, spacing: MBSpace.s) {
                if model.settings.localOnly {
                    if compact {
                        Image(systemName: "lock.fill").foregroundStyle(MBColor.info).help("Local Only is on")
                    } else {
                        StatusPill("Local Only", tone: .info, symbol: "lock.fill")
                    }
                }
                if model.isStayingAwake {
                    if compact {
                        Image(systemName: "cup.and.saucer.fill").foregroundStyle(MBColor.info).help("Stay Awake: this Mac won’t idle-sleep while a phone is connected")
                    } else {
                        StatusPill("Staying awake", tone: .info, symbol: "cup.and.saucer.fill")
                            .help("This Mac and its display won’t idle-sleep while a phone is connected. Closing the lid still sleeps it unless an external display and power are connected.")
                    }
                }
                if !model.connection.sessions.isEmpty {
                    Button(role: .destructive) { model.emergencyStop() } label: {
                        if compact { Image(systemName: "stop.circle.fill") } else { Label("Emergency Stop", systemImage: "stop.circle.fill").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(MBButtonStyle(.danger, compact: true))
                    .help("End every session and disable remote input now (⇧⌘.)")
                    .accessibilityLabel("Emergency stop")
                }
                if !compact {
                    Text("MyBuddy \(HostInfo.appVersion)").font(.system(size: 10.5)).foregroundStyle(MBColor.textTertiary)
                }
            }
            .padding(compact ? MBSpace.s : MBSpace.l)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(MBColor.surface.ignoresSafeArea())
    }
}

struct SidebarItem: View {
    @Environment(AppModel.self) private var model
    let section: AppSection
    let compact: Bool
    @State private var hovering = false

    var body: some View {
        let selected = model.selection == section
        Button { model.selection = section } label: {
            HStack(spacing: MBSpace.m - 2) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? MBColor.accent : MBColor.textSecondary)
                    .frame(width: 20)
                if !compact {
                    Text(section.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? MBColor.textPrimary : MBColor.textSecondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, compact ? 0 : MBSpace.m - 2)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: MBRadius.md - 2, style: .continuous)
                .fill(selected ? MBColor.elevatedHover : (hovering ? MBColor.elevated : .clear)))
            .overlay(alignment: .leading) {
                if selected && !compact {
                    Capsule().fill(MBColor.accent).frame(width: 3, height: 16).offset(x: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Top bar (status + command palette)

struct TopBar: View {
    @Environment(AppModel.self) private var model
    var inspectorAvailable = true

    struct Command: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let action: @MainActor (AppModel) -> Void
    }

    var commands: [Command] {
        AppSection.allCases.map { s in Command(id: "go-\(s.rawValue)", title: "Go to \(s.title)", symbol: s.symbol) { $0.selection = s } } + [
            Command(id: "pair", title: "Pair a phone", symbol: "qrcode") { $0.connection.openPairing() },
            Command(id: "stop", title: "Emergency stop", symbol: "stop.circle") { $0.emergencyStop() },
            Command(id: "report", title: "Export health report", symbol: "square.and.arrow.up") { m in m.selection = .health; m.health.export(.markdown) },
            Command(id: "local", title: "Toggle Local Only", symbol: "lock") { $0.settings.localOnly.toggle() },
            Command(id: "voice", title: "Talk to MyBuddy", symbol: "waveform") { $0.selection = .voice },
        ]
    }

    var matches: [Command] {
        let q = model.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return commands.filter { $0.title.lowercased().contains(q) }.prefix(6).map { $0 }
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: MBSpace.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.selection.title).font(MBFont.title).foregroundStyle(MBColor.textPrimary)
            }
            if model.demoMode { PreviewBadge().fixedSize() }
            Spacer(minLength: MBSpace.m)
            connectionPill.fixedSize()
            HStack(spacing: MBSpace.s) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(MBColor.textTertiary)
                TextField("Search commands", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(MBFont.body)
                    .frame(minWidth: 110, idealWidth: 180, maxWidth: 200)
                    .onSubmit { if let first = matches.first { run(first) } }
                Text("⌘K").font(.system(size: 10, weight: .medium)).foregroundStyle(MBColor.textTertiary)
            }
            .padding(.horizontal, MBSpace.m).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: MBRadius.md).fill(MBColor.elevated))
            .overlay(RoundedRectangle(cornerRadius: MBRadius.md).strokeBorder(MBColor.border))
            .popover(isPresented: Binding(get: { !matches.isEmpty }, set: { if !$0 { model.searchText = "" } }), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches) { c in
                        Button { run(c) } label: {
                            Label(c.title, systemImage: c.symbol).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(MBSpace.m)
                .frame(width: 260)
            }
            if inspectorAvailable {
                Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(MBButtonStyle(.ghost, compact: true))
                    .help("Show or hide the inspector")
                    .accessibilityLabel("Toggle inspector")
            }
            Button { model.selection = .settings } label: { Image(systemName: "gearshape") }
                .buttonStyle(MBButtonStyle(.ghost, compact: true))
                .accessibilityLabel("Settings")
        }
        .padding(.horizontal, MBSpace.xl)
        .padding(.vertical, MBSpace.m)
        .background(MBColor.base.opacity(0.6))
    }

    private func run(_ c: Command) {
        model.searchText = ""
        c.action(model)
    }

    @ViewBuilder private var connectionPill: some View {
        let state = model.connection.connectionState
        let tone: MBTone = switch state.tone {
        case .live: .live
        case .info: .info
        case .warning: .warning
        case .danger: .danger
        case .neutral: .neutral
        }
        if let session = model.connection.activeSession {
            StatusPill("\(session.deviceName) · live", tone: tone, pulsing: true)
        } else if let device = model.connection.primaryDevice {
            StatusPill("\(device.name) · offline", tone: .neutral)
        } else {
            StatusPill(state.title, tone: tone)
        }
    }
}
