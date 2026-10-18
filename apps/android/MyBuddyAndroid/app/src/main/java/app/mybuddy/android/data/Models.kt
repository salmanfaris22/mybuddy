package app.mybuddy.android.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

/** Typed availability for everything the UI shows (docs/PRODUCT_DESIGN.md §5). */
sealed interface Load<out T> {
    data object Idle : Load<Nothing>
    data object Loading : Load<Nothing>
    data class Ready<T>(val value: T) : Load<T>
    data class Unavailable(val reason: String) : Load<Nothing>
    data class NotAuthorized(val reason: String) : Load<Nothing>
    data class Failed(val message: String) : Load<Nothing>
}

data class HealthRow(val label: String, val value: String, val source: String?, val note: String?, val available: Boolean)

data class VolumeView(val name: String, val free: String, val total: String, val usedFraction: Float)

data class HealthView(
    val collectedAt: String,
    val isPreview: Boolean,
    val batteryPercent: Int?,
    val charging: Boolean,
    val batteryRows: List<HealthRow>,
    val volumes: List<VolumeView>,
    val systemRows: List<HealthRow>,
)

enum class ActivityKind { Session, Pairing, Ai, Voice, Files, Security, Input }

data class ActivityItem(val kind: ActivityKind, val title: String, val detail: String?, val at: Instant = Instant.now())

data class ChatTurn(
    val id: String,
    val fromUser: Boolean,
    val text: String,
    val status: Status = Status.Complete,
    val servedBy: String? = null,
    /** A passing state shown under the answer (e.g. "Waiting for you to allow edits on your Mac"). */
    val note: String? = null,
) {
    enum class Status { Streaming, Complete, Failed }
}

data class FileEntry(val name: String, val isFolder: Boolean, val size: Long?)

data class VoiceResult(val transcript: String, val status: String, val summary: String)

object Formats {
    fun bytes(n: Long): String {
        if (n < 1000) return "$n B"
        val units = listOf("KB", "MB", "GB", "TB")
        var v = n.toDouble()
        var i = -1
        while (v >= 1000 && i < units.size - 1) {
            v /= 1000
            i++
        }
        return String.format(Locale.US, if (v >= 100) "%.0f %s" else "%.1f %s", v, units[i])
    }

    fun minutes(m: Long) = if (m >= 60) "${m / 60} h ${m % 60} min" else "$m min"

    fun duration(seconds: Long): String {
        val d = seconds / 86_400
        val h = (seconds % 86_400) / 3_600
        val m = (seconds % 3_600) / 60
        return if (d > 0) "$d d $h h" else if (h > 0) "$h h $m min" else "$m min"
    }

    fun relative(at: Instant, now: Instant = Instant.now()): String {
        val s = (now.epochSecond - at.epochSecond).coerceAtLeast(0)
        return when {
            s < 60 -> "now"
            s < 3600 -> "${s / 60} min"
            s < 86_400 -> "${s / 3600} h"
            else -> "${s / 86_400} d"
        }
    }

    val clock: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneId.systemDefault())
}

/** Parses the Mac's `health.snapshot.result` payload (HealthSnapshot schema v1) into rows with provenance. */
object HealthParser {
    private fun JsonObject.obj(k: String) = this[k] as? JsonObject
    private fun JsonElement?.str() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonElement?.long() = (this as? JsonPrimitive)?.content?.toDoubleOrNull()?.toLong()
    private fun JsonElement?.double() = (this as? JsonPrimitive)?.content?.toDoubleOrNull()
    private fun JsonElement?.bool() = (this as? JsonPrimitive)?.content?.toBooleanStrictOrNull()

