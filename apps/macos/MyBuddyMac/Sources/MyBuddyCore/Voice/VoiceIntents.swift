import Foundation

public enum IntentRisk: String, Codable, Sendable, Comparable {
    case low, medium, high
    public static func < (a: IntentRisk, b: IntentRisk) -> Bool {
        let order: [IntentRisk] = [.low, .medium, .high]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

public enum FolderTarget: String, Codable, Sendable, CaseIterable {
    case downloads, documents, desktop
}

public enum AssistantTarget: String, Codable, Sendable {
    case localModel, anthropic, openAI
    public var title: String {
        switch self {
        case .localModel: "your local model"
        case .anthropic: "the Anthropic API"
        case .openAI: "the OpenAI API"
        }
    }
}

/// The small, typed allowlist of things MyBuddy Voice can do. Nothing else is executable.
public enum VoiceIntent: Sendable, Equatable, Codable {
    case showBatteryHealth
    case showHealthReport
    case startScreenSharing
    case openApp(name: String)
    case openFolder(FolderTarget)
    case sendTextToMac(String)
    case pauseClipboardSync
    case resumeClipboardSync
    case switchAssistant(AssistantTarget)
    case summarizeVisibleApp

    public var intentId: String {
        switch self {
        case .showBatteryHealth: "show_battery_health"
        case .showHealthReport: "show_health_report"
        case .startScreenSharing: "start_screen_sharing"
        case .openApp: "open_app"
        case .openFolder: "open_folder"
        case .sendTextToMac: "send_text_to_mac"
        case .pauseClipboardSync: "pause_clipboard"
        case .resumeClipboardSync: "resume_clipboard"
        case .switchAssistant: "switch_assistant"
        case .summarizeVisibleApp: "summarize_visible_app"
        }
    }

    public var risk: IntentRisk {
        switch self {
        case .showBatteryHealth, .showHealthReport, .openApp, .openFolder, .pauseClipboardSync, .resumeClipboardSync, .switchAssistant: .low
        case .startScreenSharing, .sendTextToMac: .medium
        case .summarizeVisibleApp: .high
        }
    }

    /// Medium and high risk intents always need an explicit confirmation on the Mac.
    public var requiresApproval: Bool { risk >= .medium }

    public var requiredCapability: Capability {
        switch self {
        case .showBatteryHealth, .showHealthReport: .healthRead
        case .startScreenSharing: .screenView
        case .openApp: .appsLaunch
        case .openFolder: .filesBrowse
        case .sendTextToMac, .pauseClipboardSync, .resumeClipboardSync: .clipboardSync
        case .switchAssistant: .aiChat
        case .summarizeVisibleApp: .aiScreenAnalysis
        }
    }

    public var title: String {
        switch self {
        case .showBatteryHealth: "Show battery health"
        case .showHealthReport: "Show the system health report"
        case .startScreenSharing: "Start remote screen sharing"
        case .openApp(let name): "Open \(name)"
        case .openFolder(let f): "Open the \(f.rawValue.capitalized) folder"
        case .sendTextToMac(let t): "Copy “\(t.prefix(40))\(t.count > 40 ? "…" : "")” to the Mac clipboard"
        case .pauseClipboardSync: "Pause clipboard sync"
        case .resumeClipboardSync: "Resume clipboard sync"
        case .switchAssistant(let target): "Switch the assistant to \(target.title)"
        case .summarizeVisibleApp: "Summarize the visible app (sends a screenshot to your AI provider)"
        }
    }
}

public enum VoiceParseResult: Sendable, Equatable {
    case intent(VoiceIntent)
    case clarification(String)
    case rejected(String)
    case unrecognized
}

/// Deterministic, rule-based intent extraction. Model output is never executed directly;
/// even an AI-proposed intent must pass `VoiceIntentParser.validate`.
public enum VoiceIntentParser {
    static let dangerous = ["delete", "erase", "wipe", "format", "remove", "rm ", "sudo", "shell", "terminal", "command line",
                            "run command", "execute", "install", "uninstall", "shut down", "shutdown", "restart", "reboot",
                            "kill", "password", "passcode", "pay ", "payment", "purchase", "buy ", "transfer money", "send money",
                            "email ", "post ", "tweet", "commit", "push "]

    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: "’", with: "'")
        let kept = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    public static func parse(_ transcript: String) -> VoiceParseResult {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .unrecognized }
        guard raw.count <= 500 else { return .rejected("That was too long for a voice command.") }
        let t = " " + normalize(raw) + " "

        // "Copy … to my Mac" carries free text, so extract it before the danger scan of the command words.
        if let text = extractSendText(raw) {
            return text.isEmpty ? .clarification("What text should I copy to your Mac?") : .intent(.sendTextToMac(text))
        }
        if let word = dangerous.first(where: { t.contains(" " + $0) }) {
            return .rejected("MyBuddy Voice can’t do that (“\(word.trimmingCharacters(in: .whitespaces))”). Use the Mac directly for anything destructive, financial or administrative.")
        }
        if t.contains(" battery") { return .intent(.showBatteryHealth) }
        if t.contains(" health report") || t.contains(" system report") || t.contains(" system health") || t.contains(" mac health") {
            return .intent(.showHealthReport)
        }
        if (t.contains(" screen") && (t.contains(" share") || t.contains(" sharing") || t.contains(" remote"))) || t.contains(" view desktop") {
            return .intent(.startScreenSharing)
        }
        if t.contains(" clipboard") {
            if t.contains(" pause") || t.contains(" stop") || t.contains(" turn off") { return .intent(.pauseClipboardSync) }
            if t.contains(" resume") || t.contains(" start") || t.contains(" turn on") { return .intent(.resumeClipboardSync) }
            return .clarification("Should I pause or resume clipboard sync?")
        }
        if t.contains(" switch ") || t.contains(" use ") || t.contains(" change ") {
            if t.contains(" local") || t.contains(" ollama") { return .intent(.switchAssistant(.localModel)) }
            if t.contains(" claude") || t.contains(" anthropic") { return .intent(.switchAssistant(.anthropic)) }
            if t.contains(" openai") || t.contains(" chatgpt") || t.contains(" gpt") { return .intent(.switchAssistant(.openAI)) }
        }
        if t.contains(" summarize") || t.contains(" summarise") {
            if t.contains(" app") || t.contains(" screen") || t.contains(" window") { return .intent(.summarizeVisibleApp) }
        }
        if let opened = openTarget(t) {
            var target = opened
            for prefix in ["the ", "my "] where target.hasPrefix(prefix) { target = String(target.dropFirst(prefix.count)) }
            let isFolderPhrase = (" " + target + " ").contains(" folder ")
            let base = (" " + target + " ").replacingOccurrences(of: " folder ", with: " ")
                .replacingOccurrences(of: " on my mac ", with: " ").trimmingCharacters(in: .whitespaces)
            if let folder = FolderTarget(rawValue: base) { return .intent(.openFolder(folder)) }
            if isFolderPhrase { return .clarification("I can open your Downloads, Documents or Desktop folder.") }
            let name = cleanAppName(opened)
            if name.isEmpty { return .clarification("Which app should I open?") }
            return .intent(.openApp(name: name))
        }
        if t.trimmingCharacters(in: .whitespaces) == "open" || t.trimmingCharacters(in: .whitespaces) == "launch" {
            return .clarification("Which app should I open?")
        }
        return .unrecognized
    }

