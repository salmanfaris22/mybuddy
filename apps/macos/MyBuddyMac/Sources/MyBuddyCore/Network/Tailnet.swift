import Foundation

/// Tailscale address rules (docs/CONNECTIVITY.md §2, §5). Tailscale gives every device an IPv4 from
/// 100.64.0.0/10 and an IPv6 from fd7a:115c:a1e0::/48; MagicDNS names end in `.ts.net`.
public enum Tailnet {
    /// The Mac's own tailnet interface, as seen in its interface addresses.
    public struct Interface: Sendable, Equatable {
        public let name: String
        public let ipv4: String
        public let ipv6: String?
        /// True when the interface also carries a Tailscale-specific fd7a:115c:a1e0::/48 address, which tells
        /// Tailscale apart from other users of the shared 100.64.0.0/10 range (carrier-grade NAT, other VPNs).
        public var confirmed: Bool { ipv6 != nil }

        public init(name: String, ipv4: String, ipv6: String?) {
            self.name = name
            self.ipv4 = ipv4
            self.ipv6 = ipv6
        }
    }

    public static func isTailnetIPv4(_ host: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, host, &addr) == 1 else { return false }
        let bytes = withUnsafeBytes(of: addr.s_addr) { Array($0) }  // network byte order
        return bytes[0] == 100 && (64...127).contains(bytes[1])
    }

    public static func isTailnetIPv6(_ host: String) -> Bool {
        var addr = in6_addr()
        let bare = host.split(separator: "%").first.map(String.init) ?? host
        guard inet_pton(AF_INET6, bare.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), &addr) == 1 else { return false }
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        return bytes.prefix(6).elementsEqual([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
    }

    public static func isTailnetAddress(_ host: String) -> Bool { isTailnetIPv4(host) || isTailnetIPv6(host) }

    /// `name.tailnet.ts.net`-style MagicDNS name (syntax only; the phone must still resolve it into the tailnet ranges).
    public static func isMagicDNSName(_ host: String) -> Bool {
        let h = host.lowercased()
        guard h.hasSuffix(".ts.net"), h.count <= 253 else { return false }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 4 else { return false }  // machine.tailnet.ts.net
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    /// Finds the tailnet interface among `interface name → addresses`, preferring one confirmed by its IPv6.
    public static func detect(_ byInterface: [String: [String]]) -> Interface? {
        let candidates: [Interface] = byInterface.compactMap { name, addresses in
            guard let v4 = addresses.sorted().first(where: isTailnetIPv4) else { return nil }
            return Interface(name: name, ipv4: v4, ipv6: addresses.sorted().first(where: isTailnetIPv6).map { $0.split(separator: "%").first.map(String.init) ?? $0 })
        }
        return candidates.sorted { ($0.confirmed ? 0 : 1, $0.name) < ($1.confirmed ? 0 : 1, $1.name) }.first
    }
}
