package app.mybuddy.android

import app.mybuddy.android.core.Hex
import app.mybuddy.android.core.files.ChunkAssembler
import app.mybuddy.android.core.files.ClipboardLoopGuard
import app.mybuddy.android.core.files.ClipboardRules
import app.mybuddy.android.core.files.FileOffer
import app.mybuddy.android.core.files.SendWindow
import app.mybuddy.android.core.files.TransferException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import kotlin.random.Random

class TransferCoreTest {
    private fun repoRoot(): File {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "protocol/schema/events.v1.json").exists()) dir = dir.parentFile
        return dir ?: error("repository root not found")
    }

    private fun fixturePayload(name: String) =
        Json.parseToJsonElement(File(repoRoot(), "protocol/fixtures/valid/$name.json").readText()).jsonObject.getValue("payload").jsonObject

    private fun offerFor(bytes: ByteArray, chunk: Int = 64 * 1024) =
        FileOffer("6f1c2b9e-1d2a-4c7e-9a51-3b8f0d2e4a10", "report.bin", bytes.size.toLong(), Hex.encode(MessageDigest.getInstance("SHA-256").digest(bytes)), chunk)

    @Test
    fun parsesSharedOfferFixturesIncludingTheRequestEcho() {
        val plain = FileOffer.fromPayload(fixturePayload("file.offer"))!!
        assertEquals("report.pdf", plain.name)
        assertEquals(32, plain.chunkCount)
        assertNull(plain.requestId)
        val requested = FileOffer.fromPayload(fixturePayload("file.offer.requested"))!!
        assertEquals("0b7e9a44-5c21-4f0e-8d9b-7a6c5e4d3b21", requested.requestId)
        assertNull(plain.problem())
    }

    @Test
    fun refusesUnsafeOffers() {
        val ok = offerFor(ByteArray(10))
        assertEquals("denied", ok.copy(name = "../evil.sh").problem())
        assertEquals("too_large", ok.copy(size = FileOffer.MAX_SIZE + 1).problem())
        assertEquals("denied", ok.copy(chunkSize = 1024).problem())
        assertEquals("denied", ok.copy(sha256 = "xyz").problem())
    }

    @Test
    fun assemblesInOrderAndVerifiesTheChecksum() {
        val bytes = Random(7).nextBytes(150_000) // 3 chunks, the last one short
        val offer = offerFor(bytes)
        val out = ByteArrayOutputStream()
        val assembler = ChunkAssembler(offer, out)
        for (i in 0 until offer.chunkCount) {
            val chunk = bytes.copyOfRange(i * offer.chunkSize, minOf(bytes.size, (i + 1) * offer.chunkSize))
            assembler.write(i, chunk)
            if (i == 0) assembler.write(0, chunk) // a duplicate is ignored
        }
        assertTrue(assembler.complete)
        assertEquals(offer.sha256, assembler.finish())
        assertArrayEquals(bytes, out.toByteArray())
    }

    @Test
    fun rejectsGapsBadLengthsAndDetectsCorruption() {
        val bytes = Random(9).nextBytes(140_000)
        val offer = offerFor(bytes)
        val gap = ChunkAssembler(offer, ByteArrayOutputStream())
        assertEquals("invalid_chunk", assertThrows(TransferException::class.java) { gap.write(1, ByteArray(offer.chunkSize)) }.code)
        assertThrows(TransferException::class.java) { gap.write(0, ByteArray(10)) }

        val corrupt = ChunkAssembler(offer, ByteArrayOutputStream())
        for (i in 0 until offer.chunkCount) {
            val chunk = bytes.copyOfRange(i * offer.chunkSize, minOf(bytes.size, (i + 1) * offer.chunkSize))
            if (i == 1) chunk[0] = (chunk[0].toInt() xor 0xFF).toByte()
            corrupt.write(i, chunk)
        }
        assertFalse("a flipped byte changes the digest", corrupt.finish() == offer.sha256)
    }

    @Test
    fun sendWindowMatchesTheMac() {
        val w = SendWindow(20)
        assertEquals((0 until 8).toList(), w.takeSendable())
        assertTrue(w.takeSendable().isEmpty())
        assertTrue(w.ack(2))
        assertEquals(listOf(8, 9, 10), w.takeSendable())
        assertFalse(w.ack(15))
        val resumed = SendWindow(5, from = 3)
        assertEquals(listOf(3, 4), resumed.takeSendable())
        resumed.ack(4)
        assertTrue(resumed.allAcked)
    }

    @Test
    fun clipboardRulesAndLoopGuard() {
        assertEquals(64, ClipboardRules.hash("test").length)
        assertNotNull(ClipboardRules.looksSensitive("key: sk-" + "abcdefghijklmnopqrstuvwxyz123456"))
        assertNotNull(ClipboardRules.looksSensitive("-----BEGIN OPENSSH " + "PRIVATE KEY-----\nabc"))
        assertNotNull(ClipboardRules.looksSensitive("card 4111 1111 1111 1111"))
        assertNull(ClipboardRules.looksSensitive("Meeting at 10:30 tomorrow"))
        assertNull(ClipboardRules.looksSensitive("order 1234 5678 9012 3456"), "fails the Luhn check, so not a card")
        val guard = ClipboardLoopGuard(capacity = 2)
        guard.noteApplied("a")
        assertFalse(guard.shouldOffer("a"))
        guard.noteApplied("b"); guard.noteApplied("c")
        assertTrue("old entries age out", guard.shouldOffer("a"))
    }

    private fun assertNull(value: Any?, message: String) = org.junit.Assert.assertNull(message, value)
}
