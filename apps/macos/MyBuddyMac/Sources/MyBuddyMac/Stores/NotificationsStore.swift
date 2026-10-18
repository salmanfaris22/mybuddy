import AppKit
import Foundation
import MyBuddyCore
import MyBuddyHost
import Observation
import UserNotifications

/// Phone notifications mirrored to this Mac (kept in memory only, never written to disk or sent to an AI
/// provider) and MyBuddy's own alerts to the phone (battery low, going to sleep). macOS has no public API to read
/// other apps' notifications, so Mac → phone is limited to MyBuddy's own.
@MainActor
@Observable
final class NotificationsStore {
    @ObservationIgnored var app: AppModel!
    let demo: Bool

    struct PhoneNotification: Identifiable, Equatable {
        let id: String
        let deviceName: String
        let appLabel: String
        let title: String?
        let text: String?
        let redaction: String
        let receivedAt: Date
    }

    private(set) var received: [PhoneNotification] = []
    private(set) var alertsSent: [String] = []
    private(set) var macNotificationsStatus: String?
    @ObservationIgnored private var battery = BatteryAlertPolicy()
    @ObservationIgnored private var batteryTimer: Timer?
    @ObservationIgnored private var sleepObserver: (any NSObjectProtocol)?

    init(demo: Bool) {
        self.demo = demo
        if demo { received = DemoData.phoneNotifications }
    }

    /// Phones currently allowed to mirror notifications.
    var mirroringSessions: [ActiveSessionInfo] { app.connection.sessions.filter { $0.grantedCapabilities.contains(.notificationsMirror) } }

    func start() {
        guard !demo else { return }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkBattery() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sendAlert(id: "mac_sleep", title: "Your Mac is going to sleep", text: "MyBuddy reconnects when it wakes up.") }
        }
    }

    // MARK: phone → Mac

    /// `notification.posted` / `.removed` from a phone allowed to mirror (capability checked by the server).
    func handle(_ e: Envelope, device: TrustedDevice) {
        let id = e.payload["notificationId"]?.stringValue ?? ""
        switch e.type {
        case .notificationPosted:
            let n = PhoneNotification(id: id, deviceName: device.name, appLabel: e.payload["appLabel"]?.stringValue ?? "App",
                                      title: e.payload["title"]?.stringValue, text: e.payload["text"]?.stringValue,
                                      redaction: e.payload["redaction"]?.stringValue ?? "content_hidden", receivedAt: Date())
            received = ([n] + received.filter { $0.id != id }).prefix(100).map { $0 }
            if app.settings.showPhoneNotificationsOnMac { postOnMac(n) }
        case .notificationRemoved:
            received.removeAll { $0.id == id }
            UNUserNotificationCenterIfAvailable()?.removeDeliveredNotifications(withIdentifiers: [id])
        default:
            break
        }
    }

    func clear() { received = [] }

    /// Also show mirrored notifications as macOS notifications (asks macOS for permission the first time).
    func setShowOnMac(_ on: Bool) {
        app.settings.showPhoneNotificationsOnMac = on
        guard on, let center = UNUserNotificationCenterIfAvailable() else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.macNotificationsStatus = granted ? nil : "macOS didn’t allow MyBuddy notifications — change it in System Settings → Notifications."
                if !granted { self.app.settings.showPhoneNotificationsOnMac = false }
            }
        }
    }

    private func postOnMac(_ n: PhoneNotification) {
        guard let center = UNUserNotificationCenterIfAvailable() else { return }
        let content = UNMutableNotificationContent()
        content.title = n.appLabel
        content.subtitle = n.title ?? ""
        content.body = n.text ?? (n.redaction == "content_hidden" ? "New notification on \(n.deviceName)" : "")
        center.add(UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
    }

    /// UNUserNotificationCenter only works inside an app bundle (not in tests or command-line hosts).
    private func UNUserNotificationCenterIfAvailable() -> UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    // MARK: Mac → phone (MyBuddy's own alerts)

    func checkBattery() {
        let b = SystemHealthCollector.currentBattery()
        guard b.present.usableValue == true else { return }
        if battery.evaluate(level: b.levelPercent.usableValue, charging: b.isCharging.usableValue), let level = b.levelPercent.usableValue {
            sendAlert(id: "mac_battery_low", title: "Mac battery low — \(level)%", text: "Connect the charger soon.")
        }
    }

    /// Sends one of MyBuddy's alerts to every connected phone allowed to mirror notifications.
    func sendAlert(id: String, title: String, text: String?) {
        guard app.settings.sendAlertsToPhone, !mirroringSessions.isEmpty else { return }
        var payload: [String: JSONValue] = ["notificationId": .string(id), "appPackage": .string("app.mybuddy.mac"), "appLabel": .string("MyBuddy"),
                                            "title": .string(title), "postedAt": .string(ConnectTime.format(Date())), "redaction": .string("none")]
        if let text { payload["text"] = .string(text) }
        for s in mirroringSessions { app.connection.push(OutgoingEvent(.notificationPosted, payload), toSession: s.id) }
        alertsSent = (["\(title) · \(Date().formatted(date: .omitted, time: .shortened))"] + alertsSent).prefix(10).map { $0 }
    }
}
