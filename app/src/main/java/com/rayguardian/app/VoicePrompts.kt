package com.rayguardian.app

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.speech.tts.TextToSpeech
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Speaks fixed rehearsal prompts. Audio comes from the backend (the configured ElevenLabs voice/model)
 * and is cached on the device; if that is unavailable or slow, Android's on-device voice says the same
 * words so a check-in is never silent. Playback uses the current media output, which is the glasses
 * when they are the connected Bluetooth audio device.
 */
class VoicePrompts(context: Context, private val scope: CoroutineScope) {
    /** IDs and wording must match PHRASES in server/elevenlabs.mjs. */
    enum class Phrase(val id: String, val text: String) {
        CHECK_IN("check_in", "Are you okay? I noticed something that might need attention. Tap I'm okay on your phone to cancel. Otherwise, I'll create an alert in fifteen seconds."),
        CHECK_IN_HEART_RATE("check_in_heart_rate", "Are you okay? Your watch reported an unusual heart rate. Tap I'm okay on your phone to cancel. Otherwise, I'll create an alert in fifteen seconds."),
        CHECK_IN_CANCELLED("check_in_cancelled", "Okay, glad you're alright. The check-in is cancelled."),
        ALERT_CREATED("alert_created", "This is a rehearsal. A simulated alert has been created. No one has been contacted."),
    }

    private val cacheDir = File(context.cacheDir, "voice").apply { mkdirs() }
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()
    private var ttsReady = false
    private lateinit var tts: TextToSpeech

    init {
        tts = TextToSpeech(context.applicationContext) { status ->
            if (status == TextToSpeech.SUCCESS) {
                tts.language = Locale.US
                tts.setAudioAttributes(attributes)
                ttsReady = true
            }
        }
    }
    private var player: MediaPlayer? = null
    private var job: Job? = null
    private val backendConfigured = BuildConfig.AI_BASE_URL.isNotBlank() && BuildConfig.AI_CLIENT_TOKEN.isNotBlank()

    /** Downloads all prompts in the background so a later check-in plays instantly. */
    fun prefetch() {
        if (!backendConfigured) return
        scope.launch(Dispatchers.IO) {
            Phrase.entries.forEach { runCatching { cachedAudio(it) } }
        }
    }

    fun speak(phrase: Phrase) {
        stop()
        job = scope.launch {
            val audio = if (backendConfigured) runCatching { withContext(Dispatchers.IO) { cachedAudio(phrase) } }.getOrNull() else null
            if (!isActive) return@launch
            if (audio == null || !play(audio)) speakOnDevice(phrase)
        }
    }

    fun stop() {
        job?.cancel()
        job = null
        player?.release()
        player = null
        tts.stop()
    }

    fun release() {
        stop()
        tts.shutdown()
    }

    private fun play(file: File): Boolean = try {
        player = MediaPlayer().apply {
            setAudioAttributes(attributes)
            setDataSource(file.path)
            setOnCompletionListener { if (player === it) player = null; it.release() }
            prepare()
            start()
        }
        true
    } catch (error: Exception) {
        player?.release()
        player = null
        file.delete() // a corrupt cache entry is downloaded again next time
        false
    }

    private fun speakOnDevice(phrase: Phrase) {
        if (ttsReady) tts.speak(phrase.text, TextToSpeech.QUEUE_FLUSH, null, phrase.id)
    }

    private fun cachedAudio(phrase: Phrase): File {
        val file = File(cacheDir, "${phrase.id}.mp3")
        if (file.length() > 0) return file
        val connection = URL(BuildConfig.AI_BASE_URL.trimEnd('/') + "/v1/speech/" + phrase.id).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            // A check-in must not wait on the network; fall back to the on-device voice quickly.
            connection.connectTimeout = 3_000
            connection.readTimeout = 8_000
            connection.setRequestProperty("Authorization", "Bearer ${BuildConfig.AI_CLIENT_TOKEN}")
            check(connection.responseCode == 200 && connection.contentType?.startsWith("audio/mpeg") == true) { "Speech unavailable" }
            // Unique temp file: a prefetch and a check-in may download the same phrase at once.
            val partial = File.createTempFile(phrase.id, ".part", cacheDir)
            try {
            connection.inputStream.use { input ->
                partial.outputStream().use { output ->
                    val buffer = ByteArray(8192)
                    var total = 0
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        check(total <= MAX_AUDIO_BYTES) { "Speech response too large" }
                        output.write(buffer, 0, count)
                    }
                }
            }
            check(partial.renameTo(file)) { "Could not cache speech" }
            } finally {
                partial.delete()
            }
            return file
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        private const val MAX_AUDIO_BYTES = 1024 * 1024
    }
}
