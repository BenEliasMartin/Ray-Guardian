package com.rayguardian.app

import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject

data class AiContext(val summary: String, val observations: List<String>, val uncertainties: List<String>)

/** Talks only to our backend. The Verda inference credential is never part of the app. */
class AiClient {
    @Volatile private var active: HttpURLConnection? = null

    fun cancel() { active?.disconnect() }

    suspend fun analyze(description: String, imageDataUrl: String?): AiContext = withContext(Dispatchers.IO) {
        ensureActive()
        check(BuildConfig.AI_BASE_URL.isNotBlank() && BuildConfig.AI_CLIENT_TOKEN.isNotBlank()) {
            "The AI connection is not configured in this build."
        }
        val connection = URL(BuildConfig.AI_BASE_URL.trimEnd('/') + "/v1/analyze").openConnection() as HttpURLConnection
        active = connection
        try {
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 8_000
            connection.readTimeout = 50_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Authorization", "Bearer ${BuildConfig.AI_CLIENT_TOKEN}")
            val request = JSONObject().put("consent", true).put("description", description)
            if (imageDataUrl != null) request.put("imageDataUrl", imageDataUrl)
            val bytes = request.toString().toByteArray(Charsets.UTF_8)
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            ensureActive()
            val status = connection.responseCode
            if (status != 200) {
                val message = when (status) {
                    401 -> "The AI connection could not be authorized."
                    413 -> "The selected image is too large. Choose a smaller image."
                    429 -> "Analysis limit reached. Wait a minute and try again."
                    503 -> "The AI service is busy or unavailable. Try again shortly."
                    504 -> "Nemotron took too long. Try again later."
                    else -> "The analysis could not be completed. Try again later."
                }
                throw IllegalStateException(message)
            }
            val response = connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    check(output.size() <= 64 * 1024) { "The AI response was too large." }
                }
                val data = output.toByteArray()
                check(data.size <= 64 * 1024) { "The AI response was too large." }
                JSONObject(String(data, Charsets.UTF_8))
            }
            ensureActive()
            check(response.optBoolean("advisoryOnly") && response.optString("source") == "nemotron") {
                "The AI service returned an unexpected response."
            }
            fun list(name: String): List<String> {
                val values = response.getJSONArray(name)
                check(values.length() <= 6) { "The AI response was invalid." }
                return List(values.length()) { values.getString(it) }
            }
            AiContext(response.getString("summary"), list("observations"), list("uncertainties"))
        } finally {
            if (active === connection) active = null
            connection.disconnect()
        }
    }
}
