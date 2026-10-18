import AppKit
import Foundation
import MyBuddyCore
import MyBuddyHost
import Observation

/// Root model: owns services and feature stores. Views talk only to stores.
@MainActor
@Observable
final class AppModel {
    let demoMode: Bool
    let identity: (any DeviceIdentity)?
    let identityBackend: IdentityBackend?
    let identityError: String?
    let trust: TrustStore
    let pairingWindow = PairingWindow()
    let activityLog: ActivityLog
    let secrets: any SecretStore
    let folders: FolderAccessStore
    let pressure = MemoryPressureMonitor()
    let injector = InputInjector()
    /// Stay Awake power assertions, held while a phone is connected (see `updateStayAwake`).
    let stayAwake = StayAwake()
    /// Thread-safe handle to the running LAN host, shared by streaming and transfers.
    let serverRef = ServerRef()
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsBox.shared.privacy = AIPrivacySettings(localOnly: settings.localOnly)
            if !demoMode { settings.save() }
            if settings.keepAwakeWhileConnected != oldValue.keepAwakeWhileConnected { updateStayAwake() }
        }
    }

    /// True while Stay Awake is keeping this Mac and its display from idle-sleeping (in demo mode: whenever a phone is shown).
    var isStayingAwake: Bool { settings.keepAwakeWhileConnected && !connection.sessions.isEmpty }

    var selection: AppSection = .overview
    var showInspector = true
    var searchText = ""

    let connection: ConnectionStore
    let health: HealthStore
    let ai: AIStore
    let voice: VoiceStore
    let files: FilesStore
    let activity: ActivityStore
    let screenShare: ScreenShareStore
    let internet: InternetStore
    let notifications: NotificationsStore
    let notes: NotesStore

    init(demoMode: Bool) {
        self.demoMode = demoMode
        var settings = AppSettings.load()
        if demoMode { settings = DemoData.settings }
        self.settings = settings
        SettingsBox.shared.privacy = AIPrivacySettings(localOnly: settings.localOnly)

        if demoMode {
            let demoIdentity = SoftwareIdentity()
            identity = demoIdentity
            identityBackend = .keychainSoftwareKey
            identityError = nil
            trust = TrustStore(storage: InMemoryTrustStorage(DemoData.trustedDevices))
            activityLog = ActivityLog(storage: nil)
            for e in DemoData.activity.reversed() { activityLog.record(e) }
            secrets = InMemorySecretStore()
            folders = FolderAccessStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mybuddy-demo-folders.json"))
        } else {
            do {
                let (id, backend) = try KeychainIdentityStore.loadOrCreate()
                identity = id
                identityBackend = backend
                identityError = nil
            } catch {
                identity = nil
                identityBackend = nil
                identityError = "Couldn’t create this Mac’s identity in the Keychain: \(error)"
            }
            trust = TrustStore(storage: KeychainTrustStorage())
            activityLog = ActivityLog(storage: FileActivityStorage(), retention: TimeInterval(settings.activityRetentionDays) * 86_400)
            secrets = KeychainSecretStore()
            folders = FolderAccessStore()
        }

        activity = ActivityStore(log: activityLog)
        health = HealthStore(demo: demoMode, pressure: pressure)
        ai = AIStore(demo: demoMode)
        voice = VoiceStore(demo: demoMode)
        files = FilesStore(demo: demoMode, folders: folders, serverRef: serverRef, autoSave: settings.saveIncomingFilesAutomatically)
        connection = ConnectionStore(demo: demoMode)
        internet = InternetStore(demo: demoMode)
        notifications = NotificationsStore(demo: demoMode)
        notes = NotesStore(demo: demoMode)
        screenShare = ScreenShareStore(demo: demoMode, injector: injector, serverRef: serverRef,
                                       iceProvider: InternetStore.iceProvider(hostRef: internet.hostRef, serverRef: serverRef))

        // Wire stores to the shared model (stores hold an unowned back-reference).
        activity.app = self
        health.app = self
        ai.app = self
        voice.app = self
        files.app = self
        connection.app = self
        screenShare.app = self
        internet.app = self
        notifications.app = self
        notes.app = self
    }

    /// Starts background services (not in demo/snapshot mode).
    func start() {
        guard !demoMode else { return }
        pressure.start()
        activityLog.record(.security, "MyBuddy started", detail: "Identity: \(identityBackend?.rawValue ?? "unavailable")")
        connection.startIfNeeded()
        internet.startIfNeeded()
        notifications.start()
        files.startClipboardMonitor()
        Task { await health.refresh() }
        Task { await ai.detectAgents() }
    }

    /// Immediately ends every session, disables input and closes the pairing window.
    func emergencyStop() {
        injector.setEnabled(false)
        screenShare.emergencyStop()
        connection.emergencyStop()
        voice.cancel()
        activityLog.record(.security, "Emergency stop", detail: "All sessions closed, screen sharing and remote input stopped")
    }

    /// Holds the Stay Awake assertions exactly while the setting is on and a phone is connected.
    func updateStayAwake() {
        guard !demoMode else { return }
        stayAwake.set(isStayingAwake)
    }

    var hostName: String { demoMode ? "MacBook Air" : (Host.current().localizedName ?? "This Mac") }

    var deviceIdentityLine: String {
        guard let identity else { return "Identity unavailable" }
        return "Device ID \(identity.deviceId.prefix(8))… · \(identityBackend?.rawValue ?? "")"
    }
}
