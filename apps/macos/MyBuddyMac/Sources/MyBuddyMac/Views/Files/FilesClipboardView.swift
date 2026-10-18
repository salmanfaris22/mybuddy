import MyBuddyCore
import MyBuddyDesign
import MyBuddyHost
import SwiftUI

struct FilesClipboardView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmShareHome = false

    var body: some View {
        let files = model.files
        Page {
            if let incoming = files.pendingIncoming {
                Panel {
                    HStack(spacing: MBSpace.m) {
                        Image(systemName: "doc.on.clipboard").foregroundStyle(MBColor.info)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(incoming.device) wants to put text on this Mac’s clipboard").font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                            Text("“\(incoming.text.prefix(120))\(incoming.text.count > 120 ? "…" : "")”").font(MBFont.callout).foregroundStyle(MBColor.textSecondary)
                        }
                        Spacer()
                        Button("Ignore") { files.rejectIncoming() }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                        Button("Paste to clipboard") { files.acceptIncoming() }.buttonStyle(MBButtonStyle(.primary, compact: true))
                    }
                }
            }
            if let outgoing = files.pendingOutgoing {
                Panel {
                    HStack(spacing: MBSpace.m) {
                        Image(systemName: "arrow.up.doc.on.clipboard").foregroundStyle(MBColor.info)
                        Text("Send your copied text (\(outgoing.utf8.count) bytes) to the phone?").font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                        Spacer()
                        Button("Not now") { files.dismissPendingOutgoing() }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                        Button("Send") { files.sendPendingOutgoing() }.buttonStyle(MBButtonStyle(.primary, compact: true))
                    }
                }
            }

            AdaptiveColumns {
                Panel {
                    VStack(alignment: .leading, spacing: MBSpace.m) {
                        SectionHeader("Shared folders", subtitle: "Your phone can only browse inside these") {
                            HStack(spacing: MBSpace.s) {
                                if !files.homeShared {
                                    Button { confirmShareHome = true } label: { Label("Share Home Folder", systemImage: "house") }
                                        .buttonStyle(MBButtonStyle(.secondary, compact: true)).disabled(model.demoMode)
                                }
                                Button { files.grantFolder() } label: { Label("Grant Folder Access", systemImage: "folder.badge.plus") }
                                    .buttonStyle(MBButtonStyle(.primary, compact: true)).disabled(model.demoMode)
                            }
                        }
                        if files.granted.isEmpty {
                            StateView(.empty, title: "No folders shared", message: "Choose a folder like Downloads or a project folder. Paths outside it — including symlinks that point elsewhere — are refused.")
                        }
                        ForEach(files.granted) { folder in
                            HStack(spacing: MBSpace.m) {
                                Image(systemName: "folder.fill").foregroundStyle(MBColor.info)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(folder.displayName).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                                    Text(Redactor.redact(folder.path)).font(MBFont.mono).foregroundStyle(MBColor.textTertiary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Button("Browse") { files.load(folder.id, path: "") }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                                Button("Stop sharing") { files.revoke(folder) }.buttonStyle(MBButtonStyle(.danger, compact: true))
                            }
                            .padding(.vertical, MBSpace.xs)
                        }
                        if let error = files.errorMessage { Text(error).font(MBFont.callout).foregroundStyle(MBColor.danger) }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: MBSpace.m) {
                        SectionHeader("Clipboard", subtitle: "Plain text only · up to 64 KB")
                        Picker("Sync mode", selection: Binding(get: { model.settings.clipboardMode }, set: { model.settings.clipboardMode = $0 })) {
                            ForEach(ClipboardSyncMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Toggle("Pause clipboard sync", isOn: Binding(get: { model.settings.clipboardPaused }, set: { model.settings.clipboardPaused = $0 }))
                            .toggleStyle(.switch)
                        Text("Passwords and items marked secret by password managers are never synced automatically. Text that looks like a key or token always asks first.")
                            .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                        if !files.clipboardEvents.isEmpty {
                            Eyebrow("Recent")
                            ForEach(files.clipboardEvents, id: \.self) { Text($0).font(MBFont.callout).foregroundStyle(MBColor.textSecondary) }
                        }
                    }
                }
            }

            if let folderId = files.selectedFolderId, let folder = files.granted.first(where: { $0.id == folderId }) {
                Panel {
                    VStack(alignment: .leading, spacing: MBSpace.s) {
                        SectionHeader("\(folder.displayName)\(files.browsePath.isEmpty ? "" : " / \(files.browsePath)")", subtitle: "What your phone sees")
                        switch files.browse {
                        case .loaded(let entries) where entries.isEmpty:
                            Text("This folder is empty.").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                        case .loaded(let entries):
                            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                                HStack(spacing: MBSpace.m) {
                                    Image(systemName: entry["kind"]?.stringValue == "folder" ? "folder" : "doc").foregroundStyle(MBColor.textSecondary).frame(width: 18)
                                    Text(entry["name"]?.stringValue ?? "").font(MBFont.body).foregroundStyle(MBColor.textPrimary)
                                    Spacer()
                                    if let size = entry["size"]?.intValue { Text(HealthReport.bytes(size)).font(MBFont.callout.monospacedDigit()).foregroundStyle(MBColor.textTertiary) }
                                }
                                .padding(.vertical, 3)
                            }
                        case .failed(let m):
                            Text(m).font(MBFont.callout).foregroundStyle(MBColor.danger)
                        default:
                            Button("Show contents") { files.load(folder.id, path: "") }.buttonStyle(MBButtonStyle(.secondary, compact: true))
                        }
                    }
                }
            }

            TransfersPanel()
        }
        .confirmationDialog("Share your whole Home folder with your phone?", isPresented: $confirmShareHome) {
            Button("Share Home Folder") { files.shareHome() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your paired phones with “Browse shared folders” can then browse and download any file in Desktop, Documents, Downloads, Pictures and your other folders. Hidden items and the Library folder stay private. macOS may ask once for each protected folder. You can stop sharing at any time.")
        }
    }
}

/// Transfers with paired phones: live progress, approvals, pause/resume/cancel, and where finished files went.
struct TransfersPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let files = model.files
        Panel {
            VStack(alignment: .leading, spacing: MBSpace.s) {
                SectionHeader("Transfers", subtitle: "Encrypted end to end · SHA-256 verified") {
                    Button { files.sendFileToPhone() } label: { Label("Send File to Phone…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(MBButtonStyle(.secondary, compact: true))
                        .disabled(model.demoMode || files.transferSessions.isEmpty)
                        .help(files.transferSessions.isEmpty ? "Connect a phone that is allowed to “Send & receive files”" : "Pick a file to send to the phone")
                }
                Toggle("Save files from the phone to Downloads without asking", isOn: Binding(get: { files.autoSave }, set: { files.setAutoSave($0) }))
                    .toggleStyle(.switch).font(MBFont.callout)
                if files.transfers.isEmpty {
                    Text(files.transferSessions.isEmpty
                         ? "No transfers yet. Allow “Send & receive files” for your phone in Settings → Devices to exchange files."
                         : "No transfers yet. Files from your phone are written to a temporary file in Downloads and moved into place only after the checksum matches.")
                        .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                }
                ForEach(files.transfers) { t in TransferRow(item: t) }
                if files.transfers.contains(where: { isFinished($0.state) }) {
                    Button("Clear Finished") { files.transferService.clearFinished() }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                }
            }
        }
    }

    private func isFinished(_ s: TransferState) -> Bool {
        switch s {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let item: TransferService.Item

    var body: some View {
        let service = model.files.transferService
        VStack(alignment: .leading, spacing: MBSpace.xs) {
            HStack(spacing: MBSpace.s) {
                Image(systemName: item.direction == .toMac ? "arrow.down.doc" : "arrow.up.doc").foregroundStyle(MBColor.info)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary).lineLimit(1).truncationMode(.middle)
                    Text("\(item.direction == .toMac ? "From" : "To") \(item.deviceName) · \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                        .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                }
                Spacer()
                Text(stateText).font(MBFont.callout.monospacedDigit()).foregroundStyle(stateTone.color)
                actions(service)
            }
            if showsProgress { UsageBar(fraction: item.state.progress, tone: item.state.progress >= 1 ? .live : .info) }
        }
        .padding(.vertical, MBSpace.xs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func actions(_ service: TransferService) -> some View {
        switch item.state {
        case .awaitingAcceptance where item.direction == .toMac:
            Button("Accept") { service.accept(item.id) }.buttonStyle(MBButtonStyle(.primary, compact: true))
            Button("Decline") { service.decline(item.id) }.buttonStyle(MBButtonStyle(.secondary, compact: true))
        case .inProgress:
            Button { service.pause(item.id) } label: { Image(systemName: "pause.fill") }.buttonStyle(MBButtonStyle(.ghost, compact: true)).help("Pause")
            Button { service.cancel(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(MBButtonStyle(.ghost, compact: true)).help("Cancel")
        case .paused:
            Button { service.resume(item.id) } label: { Image(systemName: "play.fill") }.buttonStyle(MBButtonStyle(.ghost, compact: true)).help("Resume")
            Button { service.cancel(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(MBButtonStyle(.ghost, compact: true)).help("Cancel")
        case .awaitingAcceptance:
            Button { service.cancel(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(MBButtonStyle(.ghost, compact: true)).help("Cancel")
        case .completed(let url) where item.direction == .toMac:
            Button { model.files.revealInFinder(url) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(MBButtonStyle(.ghost, compact: true)).help("Show in Finder")
        default:
            EmptyView()
        }
    }

    private var showsProgress: Bool {
        switch item.state {
        case .inProgress, .paused, .verifying: true
        default: false
        }
    }

    private var stateText: String {
        switch item.state {
        case .completed: item.direction == .toMac ? "Saved · verified" : "Delivered · verified"
        case .inProgress(let r, let t): "\(Int(Double(r) / Double(max(t, 1)) * 100))%"
        case .paused: "Paused"
        case .verifying: "Verifying…"
        case .failed(.checksumMismatch): "Failed · checksum mismatch"
        case .failed(.declined): "Declined on the phone"
        case .failed(.io(let why)) where why == "timeout": "Failed · timed out"
        case .failed(.io(let why)) where why == TransferErrorCode.tooLarge.rawValue: "Failed · too large for the phone"
        case .failed(.io(let why)) where why == TransferErrorCode.diskFull.rawValue: "Failed · phone storage full"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .awaitingAcceptance: item.direction == .toMac ? "Wants to send you this" : "Waiting for the phone"
        }
    }

    private var stateTone: MBTone {
        switch item.state {
        case .completed: .live
        case .failed(.declined): .neutral
        case .failed: .danger
        case .awaitingAcceptance: item.direction == .toMac ? .warning : .neutral
        default: .neutral
        }
    }
}

struct NotificationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.notifications
        Page {
            Panel {
                VStack(alignment: .leading, spacing: MBSpace.m) {
                    SectionHeader("Phone notifications on this Mac", subtitle: statusLine) {
                        if !store.received.isEmpty {
                            Button("Clear") { store.clear() }.buttonStyle(MBButtonStyle(.ghost, compact: true))
                        }
                    }
                    if store.received.isEmpty {
                        StateView(.empty, title: emptyTitle, message: emptyMessage)
                    }
                    ForEach(store.received) { n in
                        HStack(alignment: .top, spacing: MBSpace.m) {
                            Image(systemName: "bell.badge").foregroundStyle(MBColor.info).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: MBSpace.s) {
                                    Text(n.appLabel).font(MBFont.bodyEmphasis).foregroundStyle(MBColor.textPrimary)
                                    Text("\(n.deviceName) · \(n.receivedAt.formatted(date: .omitted, time: .shortened))").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                                }
                                if let title = n.title { Text(title).font(MBFont.body).foregroundStyle(MBColor.textPrimary) }
                                if let text = n.text { Text(text).font(MBFont.callout).foregroundStyle(MBColor.textSecondary).fixedSize(horizontal: false, vertical: true) }
                                if n.redaction == "content_hidden" { Text("Content hidden by the phone’s preview setting").font(MBFont.callout).foregroundStyle(MBColor.textTertiary) }
                                if n.redaction == "partial" { Text("Codes or keys were masked on the phone").font(MBFont.callout).foregroundStyle(MBColor.textTertiary) }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .accessibilityElement(children: .combine)
                    }
                    Toggle("Also show them as macOS notifications", isOn: Binding(get: { model.settings.showPhoneNotificationsOnMac }, set: { store.setShowOnMac($0) }))
                        .toggleStyle(.switch).font(MBFont.body).disabled(model.demoMode)
                    if let why = store.macNotificationsStatus { Text(why).font(MBFont.callout).foregroundStyle(MBColor.warning) }
                    Text("Kept in memory only while MyBuddy runs — never written to disk and never sent to an AI provider.")
                        .font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
                }
            }
            AdaptiveColumns {
                Panel {
                    VStack(alignment: .leading, spacing: MBSpace.s) {
                        SectionHeader("Controls on the phone")
                        ForEach(["Android notification access — you enable it in Android’s settings",
                                 "Master switch, off by default",
                                 "Preview: app name only (default), title, or title and text",
                                 "Codes, keys and card numbers masked; ongoing and silent ones never sent",
                                 "Per-app filters and a pause while Do Not Disturb is on"], id: \.self) {
                            Label($0, systemImage: "checkmark.circle").font(MBFont.callout).foregroundStyle(MBColor.textSecondary)
                        }
                        Text("Here: allow “Mirror notifications” for the phone in Settings → Devices & permissions.")
                            .font(MBFont.callout).foregroundStyle(MBColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: MBSpace.s) {
                        SectionHeader("From this Mac to the phone")
                        Text("macOS has no public API to read other apps’ notifications, so MyBuddy sends only its own alerts: battery low and going to sleep.")
                            .font(MBFont.callout).foregroundStyle(MBColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                        Toggle("Send MyBuddy alerts to the phone", isOn: Binding(get: { model.settings.sendAlertsToPhone }, set: { model.settings.sendAlertsToPhone = $0 }))
                            .toggleStyle(.switch).font(MBFont.body)
                        ForEach(store.alertsSent, id: \.self) { Text($0).font(MBFont.callout).foregroundStyle(MBColor.textSecondary) }
                    }
                }
            }
        }
    }

    private var statusLine: String {
        let sessions = model.notifications.mirroringSessions
        if let s = sessions.first { return "Mirroring from \(s.deviceName)" }
        if model.connection.activeSession != nil { return "Connected phone isn’t allowed to mirror notifications" }
        return "No phone connected"
    }

    private var emptyTitle: String { model.notifications.mirroringSessions.isEmpty ? "Not mirroring" : "No notifications yet" }

    private var emptyMessage: String {
        model.notifications.mirroringSessions.isEmpty
            ? "Turn it on in MyBuddy on the phone (Settings → Notifications on your Mac) and allow “Mirror notifications” for it here in Settings → Devices & permissions."
            : "New notifications from the phone appear here while it’s connected."
    }
}

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        let activity = model.activity
        Page {
            HStack(spacing: MBSpace.s) {
                ForEach(ActivityKind.allCases, id: \.self) { kind in
                    Button {
                        if activity.filter.contains(kind) { activity.filter.remove(kind) } else { activity.filter.insert(kind) }
                    } label: { Chip(kind.title, selected: activity.filter.contains(kind)) }
                        .buttonStyle(.plain)
                }
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete history", systemImage: "trash") }
                    .buttonStyle(MBButtonStyle(.danger, compact: true)).disabled(activity.events.isEmpty)
            }
            Panel {
                VStack(alignment: .leading, spacing: MBSpace.xs) {
                    if activity.filtered.isEmpty {
                        StateView(.empty, title: "No activity", message: "Sessions, pairing, transfers, clipboard, AI and voice actions appear here. MyBuddy records what happened — never clipboard text, prompts, transcripts or file contents.")
                    }
                    ForEach(activity.filtered) { e in
                        ActivityRow(event: e)
                        if e.id != activity.filtered.last?.id { Divider().overlay(MBColor.border.opacity(0.5)) }
                    }
                }
            }
            Text("Kept on this Mac for \(model.settings.activityRetentionDays) days.").font(MBFont.callout).foregroundStyle(MBColor.textTertiary)
        }
        .confirmationDialog("Delete all activity history?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { activity.deleteAll() }
        } message: { Text("This removes the local log on this Mac. It can’t be undone.") }
    }
}
