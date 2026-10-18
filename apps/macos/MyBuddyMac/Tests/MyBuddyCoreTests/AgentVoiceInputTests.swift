import Foundation
import Testing
@testable import MyBuddyCore

@Suite("Coding agents")
struct AgentTests {
    let workspace: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("mybuddy-ws-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    @Test func claudeCodeArgumentsAreLockedDown() throws {
        let read = try AgentArguments.arguments(for: .claudeCode, task: AgentTask(prompt: "secret prompt", workspace: workspace))
        #expect(read.starts(with: ["-p", "--output-format", "stream-json", "--verbose"]))
        #expect(read.contains("--restricted") && read.contains("--strict-mcp-config"))
        #expect(read.split(separator: "--permission-mode").count == 2)
        #expect(read[read.firstIndex(of: "--permission-mode")! + 1] == "plan")
        #expect(read[read.firstIndex(of: "--permission-prompts")! + 1] == "none")
        #expect(!read.contains("secret prompt"), "the prompt goes to stdin, never argv")
        let edit = try AgentArguments.arguments(for: .claudeCode, task: AgentTask(prompt: "p", workspace: workspace, level: .editWorkspace))
        #expect(edit[edit.firstIndex(of: "--permission-mode")! + 1] == "acceptEdits")
    }

    @Test func codexArgumentsAreLockedDown() throws {
        let read = try AgentArguments.arguments(for: .codex, task: AgentTask(prompt: "p", workspace: workspace))
        #expect(read == ["exec", "--json", "--sandbox", "read-only", "-C", workspace.path, "--ephemeral", "-"])
        let edit = try AgentArguments.arguments(for: .codex, task: AgentTask(prompt: "p", workspace: workspace, level: .editWorkspace, allowNonGitWorkspace: true))
        #expect(edit.contains("workspace-write") && edit.contains("--skip-git-repo-check") && edit.last == "-")
    }

    @Test(arguments: AgentArguments.forbidden)
    func forbiddenFlagsAreRejected(_ flag: String) {
        #expect(throws: AgentError.forbiddenArgument(flag)) { try AgentArguments.validate(["-p", flag]) }
        #expect(throws: AgentError.self) { try AgentArguments.validate([flag + "=true"]) }
    }

    @Test func noLevelEverProducesForbiddenFlags() throws {
        for kind in AgentKind.allCases {
            for level in AgentPermissionLevel.allCases {
                let args = try AgentArguments.arguments(for: kind, task: AgentTask(prompt: "p", workspace: workspace, level: level, allowNonGitWorkspace: true))
                #expect(AgentArguments.forbidden.allSatisfy { !args.contains($0) })
            }
        }
    }

    @Test func workspaceMustBeAProjectFolder() {
        #expect(throws: AgentError.self) { try AgentArguments.workspaceCheck(URL(fileURLWithPath: NSHomeDirectory())) }
        #expect(throws: AgentError.self) { try AgentArguments.workspaceCheck(URL(fileURLWithPath: "/")) }
        #expect(throws: AgentError.self) { try AgentArguments.workspaceCheck(URL(fileURLWithPath: "/nonexistent/project")) }
    }

    @Test func authStatusParsingDropsPersonalData() {
        let claude = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"person@example.com","orgId":"org-123","orgName":"Acme","subscriptionType":"max"}"#
        let state = AgentStatusParsing.claudeAuth(json: Data(claude.utf8))
        #expect(state == .signedIn(method: "claude.ai"))
        #expect(!state.title.contains("person@example.com") && !state.title.contains("Acme"))
        #expect(AgentStatusParsing.claudeAuth(json: Data(#"{"loggedIn":false}"#.utf8)) == .signedOut)
        if case .unknown = AgentStatusParsing.claudeAuth(json: Data("garbage".utf8)) {} else { Issue.record("garbage must be unknown") }

