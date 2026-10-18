import Foundation
import Testing
@testable import MyBuddyCore

@Suite("Coding agents from the phone")
struct PhoneAgentTests {
    @Test func wireNamesMatchTheCatalog() {
        #expect(PhoneAgentWire.kind("claude_code") == .claudeCode && PhoneAgentWire.kind("codex") == .codex && PhoneAgentWire.kind("gpt") == nil)
        #expect(PhoneAgentWire.level("read_only") == .readOnly && PhoneAgentWire.level("edit_workspace") == .editWorkspace)
        #expect(PhoneAgentWire.level("full_access") == nil, "nothing beyond the Mac's two levels can be asked for")
        #expect(AgentKind.allCases.allSatisfy { PhoneAgentWire.kind(PhoneAgentWire.wire($0)) == $0 })
    }

    @Test func eventsBecomeReadableLinesWithoutRepeatingTheAnswer() {
        let home = NSHomeDirectory()
        #expect(PhoneAgentWire.text(for: .assistantText("Pairing uses MBH1."), sawText: false) == "Pairing uses MBH1.\n")
        #expect(PhoneAgentWire.text(for: .fileChanged(path: "\(home)/p/a.swift", kind: "update"), sawText: true) == "✎ update ~/p/a.swift\n")
        #expect(PhoneAgentWire.text(for: .commandFinished(command: "swift test", exitCode: 0), sawText: true) == nil)
        #expect(PhoneAgentWire.text(for: .finished(success: true, summary: "Pairing uses MBH1.", costUSD: nil), sawText: true) == nil)
        #expect(PhoneAgentWire.text(for: .finished(success: false, summary: "", costUSD: nil), sawText: true) == "\nFailed: the agent stopped\n")
        #expect(PhoneAgentWire.chunks(String(repeating: "a", count: 20_001)).map(\.count) == [8_000, 8_000, 4_001])
    }

    @Test func workspaceIdsFitTheProtocol() {
        let ws = PhoneAgentWorkspace(path: "/tmp/project", name: "project")
        #expect(ws.id.hasPrefix("ws_") && ws.id.count <= 64)
    }
}
