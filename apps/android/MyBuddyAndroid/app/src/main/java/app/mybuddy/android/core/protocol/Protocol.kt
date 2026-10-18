package app.mybuddy.android.core.protocol

import app.mybuddy.android.core.Base64Url
import app.mybuddy.android.core.Timestamp
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant

/** Which side is decoding. The phone receives Mac→phone (`M2P`) types. */
enum class ProtocolRole { MAC, PHONE }

/** Decoder errors shared with the Mac implementation (docs/PROTOCOL.md §3). */
sealed class ProtocolError(val code: String, val detail: String = "") {
    object TooLarge : ProtocolError("too_large")
    object MalformedJson : ProtocolError("malformed_json")
    class InvalidEnvelope(detail: String) : ProtocolError("invalid_envelope", detail)
    object UnsupportedVersion : ProtocolError("unsupported_version")
    class UnknownType(type: String) : ProtocolError("unknown_type", type.take(64))
    object WrongDirection : ProtocolError("wrong_direction")
    class InvalidPayload(detail: String) : ProtocolError("invalid_payload", detail)
    object ReplayedSequence : ProtocolError("replayed_sequence")

    override fun toString(): String = if (detail.isEmpty()) code else "$code: $detail"
}

class ProtocolException(val error: ProtocolError) : Exception(error.toString())

/** Every v1 event type. A unit test asserts this matches the shared catalog exactly. */
enum class EventType(val wire: String) {
    PAIRING_REQUEST("pairing.request"), PAIRING_APPROVED("pairing.approved"), PAIRING_REJECTED("pairing.rejected"),
    SESSION_REQUEST("session.request"), SESSION_APPROVED("session.approved"), SESSION_REJECTED("session.rejected"),
    SESSION_CLOSED("session.closed"), HOST_HEARTBEAT("host.heartbeat"), HOST_STATUS("host.status"), ERROR("error"),
    CONNECT_OFFER("connect.offer"), CONNECT_ENROLL("connect.enroll"), CONNECT_ENROLLED("connect.enrolled"),
    WEBRTC_OFFER("webrtc.offer"), WEBRTC_ANSWER("webrtc.answer"), WEBRTC_ICE("webrtc.ice"),
    SCREEN_START("screen.start"), SCREEN_UPDATE("screen.update"), SCREEN_STOP("screen.stop"), SCREEN_STATE("screen.state"),
    INPUT_POINTER("input.pointer"), INPUT_BUTTON("input.button"), INPUT_SCROLL("input.scroll"), INPUT_KEY("input.key"), INPUT_TEXT("input.text"),
    HOST_APP_LIST("host.app.list"), HOST_APP_OPEN("host.app.open"), HOST_FILE_LIST("host.file.list"), HOST_FILE_OPEN("host.file.open"),
    FILE_OFFER("file.offer"), FILE_REQUEST("file.request"), FILE_START("file.start"), FILE_CHUNK("file.chunk"), FILE_ACK("file.ack"), FILE_PAUSE("file.pause"),
    FILE_RESUME("file.resume"), FILE_CANCEL("file.cancel"), FILE_COMPLETE("file.complete"), FILE_ERROR("file.error"),
    CLIPBOARD_OFFER("clipboard.offer"), CLIPBOARD_REQUEST("clipboard.request"), CLIPBOARD_CONTENT("clipboard.content"),
    CLIPBOARD_APPLIED("clipboard.applied"), CLIPBOARD_PAUSED("clipboard.paused"),
    AI_PROVIDER_STATUS("ai.provider.status"), AI_REQUEST("ai.request"), AI_DELTA("ai.delta"), AI_COMPLETE("ai.complete"), AI_ERROR("ai.error"),
    AI_TOOL_PROPOSED("ai.tool.proposed"), AI_TOOL_APPROVAL("ai.tool.approval"), AI_TOOL_RESULT("ai.tool.result"), AI_CANCEL("ai.cancel"),
    VOICE_STARTED("voice.started"), VOICE_TRANSCRIPT("voice.transcript"), VOICE_INTENT_PROPOSED("voice.intent.proposed"),
    VOICE_INTENT_APPROVED("voice.intent.approved"), VOICE_INTENT_RESULT("voice.intent.result"), VOICE_CANCELLED("voice.cancelled"),
    HEALTH_SNAPSHOT_REQUEST("health.snapshot.request"), HEALTH_SNAPSHOT_RESULT("health.snapshot.result"), HEALTH_REPORT_EXPORTED("health.report.exported"),
    NOTIFICATION_POSTED("notification.posted"), NOTIFICATION_REMOVED("notification.removed"),
    NOTES_INDEX("notes.index"), NOTES_PUT("notes.put");

