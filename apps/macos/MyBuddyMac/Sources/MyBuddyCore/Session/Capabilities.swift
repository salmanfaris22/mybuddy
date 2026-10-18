import Foundation

/// Separately grantable permissions (docs/SECURITY.md §4).
public enum Capability: String, CaseIterable, Sendable, Codable, Hashable {
    case screenView = "screen.view"
    case inputControl = "input.control"
    case appsLaunch = "apps.launch"
    case filesBrowse = "files.browse"
    case filesTransfer = "files.transfer"
    case clipboardSync = "clipboard.sync"
    case notificationsMirror = "notifications.mirror"
    case voiceCommands = "voice.commands"
    case aiChat = "ai.chat"
    case aiAgent = "ai.agent"
    case aiScreenAnalysis = "ai.screen_analysis"
    case healthRead = "health.read"
    case notesSync = "notes.sync"
    /// Exists only so it can be explicitly refused: unattended access is not offered in v1.
    case unattended = "unattended"

    /// Granted to a newly paired phone. Everything else is off until enabled on the Mac.
    public static let defaultGrants: Set<Capability> = [.screenView, .healthRead, .aiChat, .voiceCommands, .clipboardSync, .notesSync]

    /// Capabilities that can never be granted in this version.
    public static let neverGrantable: Set<Capability> = [.unattended]

    public var title: String {
        switch self {
        case .screenView: "View screen"
        case .inputControl: "Control mouse & keyboard"
        case .appsLaunch: "Open apps"
        case .filesBrowse: "Browse shared folders"
        case .filesTransfer: "Send & receive files"
        case .clipboardSync: "Clipboard sync"
        case .notificationsMirror: "Mirror notifications"
        case .voiceCommands: "Voice commands"
        case .aiChat: "AI chat on this Mac"
        case .aiAgent: "Coding agents"
        case .aiScreenAnalysis: "AI screen analysis"
        case .healthRead: "Read Mac health"
        case .notesSync: "Shared notes"
        case .unattended: "Unattended access"
        }
    }

    /// Higher-risk capabilities get extra warnings in the UI.
    public var isSensitive: Bool {
        switch self {
        case .inputControl, .filesBrowse, .filesTransfer, .aiAgent, .aiScreenAnalysis, .unattended: true
        default: false
        }
    }
}

/// The set of capabilities a trusted device holds, enforced on the Mac host.
public struct PermissionGrant: Sendable, Codable, Equatable {
    public private(set) var capabilities: Set<Capability>

    public init(_ capabilities: Set<Capability> = Capability.defaultGrants) {
        self.capabilities = capabilities.subtracting(Capability.neverGrantable)
    }

    public func allows(_ capability: Capability) -> Bool { capabilities.contains(capability) }

    public mutating func set(_ capability: Capability, enabled: Bool) {
        guard !Capability.neverGrantable.contains(capability) else { return }
        if enabled { capabilities.insert(capability) } else { capabilities.remove(capability) }
    }

    /// The subset of `requested` that may be granted for a session.
    public func intersect(requested: [Capability]) -> Set<Capability> {
        capabilities.intersection(requested)
    }
}
