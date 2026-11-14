package com.rayguardian.app

import android.graphics.Bitmap
import android.os.Bundle
import android.os.SystemClock
import android.util.Base64
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import com.meta.wearable.dat.camera.Camera
import com.meta.wearable.dat.camera.addCamera
import com.meta.wearable.dat.camera.types.AudioCodec
import com.meta.wearable.dat.camera.types.AudioSampleRate
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.StreamError
import com.meta.wearable.dat.camera.types.StreamState
import com.meta.wearable.dat.camera.types.VideoQuality
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.selectors.AutoDeviceSelector
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.session.DeviceSessionState
import com.meta.wearable.dat.core.types.Device
import com.meta.wearable.dat.core.types.DonState
import com.meta.wearable.dat.core.types.HingeState
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.core.types.ThermalLevel
import java.io.ByteArrayOutputStream
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** Foreground hardware session with bounded capture and a local test dispatch. */
class LiveGlassesActivity : ComponentActivity() {
    private lateinit var panel: LinearLayout
    private lateinit var preview: ImageView
    private lateinit var connection: TextView
    private lateinit var audioStatus: TextView
    private lateinit var aiStatus: TextView
    private lateinit var incident: TextView
    private lateinit var receipt: TextView
    private lateinit var captureButton: Button
    private lateinit var microphone: CheckBox
    private lateinit var shareFrames: CheckBox
    private lateinit var cancelButton: Button
    private lateinit var retryButton: Button
    private lateinit var voice: VoicePrompts
    private lateinit var captureSealPanel: CaptureSealPanel
    private val state = DemoSession()
    private val visionApi = AiClient()
    private val dispatchApi = AiClient()
    private val frames = ArrayDeque<String>(3)
    private var captureJob: Job? = null
    private var retainAnalysisOnCaptureEnd = false
    private val captureStarts = ArrayDeque<Long>()
    private var analysisJob: Job? = null
    private var incidentJob: Job? = null
    private var dispatchJob: Job? = null
    private var permissionJob: Job? = null
    private var requestedPermission: Permission? = null
    private var lastFrameAt = 0L
    private var lastSoundAt = 0L
    private var nextAnalysisAt = 0L
    private var candidateContext: String? = null
    private var dispatchId: String? = null
    // Shared with the recorder/seal hook when connected; never wait on it to deliver SOS.
    private var recordingIncidentId: String? = null
    private var foreground = false
    private var streaming = false

    private val permissions = registerForActivityResult(Wearables.RequestPermissionContract()) { result ->
        requestedPermission = null
        connection.text = if (result.getOrDefault(PermissionStatus.Denied) == PermissionStatus.Granted) {
            "Permission granted. Tap Capture 8-second diagnostic to continue."
        } else "Glasses permission was declined or unavailable in Meta AI."
        captureButton.isEnabled = true
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        voice = VoicePrompts(this, lifecycleScope)
        val scroll = ScrollView(this)
        panel = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        panel.setOnApplyWindowInsetsListener { view, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            view.setPadding(dp(16), dp(14) + bars.top, dp(16), dp(20) + bars.bottom)
            insets
        }
        scroll.addView(panel)
        setContentView(scroll)
        label("Ray Guardian · Live glasses", 25f)
        label("Manual bounded sensor diagnostic · Simulated dispatch", 15f)
        connection = label("Ready to connect to paired glasses.")
        preview = ImageView(this).apply {
            contentDescription = "Latest image from the glasses camera"
            scaleType = ImageView.ScaleType.FIT_CENTER
            setBackgroundColor(0xff101914.toInt())
            layoutParams = LinearLayout.LayoutParams(-1, dp(200))
        }.also(panel::addView)
        audioStatus = label("Glasses microphone off")
        aiStatus = label("Nemotron off")
        incident = label("No check-in active")
        cancelButton = action("I'm OK · Cancel check-in") { cancelCheckIn() }.apply { isEnabled = false }
        action("Simulate SOS now") { manualSos() }
        receipt = label("")
        captureSealPanel = CaptureSealPanel(this,lifecycleScope) { recordingIncidentId ?: dispatchId }
        panel.addView(captureSealPanel)
        action("Capture signing key · admin enrollment") { showCaptureKeyEnrollment(this,lifecycleScope) }
        retryButton = action("Retry simulated dispatch") { sendDispatch() }.apply { isEnabled = false }
        microphone = option("Include glasses microphone levels (loudness never triggers alone)")
        shareFrames = option("Send sampled camera frames to Verda / Nemotron")
        captureButton = action("Capture 8-second diagnostic") {
            if (captureJob != null) stopCapture("Monitoring stopped.") else prepare()
        }
    }