    /// Validates an intent proposed by anything other than this parser (e.g. an AI model).
    public static func validate(_ intent: VoiceIntent) -> Bool {
        switch intent {
        case .openApp(let name): name.count <= 60 && !name.contains("/") && !name.isEmpty
        case .sendTextToMac(let text): !text.isEmpty && text.utf8.count <= ClipboardPolicy.maxBytes
        default: true
        }
    }

    private static func openTarget(_ t: String) -> String? {
        for verb in [" open ", " launch ", " start "] {
            if let r = t.range(of: verb) {
                let rest = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
                return rest
            }
        }
        return nil
    }

    private static func cleanAppName(_ s: String) -> String {
        var name = " " + s + " "
        for filler in [" on my mac ", " on the mac ", " on mac ", " for me ", " please ", " the app ", " app ", " the "] {
            name = name.replacingOccurrences(of: filler, with: " ")
        }
        return name.trimmingCharacters(in: .whitespaces).split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func extractSendText(_ raw: String) -> String? {
        let lower = raw.lowercased()
        for prefix in ["copy this to my mac", "copy this text to my mac", "send this to my mac", "copy to my mac", "send to my mac"] {
            if lower.hasPrefix(prefix) {
                return String(raw.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.:,;!?\"'“”"))
            }
        }
        if lower.hasPrefix("copy "), let r = lower.range(of: " to my mac") {
            let start = raw.index(raw.startIndex, offsetBy: 5)
            let end = raw.index(raw.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))
            return start <= end ? String(raw[start..<end]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”")) : ""
        }
        return nil
    }
}

/// Visible, cancellable stages of a voice interaction.
public enum VoicePipelineState: Sendable, Equatable {
    case idle
    case listening(partial: String)
    case understanding(transcript: String)
    case awaitingApproval(VoiceIntent, transcript: String)
    case executing(VoiceIntent)
    case speaking(String)
    case finished(VoiceOutcome)
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .idle, .finished, .failed: false
        default: true
        }
    }
}

public struct VoiceOutcome: Sendable, Equatable {
    public enum Status: String, Sendable { case succeeded, failed, denied, needsPermission, unrecognized, rejected, clarification }
    public let transcript: String
    public let intent: VoiceIntent?
    public let status: Status
    public let summary: String

    public init(transcript: String, intent: VoiceIntent?, status: Status, summary: String) {
        self.transcript = transcript
        self.intent = intent
        self.status = status
        self.summary = summary
    }
}
