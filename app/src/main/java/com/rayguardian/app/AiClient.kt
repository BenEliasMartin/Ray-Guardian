package com.rayguardian.app

import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

data class AiContext(
    val summary: String,
    val observations: List<String>,
    val uncertainties: List<String>,
    val checkInRecommended: Boolean = false,
)

internal data class DispatchReceipt(val callId: String, val location: String)

/** Talks only to our backend. The Verda inference credential is never part of the app. */
class AiClient {
    @Volatile private var active: HttpURLConnection? = null

    fun cancel() { active?.disconnect() }

    suspend fun analyze(description: String, imageDataUrl: String?): AiContext {
        val request = JSONObject().put("consent", true).put("description", description)
        if (imageDataUrl != null) request.put("imageDataUrl", imageDataUrl)
        return submit(request)
    }

    suspend fun assessLiveFrames(frames: List<String>): AiContext = submit(JSONObject()
        .put("consent", true)
        .put("description", "Ordered first-person video frames sampled from Meta glasses.")
        .put("imageDataUrls", JSONArray(frames))
        .put("assessCollapse", true))

    internal suspend fun simulateDispatch(id: String, trigger: String, context: String?): DispatchReceipt {
        val request = JSONObject().put("id", id).put("trigger", trigger)
        if (context != null) request.put("context", context.take(1000))
        val response = post("/v1/simulated-dispatch", request)
        check(response.getString("status") == "simulated-accepted") { "Unexpected dispatch response." }
        return DispatchReceipt(response.getString("callId"), response.getString("location"))
    }

    private suspend fun submit(request: JSONObject): AiContext {
        val response = post("/v1/analyze", request)
        check(response.optBoolean("advisoryOnly") && response.optString("source") == "nemotron") {
            "The AI service returned an unexpected response."
        }
        fun list(name: String): List<String> {
            val values = response.getJSONArray(name)
            check(values.length() <= 6) { "The AI response was invalid." }
            return List(values.length()) { values.getString(it) }
        }
        val assessment = if (request.optBoolean("assessCollapse")) {
            response.get("checkInRecommended") as? Boolean
                ?: error("Nemotron returned an invalid check-in assessment.")
        } else false
        return AiContext(response.getString("summary"), list("observations"), list("uncertainties"), assessment)
    }

    private suspend fun post(path: String, request: JSONObject): JSONObject = withContext(Dispatchers.IO) {
        ensureActive()
        check(BuildConfig.AI_BASE_URL.isNotBlank() && BuildConfig.AI_CLIENT_TOKEN.isNotBlank()) {
            "The AI connection is not configured in this build."
        }
        val connection = URL(BuildConfig.AI_BASE_URL.trimEnd('/') + path).openConnection() as HttpURLConnection
        active = connection
        try {
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 8_000
            connection.readTimeout = if (path == "/v1/analyze") 50_000 else 5_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Authorization", "Bearer ${BuildConfig.AI_CLIENT_TOKEN}")
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
            response
        } finally {
            if (active === connection) active = null
            connection.disconnect()
        }
    }
}