    override fun onResume() {
        super.onResume()
        foreground = true
    }

    override fun onPause() {
        foreground = false
        permissionJob?.cancel()
        stopCapture("Monitoring is off while the app is in the background.")
        incidentJob?.cancel()
        if (state.phase == DemoSession.Phase.CHECK_IN) cancelCheckIn(speak = false)
        state.disarm()
        dispatchJob?.cancel()
        dispatchApi.cancel()
        voice.stop()
        super.onPause()
    }

    override fun onDestroy() {
        voice.release()
        super.onDestroy()
    }

    private fun prepare() {
        if (permissionJob?.isActive == true || requestedPermission != null || !foreground) return
        captureButton.isEnabled = false
        val useAudio = microphone.isChecked
        val useVision = shareFrames.isChecked
        permissionJob = lifecycleScope.launch {
            try {
                connection.text = "Checking glasses permissions…"
                val required = if (useAudio) listOf(Permission.CAMERA, Permission.MICROPHONE) else listOf(Permission.CAMERA)
                for (permission in required) {
                    val status = withTimeoutOrNull(10_000) { Wearables.checkPermissionStatus(permission) }
                    if (status?.getOrDefault(PermissionStatus.Denied) != PermissionStatus.Granted) {
                        check(foreground)
                        requestedPermission = permission
                        permissions.launch(permission)
                        return@launch
                    }
                }
                if (foreground) startCapture(useAudio, useVision)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                requestedPermission = null
                connection.text = error.message ?: "Could not check glasses permissions."
            } finally {
                captureButton.isEnabled = requestedPermission == null
            }
        }
    }

    private fun startCapture(useAudio: Boolean, useVision: Boolean) {
        val now = SystemClock.elapsedRealtime()
        while (captureStarts.isNotEmpty() && now - captureStarts.first() >= 600_000) captureStarts.removeFirst()
        if (captureStarts.size >= 3 || captureStarts.lastOrNull()?.let { now - it < 60_000 } == true) {
            connection.text = "Capture budget: wait 60 seconds between bursts; maximum three per ten minutes."
            return
        }
        captureStarts.addLast(now)
        recordingIncidentId = UUID.randomUUID().toString()
        captureSealPanel.show(CaptureSealStatus.UNTRUSTED)
        retainAnalysisOnCaptureEnd = false
        if (state.phase == DemoSession.Phase.DISARMED) state.arm()
        captureButton.text = "Stop diagnostic capture"
        microphone.isEnabled = false
        shareFrames.isEnabled = false
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        audioStatus.text = if (useAudio) "Waiting for glasses microphone…" else "Glasses microphone off"
        aiStatus.text = if (useVision) "Waiting for camera samples…" else "Nemotron off"
        connection.text = "Starting glasses session…"
        lastFrameAt = 0L
        lastSoundAt = 0L
        nextAnalysisAt = 0L
        analysisJob?.cancel()
        analysisJob = null
        captureJob = lifecycleScope.launch {
            var session: DeviceSession? = null
            var camera: Camera? = null
            try {
                val ended = withTimeoutOrNull(8_000) {
                Wearables.createSession(AutoDeviceSelector()).fold(
                    onSuccess = { session = it },
                    onFailure = { error, _ -> error(error.description) },
                )
                val deviceSession = checkNotNull(session)
                deviceSession.start()
                val ready = withTimeoutOrNull(15_000) {
                    deviceSession.state.first { it == DeviceSessionState.STARTED || it == DeviceSessionState.STOPPED }
                }
                check(ready == DeviceSessionState.STARTED) { "Glasses session could not start. Check pairing and wear the glasses." }
                check(deviceLimit(deviceSession.deviceInfo.value) == null) {
                    deviceLimit(deviceSession.deviceInfo.value) ?: "Glasses are unavailable."
                }
                val options = StreamConfiguration(
                    audioCodec = if (useAudio) AudioCodec.PCM(AudioSampleRate.RATE_16000, 1) else null,
                    videoQuality = VideoQuality.LOW,
                    frameRate = 7,
                    compressVideo = true,
                )
                deviceSession.addCamera(options).fold(
                    onSuccess = { camera = it },
                    onFailure = { error, _ -> error(error.description) },
                )
                monitor(deviceSession, checkNotNull(camera), useAudio, useVision)
                }
                if (ended == null) { retainAnalysisOnCaptureEnd = true; connection.text = "Eight-second diagnostic ended; camera off." }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                connection.text = error.message ?: "Glasses stream failed."
            } finally {
                try { camera?.stop() } finally {
                    try { session?.stop() } finally {
                        captureJob = null
                        clearStreams()
                    }
                }
            }
        }
    }

