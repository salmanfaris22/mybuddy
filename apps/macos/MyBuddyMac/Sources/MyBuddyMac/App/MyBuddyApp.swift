import AppKit
import MyBuddyCore
import MyBuddyDesign
import MyBuddyHost
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated {
                SnapshotRunner.run(to: URL(fileURLWithPath: args[i + 1]), reduceMotion: args.contains("--reduce-motion"))
            }
        } else if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            MainActor.assumeIsolated { SnapshotRunner.renderIcon(to: URL(fileURLWithPath: args[i + 1])) }
        } else {
            MyBuddyApp.main()
        }
    }
}

struct MyBuddyApp: App {
    @State private var model = AppModel(demoMode: CommandLine.arguments.contains("--demo"))

    var body: some Scene {
        WindowGroup("MyBuddy", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 640)
                .task { model.start() }
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Session") {
                Button("Pair a Phone…") { model.connection.openPairing() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Emergency Stop") { model.emergencyStop() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.selection = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }
}

/// Renders every section in Preview mode to PNG (offscreen-capable, no Screen Recording permission needed).
@MainActor
enum SnapshotRunner {
    static func run(to dir: URL, reduceMotion: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written: [String] = []
        for section in AppSection.allCases {
            let model = AppModel(demoMode: true)
            model.selection = section
            model.connection.reloadDevices()
            let view = RootView().environment(model).preferredColorScheme(.dark)
            if let png = render(view, size: NSSize(width: 1320, height: 860)) {
                let url = dir.appendingPathComponent("mac-\(String(format: "%02d", AppSection.allCases.firstIndex(of: section)! + 1))-\(section.rawValue).png")
                try? png.write(to: url)
                written.append(url.lastPathComponent)
            }
        }
        // Narrow window to check the responsive layout.
        let narrow = AppModel(demoMode: true)
        narrow.showInspector = false
        if let png = render(RootView().environment(narrow).preferredColorScheme(.dark), size: NSSize(width: 1000, height: 700)) {
            try? png.write(to: dir.appendingPathComponent("mac-10-overview-narrow.png"))
            written.append("mac-10-overview-narrow.png")
        }
        // Pairing approval sheet.
        let pairing = AppModel(demoMode: true)
        pairing.connection.pendingApproval = PairingApprovalRequest(deviceName: "Vivo X300", platform: "android", deviceId: DemoData.phone.deviceId,
                                                                    appVersion: "0.1.0", verificationCode: "607273", remoteAddress: "192.168.1.34")
        if let png = render(PairingSheet().environment(pairing).preferredColorScheme(.dark), size: NSSize(width: 560, height: 640)) {
            try? png.write(to: dir.appendingPathComponent("mac-11-pairing-approval.png"))
            written.append("mac-11-pairing-approval.png")
        }
        let qr = AppModel(demoMode: true)
        qr.connection.openPairing()
        if let png = render(PairingSheet().environment(qr).preferredColorScheme(.dark), size: NSSize(width: 560, height: 640)) {
            try? png.write(to: dir.appendingPathComponent("mac-12-pairing-qr.png"))
            written.append("mac-12-pairing-qr.png")
        }
        // Settings → Connections (below the fold in the full Settings snapshot).
        let connections = AppModel(demoMode: true)
        connections.connection.reloadDevices()
        if let png = render(ConnectionsSettings().padding(MBSpace.l).frame(width: 900, height: 560, alignment: .top).background(MBColor.base)
                                .environment(connections).preferredColorScheme(.dark),
                            size: NSSize(width: 900, height: 560)) {
            try? png.write(to: dir.appendingPathComponent("mac-13-connections.png"))
            written.append("mac-13-connections.png")
        }
        print("snapshots: \(written.joined(separator: ", "))")
        exit(written.isEmpty ? 1 : 0)
    }

    static func render<V: View>(_ view: V, size: NSSize) -> Data? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep.representation(using: .png, properties: [:])
    }

    /// Renders the brand mark as an .iconset for scripts/build-app.sh.
    static func renderIcon(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (size, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
                             (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
            let s = CGFloat(size)
            let icon = ZStack {
                RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x1A212B), Color(hex: 0x0A0C10)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: s * 0.225, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: max(1, s * 0.006)))
                BrandMark(size: s * 0.62)
            }
            .frame(width: s * 0.82, height: s * 0.82)
            .frame(width: s, height: s)
            let renderer = ImageRenderer(content: icon)
            renderer.scale = 1
            if let cg = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("icon_\(name).png"))
            }
        }
        exit(0)
    }
}