    companion object {
        private val byWire = entries.associateBy { it.wire }
        fun fromWire(s: String): EventType? = byWire[s]
    }
}

data class Envelope(
    val type: EventType,
    val sessionId: String,
    val sequence: Long,
    val sentAt: Instant,
    val replyTo: Long?,
    val payload: JsonObject,
)

// region Catalog model

class FieldSpec(
    val type: String,
    val min: Double?,
    val max: Double?,
    val optional: Boolean,
    val values: List<String>?,
    val valuesRef: String?,
    val pattern: Regex?,
    val unit: String?,
    val noNul: Boolean,
    val fileName: Boolean,
    val noControlExcept: Set<Int>?,
    val maxBytes: Int?,
    val itemName: String?,
    val itemSpec: FieldSpec?,
    val fields: Map<String, FieldSpec>?,
    val totalTextBytesMax: Int?,
)

class EventSpec(
    val dir: String,
    val channel: String,
    val capability: String?,
    val payload: Map<String, FieldSpec>?,
    val payloadP2M: Map<String, FieldSpec>?,
    val payloadM2P: Map<String, FieldSpec>?,
)

class EventCatalog(
    val limits: Map<String, Int>,
    val capabilities: List<String>,
    val keyCodes: List<String>,
    val events: Map<String, EventSpec>,
) {
    val maxEnvelopeBytes: Int = limits.values.maxOrNull() ?: 65536

    companion object {
        val embeddedJson: String get() = EventCatalogData.JSON

        val shared: EventCatalog by lazy { parse(EventCatalogData.JSON) }

        fun parse(json: String): EventCatalog {
            val root = Json.parseToJsonElement(json).jsonObject
            val limits = root.getValue("limits").jsonObject.mapValues { it.value.jsonPrimitive.content.toInt() }
            val caps = root.getValue("capabilities").jsonArray.map { it.jsonPrimitive.content }
            val keys = root.getValue("keyCodes").jsonArray.map { it.jsonPrimitive.content }
            val events = root.getValue("events").jsonObject.mapValues { (_, v) ->
                val o = v.jsonObject
                EventSpec(
                    dir = o.getValue("dir").jsonPrimitive.content,
                    channel = o.getValue("channel").jsonPrimitive.content,
                    capability = (o["capability"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
                    payload = (o["payload"] as? JsonObject)?.let(::fields),
                    payloadP2M = (o["payloadP2M"] as? JsonObject)?.let(::fields),
                    payloadM2P = (o["payloadM2P"] as? JsonObject)?.let(::fields),
                )
            }
            return EventCatalog(limits, caps, keys, events)
        }

        private fun fields(o: JsonObject): Map<String, FieldSpec> = o.mapValues { field(it.value.jsonObject) }

        private fun field(o: JsonObject): FieldSpec {
            fun num(k: String) = (o[k] as? JsonPrimitive)?.content?.toDoubleOrNull()
            fun bool(k: String) = (o[k] as? JsonPrimitive)?.content == "true"
            val values = o["values"]
            val items = o["items"]
            return FieldSpec(
                type = o.getValue("type").jsonPrimitive.content,
                min = num("min"),
                max = num("max"),
                optional = bool("optional"),
                values = (values as? JsonArray)?.map { it.jsonPrimitive.content },
                valuesRef = (values as? JsonPrimitive)?.content,
                pattern = (o["pattern"] as? JsonPrimitive)?.content?.let { Regex(it) },
                unit = (o["unit"] as? JsonPrimitive)?.content,
                noNul = bool("noNul"),
                fileName = bool("fileName"),
                noControlExcept = (o["noControlExcept"] as? JsonArray)?.flatMap { e -> e.jsonPrimitive.content.codePoints().toArray().toList() }?.toSet(),
                maxBytes = (o["maxBytes"] as? JsonPrimitive)?.content?.toIntOrNull(),
                itemName = (items as? JsonPrimitive)?.content,
                itemSpec = (items as? JsonObject)?.let(::field),
                fields = (o["fields"] as? JsonObject)?.let(::fields),
                totalTextBytesMax = (o["totalTextBytesMax"] as? JsonPrimitive)?.content?.toIntOrNull(),
            )
        }
    }
}

// endregion

// region JSON helpers

internal fun JsonElement.stringOrNull(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
internal fun JsonElement.longOrNull(): Long? = (this as? JsonPrimitive)?.takeIf { !it.isString && this !is JsonNull }?.content?.toLongOrNull()
internal fun JsonElement.doubleOrNull(): Double? = (this as? JsonPrimitive)?.takeIf { !it.isString && this !is JsonNull }?.content?.toDoubleOrNull()
internal fun JsonElement.boolOrNull(): Boolean? = (this as? JsonPrimitive)?.takeIf { !it.isString && this !is JsonNull }?.content?.toBooleanStrictOrNull()

// endregion

/** File names received from a peer must be a single harmless path component (same rules as the Mac). */
object FileNameRules {
    fun isSafe(name: String): Boolean {
        if (name.isEmpty() || name.toByteArray(Charsets.UTF_8).size > 255 || name == "." || name == "..") return false
        if (name.contains('/') || name.contains('\\') || name.contains(':')) return false
        if (name.codePoints().anyMatch { Character.getType(it) == Character.CONTROL.toInt() }) return false
        if (name.startsWith(" ") || name.endsWith(" ") || name.endsWith(".")) return false
        return true
    }
}

internal class PayloadValidator(private val catalog: EventCatalog) {
    private val uuid = Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
    private val hex64 = Regex("^[0-9a-f]{64}$")

    fun validate(payload: JsonObject, spec: Map<String, FieldSpec>): String? {
        for ((name, field) in spec.toSortedMap()) {
            val value = payload[name]
            if (value == null || value is JsonNull) {
                if (field.optional) continue
                return "missing field '$name'"
            }
            validate(value, field)?.let { return "'$name': $it" }
        }
        return null
    }

    fun validate(value: JsonElement, f: FieldSpec): String? = when (f.type) {
        "string" -> {
            val s = value.stringOrNull()
            if (s == null) "expected string" else validateString(s, f)
        }
        "enum" -> {
            val s = value.stringOrNull()
            if (s == null) "expected string" else if (s in allowed(f)) null else "value not allowed"
        }
        "number" -> {
            val n = value.doubleOrNull()
            when {
                n == null || !n.isFinite() -> "expected number"
                f.min != null && n < f.min -> "below minimum"
                f.max != null && n > f.max -> "above maximum"
                else -> null
            }
        }
        "integer" -> {
            val i = value.longOrNull()
            when {
                i == null -> "expected integer"
                i > 9_007_199_254_740_991L || i < -9_007_199_254_740_991L -> "integer out of safe range"
                f.min != null && i < f.min -> "below minimum"
                f.max != null && i > f.max -> "above maximum"
                else -> null
            }
        }
        "bool" -> if (value.boolOrNull() == null) "expected boolean" else null
        "uuid" -> if (value.stringOrNull()?.let { uuid.matches(it) } == true) null else "expected UUID"
        "hex64" -> if (value.stringOrNull()?.let { hex64.matches(it) } == true) null else "expected 64 lowercase hex characters"
        "b64u" -> {
            val d = value.stringOrNull()?.let { Base64Url.decode(it) }
            when {
                d == null -> "expected base64url"
                f.maxBytes != null && d.size > f.maxBytes -> "decoded data too large"
                else -> null
            }
        }
        "array" -> validateArray(value, f)
        "object" -> {
            val o = value as? JsonObject
            if (o == null) "expected object" else f.fields?.let { validate(o, it) }
        }
        else -> "unknown field type ${f.type}"
    }

    private fun validateArray(value: JsonElement, f: FieldSpec): String? {
        val items = value as? JsonArray ?: return "expected array"
        if (f.min != null && items.size < f.min) return "too few items"
        if (f.max != null && items.size > f.max) return "too many items"
        for (item in items) {
            val problem = when {
                f.itemSpec != null -> validate(item, f.itemSpec)
                f.itemName == "capability" -> if (item.stringOrNull()?.let { it in catalog.capabilities } == true) null else "unknown capability"
                f.itemName == "string" -> if (item.stringOrNull()?.let { it.codePointCount(0, it.length) <= 128 } == true) null else "expected short string"
                f.itemName == "integer" -> if (item.longOrNull() == null) "expected integer" else null
                else -> "unknown item type ${f.itemName}"
            }
            if (problem != null) return "item $problem"
        }
        if (f.totalTextBytesMax != null) {
            val total = items.sumOf { ((it as? JsonObject)?.get("text")?.stringOrNull() ?: "").toByteArray(Charsets.UTF_8).size }
            if (total > f.totalTextBytesMax) return "total text too large"
        }
        return null
    }

    private fun allowed(f: FieldSpec): List<String> = f.values ?: if (f.valuesRef == "\$keyCodes") catalog.keyCodes else emptyList()

    private fun validateString(s: String, f: FieldSpec): String? {
        val length = if (f.unit == "utf8Bytes") s.toByteArray(Charsets.UTF_8).size else s.codePointCount(0, s.length)
        if (f.min != null && length < f.min) return "too short"
        if (f.max != null && length > f.max) return "too long"
        if (f.noNul && s.contains('\u0000')) return "contains NUL"
        f.noControlExcept?.let { allowed ->
            if (s.codePoints().anyMatch { Character.getType(it) == Character.CONTROL.toInt() && it !in allowed }) return "contains control characters"
        }
        if (f.fileName && !FileNameRules.isSafe(s)) return "not a safe file name"
        if (f.pattern != null && !f.pattern.matches(s)) return "does not match pattern"
        return null
    }
}

object EnvelopeCodec {
    private val typePattern = Regex("^[a-z]+(\\.[a-z]+)*$")
    private val sessionPattern = Regex("^[A-Za-z0-9_-]{8,64}$")
    private const val MAX_SAFE = 9_007_199_254_740_991L
    private val json = Json { encodeDefaults = true }

    fun decode(data: ByteArray, receiver: ProtocolRole, catalog: EventCatalog = EventCatalog.shared): Envelope {
        fun fail(e: ProtocolError): Nothing = throw ProtocolException(e)
        if (data.size > catalog.maxEnvelopeBytes) fail(ProtocolError.TooLarge)
        val root = try {
            Json.parseToJsonElement(String(data, Charsets.UTF_8))
        } catch (e: Exception) {
            fail(ProtocolError.MalformedJson)
        }
        val o = root as? JsonObject ?: fail(ProtocolError.InvalidEnvelope("not an object"))
        val version = o["version"]?.longOrNull() ?: fail(ProtocolError.InvalidEnvelope("version"))
        if (version != 1L) fail(ProtocolError.UnsupportedVersion)
        val typeName = o["type"]?.stringOrNull()?.takeIf { it.length <= 64 && typePattern.matches(it) } ?: fail(ProtocolError.InvalidEnvelope("type"))
        val sessionId = o["sessionId"]?.stringOrNull()?.takeIf { sessionPattern.matches(it) } ?: fail(ProtocolError.InvalidEnvelope("sessionId"))
        val sequence = o["sequence"]?.longOrNull()?.takeIf { it in 1..MAX_SAFE } ?: fail(ProtocolError.InvalidEnvelope("sequence"))
        val sentAt = o["sentAt"]?.stringOrNull()?.let { Timestamp.parse(it) } ?: fail(ProtocolError.InvalidEnvelope("sentAt"))
        val replyRaw = o["replyTo"]
        val replyTo = if (replyRaw == null || replyRaw is JsonNull) null else replyRaw.longOrNull()?.takeIf { it in 1..MAX_SAFE }
            ?: fail(ProtocolError.InvalidEnvelope("replyTo"))
        val payload = o["payload"] as? JsonObject ?: fail(ProtocolError.InvalidEnvelope("payload"))

        val spec = catalog.events[typeName]
        val type = EventType.fromWire(typeName)
        if (spec == null || type == null) fail(ProtocolError.UnknownType(typeName))
        catalog.limits[spec.channel]?.let { if (data.size > it) fail(ProtocolError.TooLarge) }
        val directionOk = spec.dir == "BOTH" || (spec.dir == "P2M" && receiver == ProtocolRole.MAC) || (spec.dir == "M2P" && receiver == ProtocolRole.PHONE)
        if (!directionOk) fail(ProtocolError.WrongDirection)
        val fields = spec.payload ?: (if (receiver == ProtocolRole.MAC) spec.payloadP2M else spec.payloadM2P) ?: emptyMap()
        PayloadValidator(catalog).validate(payload, fields)?.let { fail(ProtocolError.InvalidPayload(it)) }
        return Envelope(type, sessionId, sequence, sentAt, replyTo, payload)
    }

    /** Encodes and self-validates as the peer would, so we never send what the peer must reject. */
    fun encode(e: Envelope, receiver: ProtocolRole): ByteArray {
        val map = linkedMapOf<String, JsonElement>(
            "version" to JsonPrimitive(1),
            "type" to JsonPrimitive(e.type.wire),
            "sessionId" to JsonPrimitive(e.sessionId),
            "sequence" to JsonPrimitive(e.sequence),
            "sentAt" to JsonPrimitive(Timestamp.format(e.sentAt)),
            "payload" to e.payload,
        )
        e.replyTo?.let { map["replyTo"] = JsonPrimitive(it) }
        val bytes = json.encodeToString(JsonObject.serializer(), JsonObject(map)).toByteArray(Charsets.UTF_8)
        decode(bytes, receiver)
        return bytes
    }
}

/** Strictly increasing envelope sequence numbers per session (L3 replay protection). */
class SequenceGuard {
    var lastSeen = 0L
        private set

    fun accept(e: Envelope) {
        if (e.sequence <= lastSeen) throw ProtocolException(ProtocolError.ReplayedSequence)
        lastSeen = e.sequence
    }
}
