import AppKit
import Foundation
import MyBuddyCore

/// Whether Tailscale can carry MyBuddy's connection from other locations (docs/CONNECTIVITY.md §2).
/// Read-only: inspects this Mac's interface addresses and whether the app is installed — it never runs
/// or configures Tailscale.
public struct TailscaleStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Up, with this Mac's tailnet address. `confirmed` = the interface also has a fd7a:115c:a1e0::/48 address.
        case connected(Tailnet.Interface)
        case installedNotConnected
        case notInstalled
    }

    public let state: State
    public let appURL: URL?

    public static let downloadURL = URL(string: "https://tailscale.com/download/macos")!
    /// Standalone (recommended) and Mac App Store variants (Tailscale KB 1065).
    static let bundleIdentifiers = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]
    /// The open-source CLI-only variant has no app bundle.
    static let cliPaths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]

    public init(state: State, appURL: URL?) {
        self.state = state
        self.appURL = appURL
    }

    /// Tailscale's own service address ("quad-100"); routed into the tunnel only while Tailscale is running.
    static let serviceAddress = "100.100.100.100"

    public static func current() -> TailscaleStatus {
        let appURL = bundleIdentifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        let installed = appURL != nil || cliPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
        return evaluate(interfaces: SystemHealthCollector.interfaceAddresses(), installed: installed,
                        routedSource: routedSourceAddress(to: serviceAddress), appURL: appURL)
    }

    /// Pure decision, for tests. The tunnel interface keeps its addresses while Tailscale is stopped, so it counts
    /// as connected only when traffic to the tailnet actually leaves from that address (`routedSource`). An
    /// unconfirmed 100.64/10 address (no fd7a:115c:a1e0::/48 sibling) also needs the app to be installed.
    public static func evaluate(interfaces: [String: [String]], installed: Bool, routedSource: String?, appURL: URL? = nil) -> TailscaleStatus {
        if let tailnet = Tailnet.detect(interfaces), tailnet.confirmed || installed, routedSource == tailnet.ipv4 {
            return TailscaleStatus(state: .connected(tailnet), appURL: appURL)
        }
        let present = installed || Tailnet.detect(interfaces)?.confirmed == true
        return TailscaleStatus(state: present ? .installedNotConnected : .notInstalled, appURL: appURL)
    }

    /// The local address the kernel would use to reach `ip` (UDP `connect` sends no packet), or nil.
    static func routedSourceAddress(to ip: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET, ip, &remote.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public var address: String? {
        if case .connected(let i) = state { return i.ipv4 }
        return nil
    }
}
