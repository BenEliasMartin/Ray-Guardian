package com.rayguardian.app

import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

data class AiContext(val summary: String, val observations: List<String>, val uncertainties: List<String>)

/** Talks only to our backend. Verda and ElevenLabs credentials never live inside the APK. */
class AiClient {
    @Volatile private var active: HttpURLConnection? = null

    fun cancel() { active?.disconnect() }

    suspend fun analyze(description: String, imageDataUrl: String?): AiContext = withContext(Dispatchers.IO) {
        val response = postAnalyze(
            JSONObject().apply {
                put("consent", true)
                put("description", description)
                if (imageDataUrl != null) put("imageDataUrl", imageDataUrl)
            },
        )
        AiContext(response.getString("summary"), parseList(response, "observations"), parseList(response, "uncertainties"))
    }

    suspend fun analyzeHazards(description: String, imageDataUrls: List<String>): HazardAssessment = withContext(Dispatchers.IO) {
        val frames = JSONArray().apply { imageDataUrls.take(3).forEach { put(it) } }
        val response = postAnalyze(
            JSONObject().apply {
                put("consent", true)
                put("description", description)
                put("imageDataUrls", frames)
                put("assessHazards", true)
            },
        )
        val hazardType = HazardType.fromWire(response.optString("hazardType"))
        val detected = response.optBoolean("hazardDetected", false) && hazardType != HazardType.NONE
        val service = if (detected) {
            HelpService.fromWire(response.optString("recommendedService")) ?: hazardType.defaultService()
        } else {
            null
        }
        HazardAssessment(
            summary = response.getString("summary"),
            observations = parseList(response, "observations"),
            uncertainties = parseList(response, "uncertainties"),
            hazardDetected = detected,
            hazardType = if (detected) hazardType else HazardType.NONE,
            severity = response.optString("severity", "none"),
            recommendedService = service,
            urgentImmediate = detected && response.optBoolean("urgentImmediate", false),
        )
    }

    suspend fun dispatchIncident(
        id: String,
        trigger: String,
        hazardType: HazardType,
        service: HelpService,
        location: String,
        contextSummary: String?,
        heartRateBpm: Int? = null,
        dialNumber: String? = null,
    ): DispatchReceipt = withContext(Dispatchers.IO) {
        if (BuildConfig.AI_BASE_URL.isBlank() || BuildConfig.AI_CLIENT_TOKEN.isBlank()) {
            return@withContext offlineReceipt(id, trigger, hazardType, service, location, contextSummary, heartRateBpm)
        }
        val connection = URL(BuildConfig.AI_BASE_URL.trimEnd('/') + "/v1/dispatch").openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 5_000
            connection.readTimeout = 8_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Authorization", "Bearer ${BuildConfig.AI_CLIENT_TOKEN}")
            val request = JSONObject().apply {
                put("id", id)
                put("trigger", trigger)
                put("hazardType", hazardType.wireName)
                put("service", service.wireName)
                put("location", location.take(240))
                if (!contextSummary.isNullOrBlank()) put("context", contextSummary.take(1000))
                if (heartRateBpm != null) put("heartRateBpm", heartRateBpm)
                if (!dialNumber.isNullOrBlank() && EmergencyDialer.validateNumber(dialNumber) is EmergencyDialer.Validation.Valid) {
                    put("dialNumber", dialNumber.take(32))
                }
            }
            val bytes = request.toString().toByteArray(Charsets.UTF_8)
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            if (connection.responseCode != 200) {
                return@withContext offlineReceipt(id, trigger, hazardType, service, location, contextSummary, heartRateBpm)
            }
            val json = readBoundedJson(connection, 32 * 1024)
            val resolvedService = HelpService.fromWire(json.optString("service")) ?: service
            val resolvedHazard = HazardType.fromWire(json.optString("hazardType")).takeIf { it != HazardType.NONE } ?: hazardType
            DispatchReceipt(
                id = json.optString("id", id),
                callId = json.optString("callId", fallbackCallId(resolvedService, id)),
                status = json.optString("status", "dispatched"),
                service = resolvedService,
                serviceLabel = json.optString("serviceLabel", resolvedService.title),
                shortServiceLabel = json.optString("shortServiceLabel", resolvedService.shortTitle),
                hazardType = resolvedHazard,
                trigger = json.optString("trigger", trigger),
                location = json.optString("location", location),
                contextIncluded = json.optBoolean("contextIncluded", !contextSummary.isNullOrBlank()),
                briefingScript = json.optString("briefingScript").ifBlank {
                    EmergencyDialer.buildOfflineBriefing(resolvedService, resolvedHazard, location, contextSummary, heartRateBpm)
                },
                offlineFallback = false,
            )
        } catch (_: Exception) {
            offlineReceipt(id, trigger, hazardType, service, location, contextSummary, heartRateBpm)
        } finally {
            connection.disconnect()
        }
    }

    private suspend fun postAnalyze(request: JSONObject): JSONObject {
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
            val response = readBoundedJson(connection, 64 * 1024)
            ensureActive()
            check(response.optBoolean("advisoryOnly") && response.optString("source") == "nemotron") {
                "The AI service returned an unexpected response."
            }
            return response
        } finally {
            if (active === connection) active = null
            connection.disconnect()
        }
    }

    private fun readBoundedJson(connection: HttpURLConnection, maxBytes: Int): JSONObject =
        connection.inputStream.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                output.write(buffer, 0, count)
                check(output.size() <= maxBytes) { "The server response was too large." }
            }
            JSONObject(String(output.toByteArray(), Charsets.UTF_8))
        }

    private fun parseList(response: JSONObject, name: String): List<String> {
        val values = response.getJSONArray(name)
        check(values.length() <= 6) { "The AI response was invalid." }
        return List(values.length()) { values.getString(it) }
    }

    private fun fallbackCallId(service: HelpService, id: String): String {
        val prefix = when (service) {
            HelpService.FIRE_DEPARTMENT -> "FIRE"
            HelpService.POLICE -> "POL"
            HelpService.AMBULANCE -> "MED"
        }
        return "$prefix-${id.take(8).uppercase()}"
    }

    private fun offlineReceipt(
        id: String,
        trigger: String,
        hazardType: HazardType,
        service: HelpService,
        location: String,
        contextSummary: String?,
        heartRateBpm: Int?,
    ): DispatchReceipt = DispatchReceipt(
        id = id,
        callId = fallbackCallId(service, id),
        status = "local-dispatched",
        service = service,
        serviceLabel = service.title,
        shortServiceLabel = service.shortTitle,
        hazardType = hazardType,
        trigger = trigger,
        location = location,
        contextIncluded = !contextSummary.isNullOrBlank(),
        briefingScript = EmergencyDialer.buildOfflineBriefing(service, hazardType, location, contextSummary, heartRateBpm),
        offlineFallback = true,
    )
}
