package app.mybuddy.android.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

private val Context.settingsStore by preferencesDataStore("mybuddy_settings")

/** Phone-side preferences, stored on this phone only (no secrets). */
class PhoneSettings(private val context: Context, private val scope: CoroutineScope) {
    private object Keys {
        val autoSaveFromMac = booleanPreferencesKey("files_auto_save_from_mac")
    }

    /** Files your Mac sends are saved to Downloads/MyBuddy without asking. Off by default. */
    val autoSaveFromMac: StateFlow<Boolean> = context.settingsStore.data.map { it[Keys.autoSaveFromMac] ?: false }
        .stateIn(scope, SharingStarted.Eagerly, false)

    fun setAutoSaveFromMac(on: Boolean) = scope.launch { context.settingsStore.edit { it[Keys.autoSaveFromMac] = on } }
}
