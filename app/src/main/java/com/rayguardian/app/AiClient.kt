package com.rayguardian.app

import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import android.util.Base64
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

internal data class SimulatedDispatchReceipt(val callId: String, val location: String)

/** Talks only to our backend. Verda and ElevenLabs credentials never live inside the APK. */
class AiClient {
    @Volatile private var active: HttpURLConnection? = null

    fun cancel() {
        active?.disconnect()
    }

    internal suspend fun createCaptureAttempt(identity: AndroidCaptureIdentity.Enrollment, incidentId: String): JSONObject =
        postJson("/v1/capture-attempts",JSONObject().put("keyId",identity.keyId).put("installationId",identity.installationId).put("incidentId",incidentId),5_000,8192)

    /** Upload bytes only. This endpoint/client never generates capture signatures. */
    internal suspend fun uploadSignedRecording(artifact: SealedCaptureUpload): CaptureSealStatus = withContext(Dispatchers.IO) {
        ensureActive()
        check(artifact.original.length() in 12..LiveCaptureSeal.MAX_BYTES)
        val connection=openCaptureConnection("/v1/incidents/${artifact.incidentId}/recording")
        active=connection
        try {
            connection.requestMethod="POST";connection.doOutput=true
            connection.setRequestProperty("Content-Type","video/mp4")
            connection.setRequestProperty("X-Guardian-Receipt",Base64.encodeToString(artifact.receiptBytes,Base64.NO_WRAP))
            connection.setRequestProperty("X-Guardian-Signature",Base64.encodeToString(artifact.signatureBytes,Base64.NO_WRAP))
            connection.setFixedLengthStreamingMode(artifact.original.length())
            connection.outputStream.use { output -> artifact.original.inputStream().use { it.copyTo(output) } }
            ensureActive()
            check(connection.responseCode==200) { "Recording verification failed (${connection.responseCode}); the original upload can be retried. SOS is independent." }
            val response=readBoundedJson(connection,8192)
            val status=CaptureSealStatus.fromWire(response.optString("status"))
            if(status==CaptureSealStatus.MATCHES) {
                val signed=JSONObject(String(artifact.receiptBytes,Charsets.UTF_8))
                check(response.getString("incidentId")==artifact.incidentId && response.getString("keyId")==signed.getString("keyId") && response.getString("videoSha256")==signed.getString("videoSha256")) { "Verification response did not match this recording." }
            }
            status
        } finally { if(active===connection)active=null;connection.disconnect() }
    }

    internal suspend fun captureSealStatus(incidentId: String): CaptureSealStatus = withContext(Dispatchers.IO) {
        check(java.util.UUID.fromString(incidentId).toString()==incidentId)
        val connection=openCaptureConnection("/v1/incidents/$incidentId/recording")
        active=connection
        try {
            connection.requestMethod="GET"
            check(connection.responseCode==200) { "Recording verification is unavailable." }
            val json=readBoundedJson(connection,8192)
            val status=CaptureSealStatus.fromWire(json.optString("status"))
            if(status==CaptureSealStatus.MATCHES)check(json.getString("incidentId")==incidentId)
            status
        }finally{if(active===connection)active=null;connection.disconnect()}
    }

    private fun openCaptureConnection(path: String): HttpURLConnection {
        check(BuildConfig.AI_BASE_URL.isNotBlank()&&BuildConfig.AI_CLIENT_TOKEN.isNotBlank()) { "Backend connection is not configured." }
        return (URL(BuildConfig.AI_BASE_URL.trimEnd('/')+path).openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects=false;connectTimeout=5_000;readTimeout=20_000
            setRequestProperty("Authorization","Bearer ${BuildConfig.AI_CLIENT_TOKEN}")
        }
    }

    suspend fun analyze(description: String, imageDataUrl: String?): AiContext = withContext(Dispatchers.IO) {
        val response = postAnalyze(
            JSONObject().apply {
                put("consent", true)
                put("description", description)
                if (imageDataUrl != null) put("imageDataUrl", imageDataUrl)
            },
        )
        AiContext(
            summary = response.getString("summary"),
            observations = parseList(response, "observations"),
            uncertainties = parseList(response, "uncertainties"),
        )
    }

    suspend fun assessLiveFrames(frames: List<String>): AiContext = withContext(Dispatchers.IO) {
        val response = postAnalyze(
            JSONObject().apply {
                put("consent", true)
                put("description", "Ordered first-person video frames sampled from Meta glasses.")
                put("imageDataUrls", JSONArray(frames))
                put("assessCollapse", true)
            },
        )
        val checkIn = response.opt("checkInRecommended") as? Boolean
            ?: error("Nemotron returned an invalid check-in assessment.")
        AiContext(
            summary = response.getString("summary"),
            observations = parseList(response, "observations"),
            uncertainties = parseList(response, "uncertainties"),
            checkInRecommended = checkIn,
        )
    }

    suspend fun analyzeHazards(
        description: String,
        imageDataUrls: List<String>,
        sandboxScenario: String? = null,
    ): HazardAssessment = withContext(Dispatchers.IO) {
        val frames = JSONArray().apply { imageDataUrls.take(3).forEach { put(it) } }
        val response = postAnalyze(
            JSONObject().apply {
                put("consent", true)
                put("description", description)
                put("imageDataUrls", frames)
                put("assessHazards", true)
                if (!sandboxScenario.isNullOrBlank()) put("sandboxScenario", sandboxScenario)
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

    internal suspend fun simulateDispatch(id: String, trigger: String, context: String?): SimulatedDispatchReceipt {
        val request = JSONObject().put("id", id).put("trigger", trigger)
        if (context != null) request.put("context", context.take(1000))
        val response = postJson("/v1/simulated-dispatch", request, readTimeoutMillis = 5_000, maxResponseBytes = 32 * 1024)
        check(response.optString("status") == "simulated-accepted") { "Unexpected dispatch response." }
        return SimulatedDispatchReceipt(response.getString("callId"), response.getString("location"))
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
        val response = postJson("/v1/analyze", request, readTimeoutMillis = 50_000, maxResponseBytes = 64 * 1024)
        val validSource = response.optString("source") in setOf("nemotron", "sandbox") || response.optBoolean("sandbox")
        check(response.optBoolean("advisoryOnly") && validSource) {
            "The AI service returned an unexpected response."
        }
        return response
    }

    private suspend fun postJson(
        path: String,
        request: JSONObject,
        readTimeoutMillis: Int,
        maxResponseBytes: Int,
    ): JSONObject = withContext(Dispatchers.IO) {
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
            connection.readTimeout = readTimeoutMillis
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
            val response = readBoundedJson(connection, maxResponseBytes)
            ensureActive()
            response
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
        val values = response.optJSONArray(name) ?: return emptyList()
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