    private suspend fun monitor(session: DeviceSession, camera: Camera, useAudio: Boolean, useVision: Boolean): Unit = coroutineScope {
        val stream = camera.stream
        val started = SystemClock.elapsedRealtime()
        launch {
            session.state.collect { state ->
                check(state !in setOf(DeviceSessionState.STOPPING, DeviceSessionState.STOPPED)) { "Glasses disconnected." }
                if (state == DeviceSessionState.PAUSED) error("Glasses session paused. Restart when available.")
            }
        }
        launch {
            session.deviceInfo.collect { device -> deviceLimit(device)?.let { error(it) } }
        }
        launch {
            stream.errorStream.collect { error ->
                if (error != StreamError.STREAM_ERROR) error("Glasses stream: ${error.description}")
            }
        }
        launch {
            stream.state.collect { status ->
                if (status == StreamState.PAUSED || status == StreamState.CLOSED) error("Glasses stream ${status.name.lowercase()}.")
            }
        }
        launch(Dispatchers.Default) {
            var decoder: GlassesFrameDecoder? = null
            try {
                stream.videoStream.collect { frame ->
                    if (decoder == null) decoder = GlassesFrameDecoder(frame.width, frame.height)
                    var sample: Bitmap? = null
                    decoder?.accept(frame) { sample = it }
                    val bitmap = sample ?: return@collect
                    val encoded = if (useVision) {
                        val jpeg = ByteArrayOutputStream()
                        check(bitmap.compress(Bitmap.CompressFormat.JPEG, 70, jpeg)) { "Could not encode a glasses frame." }
                        "data:image/jpeg;base64," + Base64.encodeToString(jpeg.toByteArray(), Base64.NO_WRAP)
                    } else null
                    withContext(Dispatchers.Main) { onFrame(bitmap, encoded) }
                }
            } finally { decoder?.close() }
        }
        if (useAudio) launch(Dispatchers.Default) {
            val detector = LoudSoundDetector()
            var lastUi = 0L
            stream.audioStream.collect { frame ->
                val level = detector.accept(frame.buffer, frame.presentationTimeUs) ?: return@collect
                val now = SystemClock.elapsedRealtime()
                if (now - lastUi >= 500 || level.sustained && now - lastUi >= 150) {
                    lastUi = now
                    withContext(Dispatchers.Main) {
                        lastSoundAt = now
                        audioStatus.text = "Glasses microphone · ${level.dbfs} dBFS"
                        if (level.sustained) audioStatus.text = "Loud audio observed · no check-in from loudness alone"
                    }
                }
            }
        }
        stream.start().onFailure { error, _ -> error(error.description) }
        launch {
            while (true) {
                delay(1000)
                val now = SystemClock.elapsedRealtime()
                val receivedAt = lastFrameAt
                check(if (receivedAt == 0L) now - started < 20_000 else now - receivedAt < 6_000) {
                    "No recent camera images. Check Bluetooth and restart monitoring."
                }
                check(now - started < 120_000) { "Two-minute live session ended. Restart when ready." }
                if (useAudio && now - (lastSoundAt.takeIf { it != 0L } ?: started) > 8_000) {
                    audioStatus.text = "No audio frames. Check Audio Streaming approval and microphone permission."
                }
            }
        }
        awaitCancellation()
    }

    private fun deviceLimit(device: Device): String? = when {
        device.thermalLevel >= ThermalLevel.MODERATE -> "Glasses thermal level is ${device.thermalLevel.name.lowercase()}. Let them cool."
        device.batteryLevel in 0..15 -> "Glasses battery is low. Charge before restarting."
        device.donState == DonState.DOFFED || device.hingeState == HingeState.CLOSED -> "Wear and unfold the glasses to monitor."
        else -> null
    }

    private fun onFrame(bitmap: Bitmap, encoded: String?) {
        if (!foreground || captureJob?.isActive != true) return
        lastFrameAt = SystemClock.elapsedRealtime()
        if (!streaming) {
            streaming = true
            connection.text = "Live camera · bounded manual diagnostic"
        }
        preview.setImageBitmap(bitmap)
        if (encoded == null || state.phase != DemoSession.Phase.ARMED) return
        if (frames.size == 3) frames.removeFirst()
        frames.addLast(encoded)
        if (frames.size < 3 || analysisJob != null || lastFrameAt < nextAnalysisAt) return
        val sample = frames.toList()
        frames.clear()
        nextAnalysisAt = lastFrameAt + 8_000
        analysisJob = lifecycleScope.launch {
            aiStatus.text = "Nemotron examining 3 live frames…"
            try {
                val result = visionApi.assessLiveFrames(sample)
                aiStatus.text = result.summary
                if (result.checkInRecommended) beginCheckIn(DemoSession.Trigger.LIVE_VISION, result.summary)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                aiStatus.text = error.message ?: "Nemotron unavailable."
            }
        }
    }

