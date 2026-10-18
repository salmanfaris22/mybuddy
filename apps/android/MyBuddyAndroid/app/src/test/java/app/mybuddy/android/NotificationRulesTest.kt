package app.mybuddy.android

import app.mybuddy.android.core.notifications.NotificationRules
import app.mybuddy.android.core.notifications.PreviewPolicy
import app.mybuddy.android.core.notifications.SeenNotification
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationRulesTest {
    private val rules = NotificationRules("app.mybuddy.android", "salt-for-tests".toByteArray())

    private fun n(title: String? = "Asha", text: String? = "Running 10 min late", pkg: String = "com.whatsapp", category: String? = "msg",
                  ongoing: Boolean = false, summary: Boolean = false, clearable: Boolean = true) =
        SeenNotification("0|$pkg|1|null|10123", pkg, "WhatsApp", title, text, category, ongoing, summary, clearable)

    @Test
    fun onlyOrdinaryNotificationsFromAllowedAppsLeaveThePhone() {
        assertTrue(rules.shouldMirror(n(), emptySet()))
        assertFalse("own notifications", rules.shouldMirror(n(pkg = "app.mybuddy.android"), emptySet()))
        assertFalse("ongoing (music, navigation, calls in progress)", rules.shouldMirror(n(ongoing = true), emptySet()))
        assertFalse("persistent", rules.shouldMirror(n(clearable = false), emptySet()))
        assertFalse("group summary", rules.shouldMirror(n(summary = true), emptySet()))
        assertFalse("system category", rules.shouldMirror(n(category = "sys"), emptySet()))
        assertFalse("blocked app", rules.shouldMirror(n(), setOf("com.whatsapp")))
        assertFalse("empty", rules.shouldMirror(n(title = " ", text = null), emptySet()))
    }

    @Test
    fun previewPolicyDecidesWhatTheMacSees() {
        val hidden = rules.mirror(n(), PreviewPolicy.HIDDEN)
        assertNull(hidden.title)
        assertNull(hidden.text)
        assertEquals("content_hidden", hidden.redaction)
        assertEquals("WhatsApp", hidden.appLabel)
        val title = rules.mirror(n(), PreviewPolicy.TITLE)
        assertEquals("Asha", title.title)
        assertNull(title.text)
        assertEquals("title_only", title.redaction)
        val full = rules.mirror(n(), PreviewPolicy.FULL)
        assertEquals("Running 10 min late", full.text)
        assertEquals("none", full.redaction)
    }

    @Test
    fun codesKeysAndCardsAreMaskedEvenWithFullPreviews() {
        val otp = rules.mirror(n(title = "Bank", text = "Your verification code is 482913. Don't share it."), PreviewPolicy.FULL)
        assertEquals("Your verification code is ••••••. Don't share it.", otp.text)
        assertEquals("partial", otp.redaction)
        assertEquals("meeting at 1030 in room 4", NotificationRules.mask("meeting at 1030 in room 4"), "numbers without a code context stay")
        assertFalse(NotificationRules.mask("card 4111 1111 1111 1111 charged").contains("4111"))
        assertFalse(NotificationRules.mask("key sk-" + "abcdefghijklmnopqrstuvwxyz123456 leaked").contains("abcdefghij"))
    }

    @Test
    fun idsAreOpaqueStableAndSalted() {
        val a = rules.id("0|com.whatsapp|1|null|10123")
        assertEquals(a, rules.id("0|com.whatsapp|1|null|10123"))
        assertTrue(a.startsWith("n_") && !a.contains("whatsapp"))
        assertNotEquals(a, NotificationRules("app.mybuddy.android", "other-install".toByteArray()).id("0|com.whatsapp|1|null|10123"))
    }

    private fun assertEquals(expected: String, actual: String, message: String) = org.junit.Assert.assertEquals(message, expected, actual)
}