        let codex = AgentStatusParsing.codexAuth(output: "Logged in using an API key - sk-proj-***ABCDE\n", exitCode: 0)
        #expect(codex == .signedIn(method: "API key"))
        #expect(AgentStatusParsing.codexAuth(output: "Logged in using ChatGPT\n", exitCode: 0) == .signedIn(method: "ChatGPT"))
        #expect(AgentStatusParsing.codexAuth(output: "Not logged in\n", exitCode: 1) == .signedOut)
    }

    @Test func versionParsing() {
        #expect(AgentStatusParsing.version(from: "2.1.301 (Claude Code)\n") == "2.1.301")
        #expect(AgentStatusParsing.version(from: "codex-cli 0.160.0") == "0.160.0")
        #expect(AgentStatusParsing.version(from: "no version here") == nil)
    }

    @Test func claudeStreamJSONParsing() {
        #expect(ClaudeStreamParser.parse(line: #"{"type":"system","subtype":"init","session_id":"abc","model":"claude-opus-5-5","tools":["Read"]}"#)
                == [.started(sessionId: "abc", model: "claude-opus-5-5")])
        #expect(ClaudeStreamParser.parse(line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at auth.py"},{"type":"tool_use","name":"Edit","input":{"file_path":"/w/auth.py"}}]},"parent_tool_use_id":null}"#)
                == [.assistantText("Looking at auth.py"), .fileChanged(path: "/w/auth.py", kind: "edit")])
        #expect(ClaudeStreamParser.parse(line: #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","total_cost_usd":0.0123,"permission_denials":[{"tool_name":"Bash"}]}"#)
                == [.notice("1 action(s) were denied by the permission mode"), .finished(success: true, summary: "Done.", costUSD: 0.0123)])
        #expect(ClaudeStreamParser.parse(line: #"{"type":"stream_event","event":{}}"#).isEmpty)
        #expect(ClaudeStreamParser.parse(line: "not json").isEmpty)
    }

    @Test func codexJSONLParsing() {
        #expect(CodexStreamParser.parse(line: #"{"type":"thread.started","thread_id":"0199a213"}"#) == [.started(sessionId: "0199a213", model: nil)])
        #expect(CodexStreamParser.parse(line: #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"bash -lc ls","status":"in_progress"}}"#) == [.commandStarted("bash -lc ls")])
        #expect(CodexStreamParser.parse(line: #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Repo looks fine."}}"#) == [.assistantText("Repo looks fine.")])
        #expect(CodexStreamParser.parse(line: #"{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"src/a.ts","kind":"update"}]}}"#) == [.fileChanged(path: "src/a.ts", kind: "update")])
        #expect(CodexStreamParser.parse(line: #"{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122}}"#) == [.finished(success: true, summary: "Turn completed", costUSD: nil)])
        #expect(CodexStreamParser.parse(line: #"{"type":"turn.failed","error":{"message":"sandbox denied"}}"#) == [.finished(success: false, summary: "sandbox denied", costUSD: nil)])
    }
}

@Suite("MyBuddy Voice intents")
struct VoiceTests {
    @Test(arguments: [
        ("Show my Mac battery health.", VoiceIntent.showBatteryHealth),
        ("Start remote screen sharing.", .startScreenSharing),
        ("Open Xcode on my Mac.", .openApp(name: "Xcode")),
        ("Open the Downloads folder.", .openFolder(.downloads)),
        ("open documents", .openFolder(.documents)),
        ("Copy this to my Mac: meeting at 5pm", .sendTextToMac("meeting at 5pm")),
        ("Pause clipboard sync.", .pauseClipboardSync),
        ("Show my system health report.", .showHealthReport),
        ("Switch assistant to my local model.", .switchAssistant(.localModel)),
        ("Summarize the current visible app", .summarizeVisibleApp),
    ])
    func allowlistedCommands(_ phrase: String, _ expected: VoiceIntent) {
        #expect(VoiceIntentParser.parse(phrase) == .intent(expected))
    }

    @Test(arguments: ["Delete everything in Downloads", "run sudo rm -rf /", "open terminal and run a command", "install homebrew",
                      "shut down my mac", "pay my credit card bill", "push the code to github", "erase the disk"])
    func dangerousCommandsAreRejected(_ phrase: String) {
        if case .rejected = VoiceIntentParser.parse(phrase) {} else { Issue.record("\(phrase) must be rejected") }
    }