    private fun beginCheckIn(trigger: DemoSession.Trigger, context: String) {
        if (!foreground || state.phase != DemoSession.Phase.ARMED) return
        state.replayCandidate(SystemClock.elapsedRealtime(), trigger)
        candidateContext = context
        cancelButton.isEnabled = true
        voice.speak(VoicePrompts.Phrase.CHECK_IN)
        incidentJob = lifecycleScope.launch {
            while (state.phase == DemoSession.Phase.CHECK_IN) {
                val now = SystemClock.elapsedRealtime()
                state.tick(now)
                if (state.phase == DemoSession.Phase.ALERT) {
                    finishCheckIn()
                    return@launch
                }
                val seconds = ((state.deadlineMillis ?: now) - now + 999) / 1000
                incident.text = "Are you okay? Test call in $seconds s\n$context"
                delay(200)
            }
        }
    }

    private fun cancelCheckIn(speak: Boolean = true) {
        if (state.phase != DemoSession.Phase.CHECK_IN) return
        state.cancel()
        incidentJob?.cancel()
        cancelButton.isEnabled = false
        candidateContext = null
        frames.clear()
        analysisJob?.cancel()
        visionApi.cancel()
        nextAnalysisAt = SystemClock.elapsedRealtime() + 8_000
        incident.text = "Check-in cancelled."
        if (speak) voice.speak(VoicePrompts.Phrase.CHECK_IN_CANCELLED)
    }

    private fun manualSos() {
        if (dispatchJob?.isActive == true || state.phase == DemoSession.Phase.ALERT) return
        if (state.phase == DemoSession.Phase.DISARMED) state.arm()
        state.manualSos()
        incidentJob?.cancel()
        candidateContext = null
        finishCheckIn()
    }

    private fun finishCheckIn() {
        cancelButton.isEnabled = false
        dispatchId = recordingIncidentId ?: UUID.randomUUID().toString()
        recordingIncidentId = null
        captureSealPanel.show(CaptureSealStatus.UNTRUSTED)
        incident.text = "Check-in ended. Sending to test dispatch…"
        voice.speak(VoicePrompts.Phrase.ALERT_CREATED)
        sendDispatch()
    }

    private fun sendDispatch() {
        if (!foreground || dispatchJob?.isActive == true) return
        val id = dispatchId ?: return
        val cause = when (state.trigger) {
            DemoSession.Trigger.LIVE_VISION -> "live-vision"
            DemoSession.Trigger.LOUD_SOUND -> "loud-sound"
            else -> "manual-sos"
        }
        retryButton.isEnabled = false
        dispatchJob = lifecycleScope.launch {
            try {
                val result = dispatchApi.simulateDispatch(id, cause, candidateContext)
                receipt.text = "Simulated call accepted · ${result.callId}\nTest location: ${result.location}"
                incident.text = "Test dispatch accepted the alert."
                state.finish()
                if (captureJob?.isActive == true) { state.arm(); nextAnalysisAt = SystemClock.elapsedRealtime() + 12_000 }
            } catch (error: Exception) {
                if (error is CancellationException) {
                    retryButton.isEnabled = true
                    throw error
                }
                receipt.text = "Test dispatch unavailable. Check the backend and retry."
                retryButton.isEnabled = true
            }
        }
    }

    private fun stopCapture(message: String) {
        retainAnalysisOnCaptureEnd = false
        connection.text = message
        captureJob?.cancel()
        analysisJob?.cancel()
        visionApi.cancel()
    }

    private fun clearStreams() {
        frames.clear()
        if (!retainAnalysisOnCaptureEnd) {
            analysisJob?.cancel()
            visionApi.cancel()
            if (state.phase == DemoSession.Phase.ARMED) state.disarm()
        }
        streaming = false
        preview.setImageDrawable(null)
        audioStatus.text = "Glasses microphone off"
        captureButton.text = "Capture 8-second diagnostic"
        microphone.isEnabled = true
        shareFrames.isEnabled = true
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun label(value: String, size: Float = 15f) = TextView(this).apply {
        text = value
        textSize = size
        setPadding(0, dp(7), 0, dp(7))
        panel.addView(this)
    }

    private fun action(value: String, onClick: () -> Unit) = Button(this).apply {
        text = value
        isAllCaps = false
        setOnClickListener { onClick() }
        panel.addView(this)
    }

    private fun option(value: String) = CheckBox(this).apply {
        text = value
        panel.addView(this)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
