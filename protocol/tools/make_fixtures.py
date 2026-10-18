#!/usr/bin/env python3
"""Regenerates protocol/fixtures/{valid,invalid}/*.json and manifest.json.

Fixtures are golden inputs for the Swift and Kotlin envelope codecs.
`receiver` names the side that decodes the message: "mac" (sent phone->Mac) or "phone".
Run from anywhere:  python3 -I protocol/tools/make_fixtures.py
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent / "fixtures"
SID = "s_fixture0001"
T = "2026-10-16T08:30:00.000Z"
U1 = "6f1c2b9e-1d2a-4c7e-9a51-3b8f0d2e4a10"
U2 = "0b7e9a44-5c21-4f0e-8d9b-7a6c5e4d3b21"
HOST_ID = "e514356e6546b0b22ebcdd982ec66090"
CLIENT_ID = "da96726356de5002c857434beefe468d"
SHA = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"


def env(t, payload, seq=1, **extra):
    e = {"version": 1, "type": t, "sessionId": SID, "sequence": seq, "sentAt": T, "payload": payload}
    e.update(extra)
    return e


valid = [
    ("pairing.request", "mac", env("pairing.request", {"deviceName": "Vivo X300", "platform": "android", "appVersion": "0.1.0"})),
    ("pairing.approved", "phone", env("pairing.approved", {"hostDeviceId": HOST_ID, "hostName": "MacBook Air", "grantedCapabilities": ["screen.view", "health.read"]}, replyTo=1)),
    ("session.request", "mac", env("session.request", {"requestedCapabilities": ["screen.view", "input.control"], "protocolVersions": [1], "features": ["health", "clipboard"]})),
    ("session.approved", "phone", env("session.approved", {"grantedCapabilities": ["screen.view"], "protocolVersion": 1, "features": ["health"], "heartbeatIntervalMs": 5000})),
    ("session.closed", "phone", env("session.closed", {"reason": "emergency_stop"})),
    ("host.heartbeat", "mac", env("host.heartbeat", {"probe": "p-17", "reply": False}, seq=17)),
    ("host.status", "phone", env("host.status", {"hostName": "MacBook Air", "osVersion": "macOS 26.4.1", "appVersion": "0.1.0", "screenSharing": False, "inputControl": False, "activeCapabilities": ["health.read"]})),
    ("error", "phone", env("error", {"code": "path_denied", "message": "That path is outside the folders you shared.", "retryable": False})),
    ("webrtc.answer", "mac", env("webrtc.answer", {"sdp": "v=0\r\no=- 46117317 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"})),
    ("webrtc.ice", "mac", env("webrtc.ice", {"candidate": "candidate:1 1 udp 2122260223 192.168.1.30 51234 typ host", "sdpMid": "0", "sdpMLineIndex": 0})),
    ("webrtc.ice.end", "phone", env("webrtc.ice", {"endOfCandidates": True})),
    ("webrtc.offer", "phone", env("webrtc.offer", {"sdp": "v=0\r\no=- 4611731 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=sendonly\r\n"})),
    ("screen.start", "mac", env("screen.start", {"quality": "auto", "displayId": "1", "maxFps": 30})),
    ("screen.start.defaults", "mac", env("screen.start", {})),
    ("screen.update", "mac", env("screen.update", {"quality": "low"})),
    ("screen.stop", "mac", env("screen.stop", {"reason": "background"})),
    ("screen.state.starting", "phone", env("screen.state", {"state": "starting", "quality": "auto"}, replyTo=4)),
    ("screen.state.live", "phone", env("screen.state", {"state": "live", "quality": "auto", "tier": "balanced", "displayId": "1", "width": 1280, "height": 800, "fps": 30, "source": "display",
                                                         "displays": [{"displayId": "1", "name": "Built-in Retina Display", "width": 2560, "height": 1600, "main": True}]})),
    ("screen.state.failed", "phone", env("screen.state", {"state": "failed", "reason": "not_authorized", "message": "Allow Screen Recording for MyBuddy on your Mac."})),
    ("input.pointer", "mac", env("input.pointer", {"x": 0.52, "y": 0.38, "displayId": "1", "action": "move"}, seq=1042)),
    ("input.button", "mac", env("input.button", {"button": "left", "action": "doubleClick", "x": 0.1, "y": 0.9, "displayId": "1"})),
    ("input.scroll", "mac", env("input.scroll", {"dx": 0, "dy": -120.5, "unit": "pixel"})),
    ("input.key", "mac", env("input.key", {"code": "KeyC", "action": "press", "modifiers": ["command"]})),
    ("input.text", "mac", env("input.text", {"text": "Hello, Mac! é你好\n"})),
    ("host.app.list.request", "mac", env("host.app.list", {"query": "xco", "limit": 20})),
    ("host.app.list.result", "phone", env("host.app.list", {"apps": [{"bundleId": "com.apple.dt.Xcode", "name": "Xcode", "isRunning": False}]}, replyTo=3)),
    ("host.app.open", "mac", env("host.app.open", {"bundleId": "com.apple.Safari"})),
    ("host.file.list", "mac", env("host.file.list", {"rootId": "downloads", "path": "Invoices/2026"})),
    ("host.file.open.result", "phone", env("host.file.open", {"rootId": "downloads", "path": "a.pdf", "status": "opened"}, replyTo=9)),
    ("file.offer", "mac", env("file.offer", {"transferId": U1, "name": "report.pdf", "size": 2097152, "sha256": SHA, "chunkSize": 65536, "mimeType": "application/pdf"})),
    ("file.chunk", "phone", env("file.chunk", {"transferId": U1, "index": 0, "data": "SGVsbG8"})),
    ("file.request", "mac", env("file.request", {"requestId": U2, "rootId": "downloads", "path": "Invoices/2026/a.pdf"})),
    ("screen.start.smooth", "mac", env("screen.start", {"quality": "smooth", "maxFps": 60})),
    ("notification.posted", "mac", env("notification.posted", {"notificationId": "n_3f2a9c", "appPackage": "com.whatsapp", "appLabel": "WhatsApp",
                                                              "title": "Asha", "postedAt": T, "redaction": "title_only", "category": "msg"})),
    ("notification.posted.from-mac", "phone", env("notification.posted", {"notificationId": "mac_battery_low", "appPackage": "app.mybuddy.mac", "appLabel": "MyBuddy",
                                                                         "title": "Mac battery low", "text": "12% — connect the charger", "postedAt": T, "redaction": "none"})),
    ("notification.removed", "mac", env("notification.removed", {"notificationId": "n_3f2a9c"})),
    ("notes.index", "mac", env("notes.index", {"notes": [{"id": U1, "updatedAt": T, "deleted": False}, {"id": U2, "updatedAt": T, "deleted": True}]})),
    ("notes.put", "phone", env("notes.put", {"id": U1, "text": "Groceries\n- milk\n- coffee ☕", "updatedAt": T, "deleted": False})),
    ("notes.put.tombstone", "mac", env("notes.put", {"id": U2, "text": "", "updatedAt": T, "deleted": True})),
    ("connect.offer", "phone", env("connect.offer", {"serverUrl": "https://connect.example.com", "hostDeviceId": HOST_ID, "createdAt": "2026-10-16T08:30:05.000Z"})),
    ("connect.enroll", "mac", env("connect.enroll", {"clientDeviceId": CLIENT_ID, "createdAt": "2026-10-16T08:30:05.000Z",
                                                    "clientSignature": "MEYCIQC8X7tiyG46_kA4j1O7PZwJ80rcZsfmh-D_7qEgnXuNeAIhAMUTwRUyGiiStVi3vmHmenbX3_ZJLaR3wsng6UmjJCZh"})),
    ("connect.enrolled", "phone", env("connect.enrolled", {"pairingId": "pr_0123456789abcdef", "serverUrl": "https://connect.example.com"}, replyTo=4)),
    ("file.offer.requested", "phone", env("file.offer", {"transferId": U1, "name": "a.pdf", "size": 2097152, "sha256": SHA, "chunkSize": 65536, "requestId": U2})),
    ("file.start", "phone", env("file.start", {"transferId": U1, "fromChunk": 0})),
    ("file.ack", "mac", env("file.ack", {"transferId": U1, "index": 7})),
    ("file.error", "phone", env("file.error", {"transferId": U1, "code": "checksum_mismatch"})),
    ("file.complete", "mac", env("file.complete", {"transferId": U1, "sha256": SHA})),
    ("clipboard.offer", "mac", env("clipboard.offer", {"revisionId": U2, "originDeviceId": CLIENT_ID, "contentHash": SHA, "size": 4, "mime": "text/plain"})),
    ("clipboard.content", "phone", env("clipboard.content", {"revisionId": U2, "text": "test"})),
    ("ai.request", "mac", env("ai.request", {"requestId": U1, "mode": "chat", "messages": [{"role": "user", "text": "Summarize my battery health."}], "contextSources": []})),
    ("ai.request.agent", "mac", env("ai.request", {"requestId": U2, "mode": "agent", "messages": [{"role": "user", "text": "Explain how pairing works in this repo."}],
                                                   "contextSources": [], "agent": {"kind": "claude_code", "workspaceId": "ws_7f3a", "level": "read_only"}})),
    ("session.approved.agents", "phone", env("session.approved", {"grantedCapabilities": ["ai.chat", "ai.agent"], "protocolVersion": 1, "features": [], "heartbeatIntervalMs": 5000,
                                                                 "agentWorkspaces": [{"workspaceId": "ws_7f3a", "name": "my buddy"}], "agents": [{"kind": "claude_code", "ready": True}, {"kind": "codex", "ready": False}]}, replyTo=1)),
    ("ai.delta", "phone", env("ai.delta", {"requestId": U1, "text": "Your battery"})),
    ("ai.complete", "phone", env("ai.complete", {"requestId": U1, "stopReason": "end_turn", "servedBy": "claude-opus-5-5", "usage": {"inputTokens": 120, "outputTokens": 48}})),
    ("voice.transcript", "mac", env("voice.transcript", {"utteranceId": U2, "text": "open the downloads folder", "isFinal": True, "locale": "en-US"})),
    ("voice.intent.proposed", "phone", env("voice.intent.proposed", {"utteranceId": U2, "intentId": "open_folder", "intent": {"kind": "openFolder", "folder": "downloads"}, "requiresApproval": False, "risk": "low"})),
    ("health.snapshot.request", "mac", env("health.snapshot.request", {"sections": ["battery", "storage"]})),
    ("health.snapshot.request.all", "mac", env("health.snapshot.request", {})),
    ("unknown-fields-ignored", "mac", env("host.heartbeat", {"probe": "p", "reply": True, "futureField": {"a": 1}}, futureTopLevel=True)),
]

# (name, receiver, expected error, message object or raw string)
invalid = [
    ("malformed-json", "mac", "malformed_json", '{"version":1,"type":"input.text",'),
    ("not-an-object", "mac", "invalid_envelope", "[1,2,3]"),
    ("missing-type", "mac", "invalid_envelope", {k: v for k, v in env("input.text", {"text": "a"}).items() if k != "type"}),
    ("unsupported-version", "mac", "unsupported_version", {**env("input.text", {"text": "a"}), "version": 2}),
    ("unknown-type", "mac", "unknown_type", env("shell.exec", {"command": "rm -rf ~"})),
    ("bad-session-id", "mac", "invalid_envelope", {**env("input.text", {"text": "a"}), "sessionId": "short"}),
    ("sequence-zero", "mac", "invalid_envelope", env("input.text", {"text": "a"}, seq=0)),
    ("sequence-float", "mac", "invalid_envelope", env("input.text", {"text": "a"}, seq=1.5)),
    ("bad-sent-at", "mac", "invalid_envelope", {**env("input.text", {"text": "a"}), "sentAt": "yesterday"}),
    ("payload-not-object", "mac", "invalid_envelope", {**env("input.text", {"text": "a"}), "payload": "x"}),
    ("pointer-missing-x", "mac", "invalid_payload", env("input.pointer", {"y": 0.5, "displayId": "1", "action": "move"})),
    ("pointer-out-of-range", "mac", "invalid_payload", env("input.pointer", {"x": 1.5, "y": 0.5, "displayId": "1", "action": "move"})),
    ("button-unknown-action", "mac", "invalid_payload", env("input.button", {"button": "left", "action": "tripleClick", "x": 0.5, "y": 0.5, "displayId": "1"})),
    ("key-not-allowlisted", "mac", "invalid_payload", env("input.key", {"code": "Power", "action": "press", "modifiers": []})),
    ("key-bad-modifier", "mac", "invalid_payload", env("input.key", {"code": "KeyA", "action": "press", "modifiers": ["hyper"]})),
    ("text-too-long", "mac", "invalid_payload", env("input.text", {"text": "a" * 257})),
    ("text-control-char", "mac", "invalid_payload", env("input.text", {"text": "a\u0007b"})),
    ("text-empty", "mac", "invalid_payload", env("input.text", {"text": ""})),
    ("app-open-bad-bundle", "mac", "invalid_payload", env("host.app.open", {"bundleId": "../../bin/sh"})),
    ("file-list-nul", "mac", "invalid_payload", env("host.file.list", {"rootId": "downloads", "path": "a\u0000b"})),
    ("file-offer-slash-name", "mac", "invalid_payload", env("file.offer", {"transferId": U1, "name": "../evil.sh", "size": 10, "sha256": SHA, "chunkSize": 65536})),
    ("file-offer-too-large", "mac", "invalid_payload", env("file.offer", {"transferId": U1, "name": "big.iso", "size": 2147483649, "sha256": SHA, "chunkSize": 65536})),
    ("file-offer-bad-uuid", "mac", "invalid_payload", env("file.offer", {"transferId": "not-a-uuid", "name": "a.txt", "size": 10, "sha256": SHA, "chunkSize": 65536})),
    ("file-offer-bad-hash", "mac", "invalid_payload", env("file.offer", {"transferId": U1, "name": "a.txt", "size": 10, "sha256": "XYZ", "chunkSize": 65536})),
    ("clipboard-too-large", "mac", "invalid_payload", env("clipboard.offer", {"revisionId": U2, "originDeviceId": CLIENT_ID, "contentHash": SHA, "size": 65537, "mime": "text/plain"})),
    ("ai-request-no-messages", "mac", "invalid_payload", env("ai.request", {"requestId": U1, "mode": "chat", "messages": [], "contextSources": []})),
    ("wrong-direction", "mac", "wrong_direction", env("pairing.approved", {"hostDeviceId": HOST_ID, "hostName": "x", "grantedCapabilities": []})),
    ("capability-unknown", "phone", "invalid_payload", env("session.approved", {"grantedCapabilities": ["root.shell"], "protocolVersion": 1, "features": [], "heartbeatIntervalMs": 5000})),
    ("too-large-input", "mac", "too_large", env("input.text", {"text": "a"}, padding="x" * 2000)),
    ("screen-start-bad-quality", "mac", "invalid_payload", env("screen.start", {"quality": "ultra"})),
    ("file-request-nul", "mac", "invalid_payload", env("file.request", {"requestId": U2, "rootId": "downloads", "path": "a\u0000b"})),
    ("file-request-no-id", "mac", "invalid_payload", env("file.request", {"rootId": "downloads", "path": "a.pdf"})),
    ("file-request-from-mac", "phone", "wrong_direction", env("file.request", {"requestId": U2, "rootId": "downloads", "path": "a.pdf"})),
    ("file-error-unknown-code", "mac", "invalid_payload", env("file.error", {"transferId": U1, "code": "exploded"})),
    ("screen-start-fps-too-high", "mac", "invalid_payload", env("screen.start", {"maxFps": 240})),
    ("screen-state-unknown-state", "phone", "invalid_payload", env("screen.state", {"state": "recording"})),
    ("screen-state-bad-reason", "phone", "invalid_payload", env("screen.state", {"state": "failed", "reason": "Not Authorized!"})),
    ("screen-state-wrong-direction", "mac", "wrong_direction", env("screen.state", {"state": "live"})),
    ("webrtc-offer-from-phone", "mac", "wrong_direction", env("webrtc.offer", {"sdp": "v=0\r\n"})),
    ("notification-bad-redaction", "mac", "invalid_payload", env("notification.posted", {"notificationId": "n_1", "appPackage": "a", "appLabel": "A", "postedAt": T, "redaction": "secret"})),
    ("notification-text-too-long", "mac", "invalid_payload", env("notification.posted", {"notificationId": "n_1", "appPackage": "a", "appLabel": "A", "text": "x" * 1025, "postedAt": T, "redaction": "none"})),
    ("ai-request-agent-bad-level", "mac", "invalid_payload", env("ai.request", {"requestId": U2, "mode": "agent", "messages": [{"role": "user", "text": "x"}],
                                                                                 "contextSources": [], "agent": {"kind": "claude_code", "workspaceId": "ws_7f3a", "level": "full_access"}})),
    ("notes-put-too-long", "mac", "invalid_payload", env("notes.put", {"id": U1, "text": "x" * 24577, "updatedAt": T, "deleted": False})),
    ("notes-put-not-a-uuid", "phone", "invalid_payload", env("notes.put", {"id": "note-1", "text": "a", "updatedAt": T, "deleted": False})),
    ("connect-enroll-from-mac", "phone", "wrong_direction", env("connect.enroll", {"clientDeviceId": CLIENT_ID, "createdAt": "2026-10-16T08:30:05.000Z", "clientSignature": "MEUCIQ"})),
    ("connect-offer-short-host-id", "phone", "invalid_payload", env("connect.offer", {"serverUrl": "https://connect.example.com", "hostDeviceId": "abc", "createdAt": "2026-10-16T08:30:05.000Z"})),
    ("connect-enroll-signature-too-long", "mac", "invalid_payload", env("connect.enroll", {"clientDeviceId": CLIENT_ID, "createdAt": "2026-10-16T08:30:05.000Z", "clientSignature": "A" * 120})),
]


def main():
    for sub in ("valid", "invalid"):
        d = ROOT / sub
        d.mkdir(parents=True, exist_ok=True)
        for f in d.glob("*.json"):
            f.unlink()
    manifest = {"valid": [], "invalid": []}
    for name, receiver, msg in valid:
        rel = f"valid/{name}.json"
        (ROOT / rel).write_text(json.dumps(msg, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
        manifest["valid"].append({"file": rel, "receiver": receiver, "type": msg["type"]})
    for name, receiver, err, msg in invalid:
        rel = f"invalid/{name}.json"
        text = msg if isinstance(msg, str) else json.dumps(msg, ensure_ascii=False, separators=(",", ":"))
        (ROOT / rel).write_text(text + "\n", encoding="utf-8")
        manifest["invalid"].append({"file": rel, "receiver": receiver, "error": err})
    (ROOT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(valid)} valid and {len(invalid)} invalid fixtures")


if __name__ == "__main__":
    main()
