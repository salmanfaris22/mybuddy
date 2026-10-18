import AppKit
import Foundation
import Testing
import MyBuddyCore
@testable import MyBuddyHost

@Suite("Workspace services")
struct WorkspaceServicesTests {
    @Test func pairingQRCodeIsScannable() throws {
        let invitation = PairingInvitation(addresses: ["192.168.1.20:47811"], hostFingerprint: SoftwareIdentity().fingerprint,
                                           secret: Data(repeating: 9, count: 32), expiresAt: Date().addingTimeInterval(120), displayName: "Salman’s MacBook Air")
        let image = try #require(QRCodeRenderer.image(for: invitation.url.absoluteString))
        let decoded = try #require(QRCodeRenderer.decode(image))
        #expect(decoded == invitation.url.absoluteString)
        #expect(try PairingInvitation.parse(decoded) == invitation)
    }

    @Test func appCatalogListsAndSearchesRealApps() {
        let apps = WorkspaceAppCatalog.installedApps()
        #expect(apps.count > 5)
        #expect(apps.contains { $0.bundleId == "com.apple.TextEdit" })
        let results = WorkspaceAppCatalog.search("text", in: apps)
        #expect(results.contains { $0.bundleId == "com.apple.TextEdit" })
        let exact = WorkspaceAppCatalog.search("TextEdit", in: apps)
        #expect(exact.first?.bundleId == "com.apple.TextEdit", "exact name ranks first")
    }

    @Test func grantedFoldersAreTheOnlyBrowsableRoots() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mybuddy-fa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Shared/Docs"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: base.appendingPathComponent("Shared/Docs/a.txt"))
        try Data("secret".utf8).write(to: base.appendingPathComponent("outside.txt"))
        let store = FolderAccessStore(url: base.appendingPathComponent("grants.json"))
        let folder = try store.grant(base.appendingPathComponent("Shared"))
        #expect(folder.id == "shared")
        let entries = try store.list(rootId: folder.id, path: "Docs")
        #expect(entries.first?["name"] == .string("a.txt") && entries.first?["kind"] == .string("file"))
        #expect(throws: PathGuardError.self) { try store.resolve(rootId: folder.id, path: "../outside.txt") }
        #expect(throws: PathGuardError.rootUnavailable) { try store.resolve(rootId: "nope", path: "") }
        #expect(throws: (any Error).self) { try store.grant(URL(fileURLWithPath: NSHomeDirectory())) }
        // Persisted
        #expect(FolderAccessStore(url: base.appendingPathComponent("grants.json")).folder(id: "shared") != nil)
        try store.revoke(id: folder.id)
        #expect(store.all.isEmpty)
    }

    @Test func sharedHomeKeepsHiddenItemsAndLibraryPrivate() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mybuddy-home-\(UUID().uuidString)")
        for dir in ["Documents", "Library/Keychains", ".ssh"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data("k".utf8).write(to: home.appendingPathComponent(".ssh/id_ed25519"))
        try Data("d".utf8).write(to: home.appendingPathComponent("Documents/report.txt"))
        try Data("e".utf8).write(to: home.appendingPathComponent("Documents/.env"))
        let store = FolderAccessStore(url: home.appendingPathComponent("grants.json"), homeDirectory: home.path)
        #expect(throws: (any Error).self) { try store.grant(home) }  // the folder picker still refuses the home folder
        let folder = try store.grantHome()
        #expect(store.homeShared && folder.displayName.hasPrefix("Home"))
        #expect(try store.grantHome().id == folder.id, "sharing twice keeps one entry")
        let names = try store.list(rootId: folder.id, path: "").compactMap { $0["name"]?.stringValue }
        #expect(names.contains("Documents") && !names.contains("Library") && !names.contains(".ssh"))
        #expect(try store.resolve(rootId: folder.id, path: "Documents/report.txt").lastPathComponent == "report.txt")
        #expect(throws: PathGuardError.self) { try store.resolve(rootId: folder.id, path: ".ssh/id_ed25519") }
        #expect(throws: PathGuardError.self) { try store.resolve(rootId: folder.id, path: "Library/Keychains") }
        #expect(throws: PathGuardError.self) { try store.resolve(rootId: folder.id, path: "Documents/.env") }
    }

    @Test func pasteboardMonitorIgnoresItsOwnWrites() {
        // A private, uniquely named pasteboard — the user's real clipboard is never touched.
        let pb = NSPasteboard(name: NSPasteboard.Name("app.mybuddy.tests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let monitor = PasteboardMonitor(pasteboard: pb)
        #expect(monitor.poll() == nil)
        monitor.write("from phone")
        #expect(monitor.poll() == nil, "MyBuddy's own write must not bounce back")
        pb.clearContents()
        pb.setString("typed on the Mac", forType: .string)
        let change = monitor.poll()
        #expect(change?.text == "typed on the Mac")
        #expect(change?.types.contains("public.utf8-plain-text") == true)
        #expect(monitor.poll() == nil, "each change is reported once")
    }

    @Test func inputInjectorIsInertUntilEnabled() {
        let injector = InputInjector()
        #expect(!injector.isEnabled)
        // No events are posted in tests: the injector is disabled (and Accessibility is not granted to the test runner).
        injector.key(code: "KeyA", action: "press", modifiers: [])
        injector.setEnabled(false)
        #expect(!injector.isEnabled)
    }

    @Test func permissionPreflightsNeverPrompt() {
        // These only read state; they must not crash or show UI in a headless test process.
        _ = SystemPermissions.screenRecording
        _ = SystemPermissions.accessibility
        _ = SystemPermissions.microphone
        _ = SystemPermissions.speechRecognition
    }
}
