package app.mybuddy.android.data

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.Locale

enum class VoicePhase { Idle, Listening, Thinking, Speaking, Error }

data class VoiceUi(
    val phase: VoicePhase = VoicePhase.Idle,
    val caption: String = "",
    val level: Float = 0f,
    val message: String? = null,
    val onDevice: Boolean = false,
)

/**
 * Push-to-talk speech on the phone: Android SpeechRecognizer while the user holds the orb,
 * TextToSpeech for replies. Never listens in the background; no wake word.
 */
class VoiceController(private val context: Context, private val onFinalTranscript: (String) -> Unit) {
    private val _ui = MutableStateFlow(VoiceUi())
    val ui: StateFlow<VoiceUi> = _ui
    private var recognizer: SpeechRecognizer? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    var muted = false

    val isAvailable: Boolean get() = SpeechRecognizer.isRecognitionAvailable(context)

    /** Must be called on the main thread after RECORD_AUDIO is granted. */
    fun start() {
        if (!isAvailable) {
            _ui.value = VoiceUi(VoicePhase.Error, message = "Speech recognition isn’t available on this phone.")
            return
        }
        stopTts()
        val onDevice = SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        val r = if (onDevice) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else SpeechRecognizer.createSpeechRecognizer(context)
        recognizer?.destroy()
        recognizer = r
        r.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {
                _ui.value = _ui.value.copy(level = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f))
            }
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {
                _ui.value = _ui.value.copy(level = 0f)
            }
            override fun onError(error: Int) {
                val caption = _ui.value.caption
                if (caption.isNotBlank()) {
                    finish(caption)
                } else {
                    val message = when (error) {
                        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "I didn’t hear anything."
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission is needed."
                        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Speech recognition needs a network connection on this phone."
                        else -> "Speech recognition stopped (code $error)."
                    }
                    _ui.value = VoiceUi(VoicePhase.Error, message = message)
                }
            }
            override fun onResults(results: Bundle?) {
                val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                if (text.isBlank()) _ui.value = VoiceUi(VoicePhase.Idle, message = "I didn’t hear anything.") else finish(text)
            }
            override fun onPartialResults(partialResults: Bundle?) {
                val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                if (text.isNotBlank()) _ui.value = _ui.value.copy(caption = text)
            }
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
        }
        _ui.value = VoiceUi(VoicePhase.Listening, onDevice = onDevice)
        r.startListening(intent)
    }

    /** Release of the talk button: the recognizer delivers its final result. */
    fun release() {
        recognizer?.stopListening()
    }

    fun cancel() {
        recognizer?.cancel()
        stopTts()
        _ui.value = VoiceUi()
    }

    private fun finish(text: String) {
        _ui.value = _ui.value.copy(phase = VoicePhase.Thinking, caption = text, level = 0f)
        onFinalTranscript(text)
    }

    fun showResult(summary: String, ok: Boolean) {
        _ui.value = _ui.value.copy(phase = if (ok) VoicePhase.Speaking else VoicePhase.Error, message = summary)
        speak(summary)
    }

    fun speak(text: String) {
        if (muted) {
            _ui.value = _ui.value.copy(phase = VoicePhase.Idle)
            return
        }
        val engine = tts ?: TextToSpeech(context) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            if (ttsReady) tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "mybuddy")
        }.also { tts = it }
        if (ttsReady) engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "mybuddy")
    }

    private fun stopTts() {
        tts?.stop()
    }

    fun shutdown() {
        recognizer?.destroy()
        recognizer = null
        tts?.shutdown()
        tts = null
    }
}
