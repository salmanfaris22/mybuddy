import AppKit
import Foundation
import MyBuddyCore
import MyBuddyHost
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class HealthStore {
    @ObservationIgnored var app: AppModel!
    let demo: Bool
    private let pressure: MemoryPressureMonitor
    private(set) var state: LoadState<HealthSnapshot> = .idle
    private(set) var history: [HealthSnapshot] = []
    private(set) var isRefreshing = false
    var exportMessage: String?

    init(demo: Bool, pressure: MemoryPressureMonitor) {
        self.demo = demo
        self.pressure = pressure
        if demo {
            state = .loaded(DemoData.health)
            history = DemoData.healthHistory
        }
    }

    var snapshot: HealthSnapshot? { state.value }

    func refresh() async {
        guard !demo, !isRefreshing else { return }
        isRefreshing = true
        if snapshot == nil { state = .loading }
        let diagnostics = HostDiagnostics(
            appVersion: HostInfo.appVersion,
            lanListener: lanListenerMetric(),
            trustedDevices: app.trust.active.count,
            activeSessions: app.connection.sessions.count)
        let collector = SystemHealthCollector(pressure: pressure)
        let s = await collector.collect(host: diagnostics)
        state = .loaded(s)
        history.append(s)
        if history.count > 120 { history.removeFirst(history.count - 120) }
        isRefreshing = false
    }

    private func lanListenerMetric() -> HealthMetric<String> {
        let now = Date()
        switch app.connection.serverState {
        case .listening(let port): return .reported("Listening on port \(port)", source: "Network.framework NWListener", at: now)
        case .failed(let why): return .unavailable("Listener failed: \(why)", source: "Network.framework NWListener", at: now)
        case .stopped: return .unavailable("Not listening (no paired phone yet)", source: "Network.framework NWListener", at: now)
        }
    }

    /// A fresh-enough snapshot for a phone request (refreshes if older than 30 s).
    func snapshotForPeer() async -> HealthSnapshot? {
        if let s = snapshot, Date().timeIntervalSince(s.collectedAt) < 30 { return s }
        await refresh()
        return snapshot
    }

    enum ExportFormat: String, CaseIterable { case markdown = "Markdown", json = "JSON" }

    func export(_ format: ExportFormat) {
        guard let s = snapshot else { return }
        let panel = NSSavePanel()
        let stamp = s.collectedAt.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Mac Health \(stamp).\(format == .json ? "json" : "md")"
        panel.allowedContentTypes = format == .json ? [.json] : [UTType(filenameExtension: "md") ?? .plainText]
        panel.message = "The report is saved locally. It is never sent to a server or AI provider automatically."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let options = app.settings.redaction
            let data = format == .json ? try HealthReport.json(s, options: options) : Data(HealthReport.markdown(s, options: options).utf8)
            try data.write(to: url, options: .atomic)
            exportMessage = "Saved \(url.lastPathComponent)"
            app.activityLog.record(.health, "Exported health report (\(format.rawValue))", detail: options.hidePaths ? "Redacted" : "Not redacted")
        } catch {
            exportMessage = "Couldn’t save the report: \(error.localizedDescription)"
        }
    }

    func previewMarkdown() -> String? {
        snapshot.map { HealthReport.markdown($0, options: app.settings.redaction) }
    }
}

@MainActor
@Observable
final class ActivityStore {
    @ObservationIgnored var app: AppModel!
    private let log: ActivityLog
    private(set) var events: [ActivityEvent] = []
    var filter: Set<ActivityKind> = []

    init(log: ActivityLog) {
        self.log = log
        events = log.all
        log.observe { [weak self] snapshot in
            Task { @MainActor in self?.events = snapshot }
        }
    }

    var filtered: [ActivityEvent] { filter.isEmpty ? events : events.filter { filter.contains($0.kind) } }

    func deleteAll() {
        log.deleteAll()
        events = []
    }
}
