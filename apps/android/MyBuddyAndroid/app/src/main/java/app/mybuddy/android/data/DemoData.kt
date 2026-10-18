package app.mybuddy.android.data

import java.time.Instant

/**
 * Preview fixtures (Settings → Preview data, or `--ez demo true`). Every screen showing them
 * also shows the "Preview data" badge; production state never comes from here.
 */
object DemoData {
    private val now: Instant get() = Instant.now()

    val host = PairedHost("e514356e6546b0b22ebcdd982ec66090", "PREVIEW-FINGERPRINT", "MacBook Air", listOf("192.168.1.20:47811"), 1_792_000_000)

    val session = SessionInfo(
        granted = setOf("screen.view", "health.read", "ai.chat", "voice.commands", "clipboard.sync", "files.browse", "input.control"),
        sharedFolders = listOf("downloads" to "Downloads", "projects" to "Projects"),
        hostName = "MacBook Air",
    )

    val health = HealthView(
        collectedAt = "09:41", isPreview = true, batteryPercent = 81, charging = false,
        batteryRows = listOf(
            HealthRow("Power source", "Battery Power", "IOKit IOPSCopyPowerSourcesInfo", null, true),
            HealthRow("Time remaining", "5 h 12 min", "IOKit IOPSCopyPowerSourcesInfo", null, true),
            HealthRow("Condition", "Normal", "system_profiler SPPowerDataType", null, true),
            HealthRow("Cycle count", "412", "system_profiler SPPowerDataType", null, true),
            HealthRow("Maximum capacity", "88%", "system_profiler SPPowerDataType", null, true),
        ),
        volumes = listOf(VolumeView("Macintosh HD", "61.4 GB", "245.1 GB", 0.75f)),
        systemRows = listOf(
            HealthRow("Memory in use", "5.9 GB", "host_statistics64", "Derived: (internal − purgeable) + wired + compressed", true),
            HealthRow("Memory pressure", "Normal", "DispatchSource memory-pressure events", "Estimate — No pressure events since MyBuddy started", true),
            HealthRow("CPU (all cores)", "14.2%", "host_processor_info", "Derived: Δbusy ÷ Δtotal ticks over 1 s", true),
            HealthRow("Thermal state", "Nominal", "ProcessInfo.thermalState", null, true),
            HealthRow("Temperatures & fans", "Unavailable", "—", "No supported public API on Apple Silicon", false),
            HealthRow("macOS", "macOS 26.4.1 (25E253)", "ProcessInfo.operatingSystemVersion", null, true),
            HealthRow("Uptime", "3 d 4 h", "sysctl kern.boottime", null, true),
        ),
    )

    val chat = listOf(
        ChatTurn("d1", true, "Is my Mac's battery healthy enough to skip a replacement this year?"),
        ChatTurn("d2", false, "Probably, yes. macOS reports the condition as Normal with 88% maximum capacity after 412 cycles — well above the 80% replacement threshold.",
            ChatTurn.Status.Complete, "claude-opus-5-5"),
    )

    val activity: List<ActivityItem>
        get() = listOf(
            ActivityItem(ActivityKind.Session, "Connected to MacBook Air", "Encrypted · LAN", now.minusSeconds(40)),
            ActivityItem(ActivityKind.Voice, "“Show my Mac battery health”", "succeeded", now.minusSeconds(900)),
            ActivityItem(ActivityKind.Ai, "Asked Anthropic API", "Ran on the Mac", now.minusSeconds(1900)),
            ActivityItem(ActivityKind.Files, "Opened a file on the Mac", "opened", now.minusSeconds(4000)),
            ActivityItem(ActivityKind.Pairing, "Paired with MacBook Air", "Code confirmed on the Mac", now.minusSeconds(86_400)),
        )

    val files = listOf(
        FileEntry("Invoices", true, null),
        FileEntry("Quarterly report.pdf", false, 2_204_311),
        FileEntry("Screenshot 2026-10-15.png", false, 842_113),
        FileEntry("notes.md", false, 3_412),
    )

    val voice = VoiceResult("Show my Mac battery health", "succeeded", "Battery at 81 percent, condition Normal, 412 cycles, maximum capacity 88 percent.")
}