    @Test func ambiguityAndNoise() {
        #expect(VoiceIntentParser.parse("open") == .clarification("Which app should I open?"))
        #expect(VoiceIntentParser.parse("clipboard") == .clarification("Should I pause or resume clipboard sync?"))
        #expect(VoiceIntentParser.parse("Copy this text to my Mac.") == .clarification("What text should I copy to your Mac?"))
        #expect(VoiceIntentParser.parse("open the photos folder") == .clarification("I can open your Downloads, Documents or Desktop folder."))
        #expect(VoiceIntentParser.parse("uh hmm the weather is nice") == .unrecognized)
        #expect(VoiceIntentParser.parse("") == .unrecognized)
    }

    @Test func riskAndApprovalPolicy() {
        #expect(!VoiceIntent.showBatteryHealth.requiresApproval)
        #expect(VoiceIntent.startScreenSharing.requiresApproval)
        #expect(VoiceIntent.summarizeVisibleApp.risk == .high && VoiceIntent.summarizeVisibleApp.requiredCapability == .aiScreenAnalysis)
        #expect(VoiceIntent.sendTextToMac("x").requiresApproval)
        #expect(!VoiceIntentParser.validate(.openApp(name: "../../bin/sh")))
        #expect(VoiceIntentParser.validate(.openApp(name: "Xcode")))
    }
}

@Suite("Remote input mapping")
struct InputTests {
    @Test func normalizedCoordinatesMapAndClamp() {
        let main = DisplayGeometry(displayId: "1", originX: 0, originY: 0, width: 1440, height: 900)
        #expect(CoordinateMapper.point(x: 0.5, y: 0.5, on: main) == (720, 450))
        #expect(CoordinateMapper.point(x: 0, y: 0, on: main) == (0, 0))
        #expect(CoordinateMapper.point(x: 1, y: 1, on: main) == (1439, 899), "never past the last pixel")
        #expect(CoordinateMapper.point(x: 7, y: -3, on: main) == (1439, 0), "out-of-range input is clamped")
        #expect(CoordinateMapper.point(x: .nan, y: .infinity, on: main) == (0, 0))
        let left = DisplayGeometry(displayId: "2", originX: -1920, originY: -200, width: 1920, height: 1080)
        #expect(CoordinateMapper.point(x: 0.5, y: 0.5, on: left) == (-960, 340), "secondary display with negative origin")
        let n = CoordinateMapper.normalized(x: -960, y: 340, on: left)
        #expect(abs(n.x - 0.5) < 1e-9 && abs(n.y - 0.5) < 1e-9)
    }

    @Test func everyAllowlistedKeyHasAMacKeyCode() {
        for code in EventCatalog.shared.keyCodes {
            #expect(KeyCodeMap.virtualKey(for: code) != nil, "\(code)")
        }
        #expect(KeyCodeMap.virtualKey(for: "KeyA") == 0x00 && KeyCodeMap.virtualKey(for: "Enter") == 0x24)
        #expect(KeyCodeMap.virtualKey(for: "Power") == nil)
    }

    @Test func stuckKeyCleanupAndRateLimits() {
        var tracker = PressedInputTracker()
        tracker.keyDown("ShiftLeft")
        tracker.keyDown("KeyA")
        tracker.keyUp("KeyA")
        tracker.buttonDown("left")
        let released = tracker.releaseAll()
        #expect(released.keys == ["ShiftLeft"] && released.buttons == ["left"])
        #expect(tracker.keys.isEmpty && tracker.buttons.isEmpty)

        var limiter = InputRateLimiter()
        let t0 = Date(timeIntervalSince1970: 100)
        var allowed = 0
        for _ in 0..<25 where limiter.allow(.inputText, now: t0) { allowed += 1 }
        #expect(allowed == 20, "20 text events per second")
        let afterWindow = limiter.allow(.inputText, now: t0.addingTimeInterval(1.01))
        #expect(afterWindow)
        let heartbeat = limiter.allow(.hostHeartbeat, now: t0)
        #expect(heartbeat, "non-input events are not limited here")
    }
}
