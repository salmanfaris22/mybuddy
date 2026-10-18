import Foundation
import MyBuddyCore
import MyBuddyHost

/// User settings persisted locally (Application Support/MyBuddy/settings.json). No secrets.
struct AppSettings: Codable, Equatable {
    var localOnly = false
    var acceptConnections = true
    /// Let paired phones reach this Mac over Tailscale (docs/CONNECTIVITY.md §2).
    var allowTailscale = true
    /// Internet access through your own MyBuddy Connect server (docs/CONNECTIVITY.md §3). Off by default.
    var allowInternet = false
    /// `https://host[:port]` of that server (no secrets — the device key is the credential).
    var connectServer = ""
    /// Phones with internet access: device id → pairing id registered on the server.
    var connectEnrollments: [String: String] = [:]
    /// Also post mirrored phone notifications as macOS notifications (off by default).
    var showPhoneNotificationsOnMac = false
    /// Send MyBuddy's own alerts (battery low, going to sleep) to phones allowed to mirror notifications.
    var sendAlertsToPhone = true
    /// Files a phone sends: ask each time (default) or save to Downloads automatically.
    var saveIncomingFilesAutomatically = false
    /// Stay Awake: keep this Mac and its display from idle-sleeping while a phone is connected (on by default).
    var keepAwakeWhileConnected = true
    var clipboardMode: ClipboardSyncMode = .ask
    var clipboardPaused = false
    var activityRetentionDays = 30
    var voiceRate: Float = 0.5
    var voiceMuted = false
    var voiceIdentifier: String?
    var providers: [ProviderConfig] = ProviderConfig.defaults
    /// Folders paired phones may run coding agents in (phones see only the names; agents still need "Coding agents").
    var phoneAgentWorkspaces: [PhoneAgentWorkspace] = []
    var selectedProviderId = "ollama"
    var healthRefreshSeconds = 60
    var redaction = RedactionOptions()

    static let store = JSONFileStore<AppSettings>(url: AppDirectories.support.appendingPathComponent("settings.json"))

    static func load() -> AppSettings { (try? store.load()) ?? AppSettings() }
    func save() { try? Self.store.save(self) }
}

extension AppSettings {
    /// Tolerant decoding: a settings file written by an older version (missing newer keys) keeps every value
    /// it has instead of failing and silently resetting everything to defaults.
    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localOnly = try c.decodeIfPresent(Bool.self, forKey: .localOnly) ?? localOnly
        acceptConnections = try c.decodeIfPresent(Bool.self, forKey: .acceptConnections) ?? acceptConnections
        allowTailscale = try c.decodeIfPresent(Bool.self, forKey: .allowTailscale) ?? allowTailscale
        allowInternet = try c.decodeIfPresent(Bool.self, forKey: .allowInternet) ?? allowInternet
        connectServer = try c.decodeIfPresent(String.self, forKey: .connectServer) ?? connectServer
        connectEnrollments = try c.decodeIfPresent([String: String].self, forKey: .connectEnrollments) ?? connectEnrollments
        showPhoneNotificationsOnMac = try c.decodeIfPresent(Bool.self, forKey: .showPhoneNotificationsOnMac) ?? showPhoneNotificationsOnMac
        sendAlertsToPhone = try c.decodeIfPresent(Bool.self, forKey: .sendAlertsToPhone) ?? sendAlertsToPhone
        saveIncomingFilesAutomatically = try c.decodeIfPresent(Bool.self, forKey: .saveIncomingFilesAutomatically) ?? saveIncomingFilesAutomatically
        keepAwakeWhileConnected = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeWhileConnected) ?? keepAwakeWhileConnected
        clipboardMode = try c.decodeIfPresent(ClipboardSyncMode.self, forKey: .clipboardMode) ?? clipboardMode
        clipboardPaused = try c.decodeIfPresent(Bool.self, forKey: .clipboardPaused) ?? clipboardPaused
        activityRetentionDays = try c.decodeIfPresent(Int.self, forKey: .activityRetentionDays) ?? activityRetentionDays
        voiceRate = try c.decodeIfPresent(Float.self, forKey: .voiceRate) ?? voiceRate
        voiceMuted = try c.decodeIfPresent(Bool.self, forKey: .voiceMuted) ?? voiceMuted
        voiceIdentifier = try c.decodeIfPresent(String.self, forKey: .voiceIdentifier) ?? voiceIdentifier
        providers = try c.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? providers
        phoneAgentWorkspaces = try c.decodeIfPresent([PhoneAgentWorkspace].self, forKey: .phoneAgentWorkspaces) ?? phoneAgentWorkspaces
        selectedProviderId = try c.decodeIfPresent(String.self, forKey: .selectedProviderId) ?? selectedProviderId
        healthRefreshSeconds = try c.decodeIfPresent(Int.self, forKey: .healthRefreshSeconds) ?? healthRefreshSeconds
        redaction = try c.decodeIfPresent(RedactionOptions.self, forKey: .redaction) ?? redaction
    }
}

/// Typed availability for anything the UI shows (docs/PRODUCT_DESIGN.md §5).
enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case unavailable(String)
    case notAuthorized(String)
    case failed(String)

    var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview, remote, ai, voice, files, notes, notifications, health, activity, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .remote: "Remote Desktop"
        case .ai: "AI Studio"
        case .voice: "Voice"
        case .files: "Files & Clipboard"
        case .notes: "Notes"
        case .notifications: "Notifications"
        case .health: "Mac Health"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "circle.hexagongrid"
        case .remote: "display"
        case .ai: "sparkles"
        case .voice: "waveform"
        case .files: "folder"
        case .notes: "note.text"
        case .notifications: "bell.badge"
        case .health: "heart.text.square"
        case .activity: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}