    private fun row(label: String, m: JsonObject?, format: (JsonElement) -> String): HealthRow {
        if (m == null) return HealthRow(label, "Unavailable", null, "Not reported", false)
        val status = m.obj("status")
        val state = status?.get("state").str()
        val note = status?.get("note").str()
        val source = m["source"].str()
        val value = m["value"]
        return when (state) {
            "available" -> HealthRow(label, value?.let(format) ?: "—", source,
                if (m["origin"].str() == "derived") "Derived: ${m["formula"].str() ?: ""}" else null, true)
            "estimated" -> HealthRow(label, value?.let(format) ?: "—", source, "Estimate — $note", true)
            "notPermitted" -> HealthRow(label, "Not permitted", source, note, false)
            else -> HealthRow(label, "Unavailable", source, note, false)
        }
    }

    fun parse(snapshot: JsonObject): HealthView {
        val battery = snapshot.obj("battery")
        val level = battery?.obj("levelPercent")
        val levelOk = level?.obj("status")?.get("state").str() == "available"
        val charging = battery?.obj("isCharging")?.get("value").bool() == true
        val remainingKind = battery?.get("timeRemainingKind").str()
        val batteryRows = if (battery?.obj("present")?.get("value").bool() == false) {
            listOf(HealthRow("Battery", "None", "IOKit", "This Mac has no internal battery", false))
        } else {
            listOf(
                row("Power source", battery?.obj("powerSource")) { it.str() ?: "—" },
                row(if (remainingKind == "toFull") "Time to full" else "Time remaining", battery?.obj("timeRemainingMinutes")) { Formats.minutes(it.long() ?: 0) },
                row("Condition", battery?.obj("condition")) { it.str() ?: "—" },
                row("Cycle count", battery?.obj("cycleCount")) { "${it.long()}" },
                row("Maximum capacity", battery?.obj("maximumCapacityPercent")) { "${it.long()}%" },
            )
        }
        val volumes = (snapshot.obj("storage")?.get("value") as? JsonArray)?.mapNotNull { v ->
            val o = v.jsonObject
            val total = o["totalBytes"].long() ?: return@mapNotNull null
            val available = o["availableBytes"].long() ?: 0
            VolumeView(o["name"].str() ?: "Volume", Formats.bytes(available), Formats.bytes(total), if (total > 0) ((total - available).toFloat() / total) else 0f)
        } ?: emptyList()
        val memory = snapshot.obj("memory")
        val cpu = snapshot.obj("cpu")
        val system = snapshot.obj("system")
        val thermal = snapshot.obj("thermal")
        val network = snapshot.obj("network")
        val systemRows = listOf(
            row("Memory in use", memory?.obj("usedBytes")) { Formats.bytes(it.long() ?: 0) },
            row("Memory pressure", memory?.obj("pressure")) { (it.str() ?: "—").replaceFirstChar(Char::uppercase) },
            row("CPU (all cores)", cpu?.obj("systemUsagePercent")) { String.format(Locale.US, "%.1f%%", it.double() ?: 0.0) },
            row("Thermal state", thermal?.obj("thermalState")) { (it.str() ?: "—").replaceFirstChar(Char::uppercase) },
            row("Temperatures & fans", thermal?.obj("temperatures")) { it.str() ?: "—" },
            row("macOS", system?.obj("osVersion")) { it.str() ?: "—" },
            row("Chip", system?.obj("chip")) { it.str() ?: "—" },
            row("Uptime", system?.obj("uptimeSeconds")) { Formats.duration(it.long() ?: 0) },
            row("Network", network?.obj("pathStatus")) { (it.str() ?: "—").replaceFirstChar(Char::uppercase) },
        )
        val collected = snapshot["collectedAt"].str()?.let { runCatching { Instant.parse(it) }.getOrNull() }
        return HealthView(
            collectedAt = collected?.let { Formats.clock.format(it) } ?: "—",
            isPreview = snapshot["isPreviewData"].bool() == true,
            batteryPercent = if (levelOk) level?.get("value").long()?.toInt() else null,
            charging = charging,
            batteryRows = batteryRows,
            volumes = volumes,
            systemRows = systemRows,
        )
    }

    fun percentOf(f: Float) = (f * 100).roundToInt()
}
