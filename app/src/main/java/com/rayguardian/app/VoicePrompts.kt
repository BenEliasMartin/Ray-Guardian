package com.rayguardian.app

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.speech.tts.TextToSpeech
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Speaks fixed wearer warnings and dynamic ElevenLabs emergency call briefings.
 * Audio comes from the backend (ElevenLabs Eleven v4, Jack John voice) and is cached on-device;
 * if the backend is unreachable or slow, Android's on-device TextToSpeech speaks the exact same
 * script so a hazard check-in or emergency briefing is never silent.
 */
class VoicePrompts(context: Context, private val scope: CoroutineScope) {
    /** IDs and wording must match PHRASES in server/elevenlabs.mjs. */
    enum class Phrase(val id: String, val text: String) {
        CHECK_IN("check_in", "Are you okay? I noticed something that might need attention. Tap I'm okay on your phone to cancel. Otherwise, I'll create an alert in fifteen seconds."),
        CHECK_IN_HEART_RATE("check_in_heart_rate", "Are you okay? Your watch reported an unusual heart rate. Tap I'm okay on your phone to cancel. Otherwise, I'll create an alert in fifteen seconds."),
        CHECK_IN_CANCELLED("check_in_cancelled", "Okay, glad you're alright. The check-in is cancelled."),
        ALERT_CREATED("alert_created", "This is a rehearsal. A simulated alert has been created. No one has been contacted."),
        HAZARD_MEDICAL("hazard_medical", "Medical hazard detected. A person appears to have fallen or needs urgent medical attention. Cancel now if everyone is okay, otherwise calling Ambulance Services."),
        HAZARD_FIRE("hazard_fire", "Warning! Large open fire detected ahead. Move to safety immediately. Calling Fire and Rescue Services unless you cancel."),
        HAZARD_POLICE("hazard_police", "Safety threat detected. Calling Police Emergency Services shortly unless you cancel."),
        CALLING_AMBULANCE("calling_ambulance", "Calling Ambulance Services now and transmitting your location and smart glasses report."),
        CALLING_FIRE_DEPARTMENT("calling_fire_department", "Calling Fire and Rescue Services now and transmitting your location and smart glasses report."),
        CALLING_POLICE("calling_police", "Calling Police Emergency Services now and transmitting your location and smart glasses report."),
        EMERGENCY_CANCELLED("emergency_cancelled", "Emergency call cancelled. Monitoring resumed.");

        companion object {
            fun forHazardCheckIn(hazardType: HazardType): Phrase = when (hazardType) {
                HazardType.FIRE -> HAZARD_FIRE
                HazardType.POLICE -> HAZARD_POLICE
                HazardType.MEDICAL, HazardType.NONE -> HAZARD_MEDICAL
            }

            fun forCallingService(service: HelpService): Phrase = when (service) {
                HelpService.AMBULANCE -> CALLING_AMBULANCE
                HelpService.FIRE_DEPARTMENT -> CALLING_FIRE_DEPARTMENT
                HelpService.POLICE -> CALLING_POLICE
            }
        }
    }

    private val cacheDir = File(context.cacheDir, "voice").apply { mkdirs() }
    private val briefingCacheDir = File(cacheDir, "briefings").apply { mkdirs() }
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

    /** Downloads fixed prompts in the background so hazard alerts play with zero delay. */
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
            if (audio == null || !play(audio)) speakTextOnDevice(phrase.text, phrase.id)
        }
    }

    fun speakBriefing(receipt: DispatchReceipt, contextSummary: String? = null, heartRateBpm: Int? = null) {
        stop()
        job = scope.launch {
            val audio = if (backendConfigured) {
                runCatching {
                    withContext(Dispatchers.IO) {
                        cachedBriefingAudio(receipt, contextSummary, heartRateBpm)
                    }
                }.getOrNull()
            } else {
                null
            }
            if (!isActive) return@launch
            if (audio == null || !play(audio)) {
                speakTextOnDevice(receipt.briefingScript, "briefing_${receipt.id}")
            }
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
        file.delete()
        false
    }

    private fun speakTextOnDevice(text: String, utteranceId: String) {
        if (ttsReady && text.isNotBlank()) {
            tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
        }
    }

    private fun cachedAudio(phrase: Phrase): File {
        val file = File(cacheDir, "${phrase.id}.mp3")
        if (file.length() > 0) return file
        val connection = URL(BuildConfig.AI_BASE_URL.trimEnd('/') + "/v1/speech/" + phrase.id).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 3_000
            connection.readTimeout = 9_000
            connection.setRequestProperty("Authorization", "Bearer ${BuildConfig.AI_CLIENT_TOKEN}")
            check(connection.responseCode == 200 && connection.contentType?.startsWith("audio/mpeg") == true) { "Speech unavailable" }
            return writeStreamToCache(connection, phrase.id, cacheDir, file)
        } finally {
            connection.disconnect()
        }
    }

    private fun cachedBriefingAudio(
        receipt: DispatchReceipt,
        contextSummary: String?,
        heartRateBpm: Int?,
    ): File {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(receipt.briefingScript.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
            .take(24)
        val file = File(briefingCacheDir, "briefing_$digest.mp3")
        if (file.length() > 0) return file

        val payload = JSONObject().apply {
            if (!receipt.offlineFallback) {
                put("incidentId", receipt.id)
            } else {
                put("service", receipt.service.wireName)
                put("hazardType", receipt.hazardType.wireName)
                put("trigger", receipt.trigger)
                put("location", receipt.location)
                if (!contextSummary.isNullOrBlank()) put("context", contextSummary.take(900))
                if (heartRateBpm != null) put("heartRateBpm", heartRateBpm)
            }
        }
        val bytes = payload.toString().toByteArray(Charsets.UTF_8)
        val connection = URL(BuildConfig.AI_BASE_URL.trimEnd('/') + "/v1/speech/briefing").openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 3_500
            connection.readTimeout = 14_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Authorization", "Bearer ${BuildConfig.AI_CLIENT_TOKEN}")
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            check(connection.responseCode == 200 && connection.contentType?.startsWith("audio/mpeg") == true) {
                "Briefing speech unavailable"
            }
            return writeStreamToCache(connection, "briefing_$digest", briefingCacheDir, file)
        } finally {
            connection.disconnect()
        }
    }

    private fun writeStreamToCache(
        connection: HttpURLConnection,
        prefix: String,
        directory: File,
        destination: File,
    ): File {
        val partial = File.createTempFile(prefix, ".part", directory)
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
            check(partial.renameTo(destination)) { "Could not cache speech" }
        } finally {
            partial.delete()
        }
        return destination
    }

    companion object {
        private const val MAX_AUDIO_BYTES = 1024 * 1024
    }
}
