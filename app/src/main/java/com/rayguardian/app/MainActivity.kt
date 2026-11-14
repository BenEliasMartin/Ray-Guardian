package com.rayguardian.app

import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.WindowInsets
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.view.doOnNextLayout
import androidx.lifecycle.lifecycleScope
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.selectors.AutoDeviceSelector
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.session.DeviceSessionState
import com.meta.wearable.dat.core.types.DeviceIdentifier
import com.meta.wearable.dat.core.types.RegistrationState
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val demo = DemoSession()
    private val handler = Handler(Looper.getMainLooper())
    private var mode: IntegrationMode? = null
    private var registration = "Not connected"
    private var deviceName = "No glasses connected"
    private var deviceDetails = "Connect your glasses or use a simulated device."
    private var integrationError: String? = null
    private var metadataJob: Job? = null
    private var activeDeviceJob: Job? = null
    private var hasActiveDevice = false
    private var activeDeviceId: DeviceIdentifier? = null
    private var wearableSession: DeviceSession? = null
    private val deviceSelector by lazy { AutoDeviceSelector() }
    private var deviceSessionStatus = "Not started"
    private var batteryStatus = "unknown"
    private var thermalStatus = "unknown"
    private var cameraPermissionGranted = false
    private var registered = false
    private val triggers: TriggerRuntime by lazy {
        TriggerRuntime(lifecycleScope, captureBudget,
            onIncident = { signal ->
                when (signal) {
                    TriggerController.Signal.MANUAL_SOS -> demo.manualSos()
                    TriggerController.Signal.VOICE_SOS -> demo.manualSos(DemoSession.Trigger.VOICE_SOS)
                    TriggerController.Signal.FALL_CANDIDATE -> demo.replayCandidate(SystemClock.elapsedRealtime(), DemoSession.Trigger.FALL_CANDIDATE)
                    TriggerController.Signal.HEART_RATE -> demo.replayCandidate(SystemClock.elapsedRealtime(), DemoSession.Trigger.HEART_RATE_ANOMALY)
                    TriggerController.Signal.LOUD_VOICE -> Unit
                }
                if (::voice.isInitialized) {
                    if (demo.phase == DemoSession.Phase.CHECK_IN) voice.speak(if (signal == TriggerController.Signal.HEART_RATE) VoicePrompts.Phrase.CHECK_IN_HEART_RATE else VoicePrompts.Phrase.CHECK_IN)
                    else if (demo.phase == DemoSession.Phase.ALERT) voice.speak(VoicePrompts.Phrase.ALERT_CREATED)
                }
                handler.removeCallbacks(countdown)
                if (demo.phase == DemoSession.Phase.CHECK_IN) handler.post(countdown)
            },
            onChanged = {
                if (!triggers.controller.armed && (demo.phase == DemoSession.Phase.ARMED || demo.phase == DemoSession.Phase.CHECK_IN)) {
                    demo.disarm()
                    handler.removeCallbacks(countdown)
                }
                if (::content.isInitialized) render()
            },
        )
    }
    private var timerText: TextView? = null
    private lateinit var voice: VoicePrompts
    private val heartRateDetector = HeartRateAnomalyDetector()
    private var heartRateSource: HeartRateSource? = null
    private var heartRateStatus = "No watch connected"
    private var heartRateAssessment = HeartRateAnomalyDetector.Assessment(HeartRateAnomalyDetector.State.NO_DATA)
    private var heartRateAnomalySummary: String? = null
    private var heartRateValueText: TextView? = null
    private var heartRateStateText: TextView? = null
    private lateinit var content: LinearLayout
    private lateinit var scroll: ScrollView
    private var currentSessionCard: LinearLayout? = null
    private var lastRenderedPhase = DemoSession.Phase.DISARMED
    private var revealSession = false
    private var topInset = 0

    private enum class IntegrationMode { REAL, MOCK }

    companion object {
        // DAT and MockDeviceKit live for the process lifetime, including activity recreation.
        private var activeIntegrationMode: IntegrationMode? = null
        // Coarse capture timestamps only. Disarming or activity recreation does not reset limits.
        private val captureBudget = TriggerController.CaptureBudget()
    }

    private val glassesCameraPermission = registerForActivityResult(Wearables.RequestPermissionContract()) { result ->
        cameraPermissionGranted = false
        result.fold(onSuccess = { cameraPermissionGranted = it == PermissionStatus.Granted }, onFailure = { _, _ -> })
        refreshTriggerAvailability()
        render()
    }

    private val bluetoothPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) connectRealGlasses()
            else {
                integrationError = "Bluetooth access was not granted. You can still use the local demo."
                render()
            }
        }

    private val heartRatePermissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
            if (results.values.all { it }) startHeartRateSource(BleHeartRateSource(this))
            else {
                heartRateStatus = "Bluetooth access was not granted. You can still use a simulated watch."
                render()
            }
        }

    private val heartRateListener = object : HeartRateSource.Listener {
        override fun onSample(bpm: Int, skinContact: Boolean?) {
            onHeartRateAssessment(heartRateDetector.onSample(bpm, SystemClock.elapsedRealtime(), skinContact))
        }

        override fun onStatus(status: String) {
            heartRateStatus = status
            render()
        }
    }

    // Re-assesses once per second so a watch that stops reporting shows up as lost signal.
    private val heartRateTicker = object : Runnable {
        override fun run() {
            if (heartRateSource == null) return
            onHeartRateAssessment(heartRateDetector.assess(SystemClock.elapsedRealtime()))
            handler.postDelayed(this, 1_000L)
        }
    }

    private val countdown = object : Runnable {
        override fun run() {
            if (demo.phase != DemoSession.Phase.CHECK_IN) return
            val now = SystemClock.elapsedRealtime()
            demo.tick(now)
            if (demo.phase == DemoSession.Phase.ALERT) voice.speak(VoicePrompts.Phrase.ALERT_CREATED)
            if (demo.phase == DemoSession.Phase.CHECK_IN) {
                val seconds = ((demo.deadlineMillis!! - now + 999) / 1000).coerceAtLeast(0)
                timerText?.text = "Simulated alert in $seconds seconds"
                handler.postDelayed(this, 250)
            } else {
                render()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        voice = VoicePrompts(this, lifecycleScope)
        window.statusBarColor = color("#F6F7F4")
        window.navigationBarColor = color("#F6F7F4")
        scroll = ScrollView(this).apply {
            setBackgroundColor(color("#F6F7F4"))
            isFillViewport = true
        }
        content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(28), dp(22), dp(32))
        }
        scroll.setOnApplyWindowInsetsListener { _, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            topInset = bars.top
            content.setPadding(dp(22), dp(28) + bars.top, dp(22), dp(32) + bars.bottom)
            insets
        }
        scroll.addView(content)
        setContentView(scroll)
        mode = activeIntegrationMode
        if (mode != null) observeWearables()
        render()
        if (BuildConfig.DEBUG && intent.getBooleanExtra("ray_guardian_simulator", false) && mode == null) {
            connectMockGlasses()
        }
    }

    override fun onPause() {
        triggers.pause()
        // The rehearsal is foreground-only. It must never imply background coverage.
        if (demo.phase == DemoSession.Phase.ARMED || demo.phase == DemoSession.Phase.CHECK_IN) {
            demo.disarm()
            handler.removeCallbacks(countdown)
        }
        voice.stop()
        stopWearableSession()
        // Heart-rate screening is foreground-only as well.
        stopHeartRateSource()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        triggers.resume()
        refreshTriggerAvailability()
        if (mode == IntegrationMode.REAL) lifecycleScope.launch {
            cameraPermissionGranted = false
            Wearables.checkPermissionStatus(Permission.CAMERA).fold(
                onSuccess = { cameraPermissionGranted = it == PermissionStatus.Granted }, onFailure = { _, _ -> },
            )
            refreshTriggerAvailability()
            render()
        }
        if (::content.isInitialized) render()
    }

    override fun onDestroy() {
        triggers.pause()
        handler.removeCallbacks(countdown)
        stopHeartRateSource()
        voice.release()
        super.onDestroy()
    }

    private fun render() {
        if (demo.phase != lastRenderedPhase) {
            lastRenderedPhase = demo.phase
            revealSession = true
        }
        content.removeAllViews()
        timerText = null
        heartRateValueText = null
        heartRateStateText = null

        content.addView(label("RAY GUARDIAN  /  PROTOTYPE", 12, "#277B69", true).apply {
            letterSpacing = 0.12f
        })
        content.addView(label("A little more\npeace of mind.", 34, "#172B26", true).apply {
            setLineSpacing(dp(1).toFloat(), 1f)
            setPadding(0, dp(8), 0, 0)
        })
        content.addView(label("Explore how a hands-free safety companion could work.", 16, "#5B6D67").apply {
            setPadding(0, dp(10), 0, dp(20))
        })

        val banner = card("#E5F1EB")
        banner.addView(label("DEMO ONLY", 12, "#1C6857", true))
        banner.addView(label("No help is contacted. No background monitoring is active, and heart-rate rules are unvalidated.", 15, "#23463D").apply {
            setPadding(0, dp(6), 0, 0)
        })
        content.addView(banner)

        sectionHeading("01", "Glasses connection", "Connect a device to inspect its reported status.")
        val deviceCard = card("#FFFFFF")
        deviceCard.addView(label(if (mode == IntegrationMode.MOCK) "SIMULATED DEVICE" else "DEVICE STATUS", 11, "#71817A", true))
        deviceCard.addView(label(deviceName, 20, "#172B26", true).apply { setPadding(0, dp(8), 0, dp(3)) })
        deviceCard.addView(label(deviceDetails, 14, "#5B6D67"))
        deviceCard.addView(label("Registration: $registration", 13, "#5B6D67").apply { setPadding(0, dp(8), 0, 0) })
        if (mode != null) {
            deviceCard.addView(label("Device session: $deviceSessionStatus", 13, "#5B6D67").apply { setPadding(0, dp(5), 0, 0) })
        }
        integrationError?.let { error ->
            deviceCard.addView(label(error, 13, "#A84436").apply { setPadding(0, dp(10), 0, 0) })
        }
        if (mode == null) {
            deviceCard.addView(button("Connect Meta glasses", true) { requestRealConnection() })
            if (MockGlassesBridge.available) {
                deviceCard.addView(button("Try simulated glasses", false) { connectMockGlasses() })
            }
        } else if (mode == IntegrationMode.REAL) {
            deviceCard.addView(button("Open Meta AI registration", false) { Wearables.startRegistration(this) })
        }
        if (mode != null && hasActiveDevice && !triggers.controller.armed) {
            if (mode == IntegrationMode.REAL) {
                deviceCard.addView(button("Open live glasses diagnostics", false) {
                    stopWearableSession()
                    startActivity(Intent(this, LiveGlassesActivity::class.java))
                })
            }
            if (wearableSession == null) {
                deviceCard.addView(button("Start device session", false) { startWearableSession() })
            } else {
                deviceCard.addView(button("End device session", false) { stopWearableSession(); render() })
            }
        }
        content.addView(deviceCard)

        sectionHeading("02", "Rehearse an alert", "Practice the flow using only simulated events.")
        val sessionCard = card("#FFFFFF")
        currentSessionCard = sessionCard
        val phaseTitle: String
        val phaseDescription: String
        when (demo.phase) {
            DemoSession.Phase.DISARMED -> {
                phaseTitle = "Ready to practice"
                phaseDescription = "Start a foreground-only rehearsal. It stops when you leave this screen."
            }
            DemoSession.Phase.ARMED -> {
                phaseTitle = "Rehearsal active"
                phaseDescription = "Foreground rehearsal armed. Camera stays off until an enabled trigger and capture consent allow a brief context window."
            }
            DemoSession.Phase.CHECK_IN -> {
                phaseTitle = "Are you okay?"
                phaseDescription = if (demo.trigger == DemoSession.Trigger.HEART_RATE_ANOMALY) {
                    "Your watch reported ${heartRateAnomalySummary ?: "an unusual heart rate"}. Cancel the check-in or wait to see the alert screen."
                } else {
                    "This is a replayed event. Cancel the check-in or wait to see the alert screen."
                }
            }
            DemoSession.Phase.ALERT -> {
                phaseTitle = "Simulated alert created"
                phaseDescription = "No message was sent and no one was contacted. This screen does not represent delivery."
            }
            DemoSession.Phase.ACKNOWLEDGED -> {
                phaseTitle = "Acknowledgment simulated"
                phaseDescription = "A demo contact has been marked as responding. No real person was contacted."
            }
            DemoSession.Phase.CANCELLED -> {
                phaseTitle = "Simulated alert cancelled"
                phaseDescription = "The rehearsal is cancelled. No message was sent."
            }
        }
        sessionCard.addView(label("LOCAL REHEARSAL", 11, "#71817A", true))
        sessionCard.addView(label(phaseTitle, 22, "#172B26", true).apply { setPadding(0, dp(8), 0, dp(5)) })
        sessionCard.addView(label(phaseDescription, 15, "#5B6D67"))
        sessionCard.addView(label("Context: ${triggers.controller.reason}", 13, "#277B69").apply {
            setPadding(0, dp(10), 0, 0)
            accessibilityLiveRegion = android.view.View.ACCESSIBILITY_LIVE_REGION_POLITE
        })
        when (demo.phase) {
            DemoSession.Phase.DISARMED -> sessionCard.addView(button("Start rehearsal", true) {
                demo.arm()
                voice.prefetch()
                stopWearableSession()
                refreshTriggerAvailability()
                triggers.arm()
                render()
            })
            DemoSession.Phase.ARMED -> {
                sessionCard.addView(button("Simulate SOS", true) { triggers.offer(TriggerController.Signal.MANUAL_SOS, mode == IntegrationMode.MOCK) })
                sessionCard.addView(button("Replay a possible incident", false) {
                    triggers.offer(TriggerController.Signal.FALL_CANDIDATE, true)
                })
                sessionCard.addView(button("Stop rehearsal", false) { demo.disarm(); triggers.disarm(); render() })
            }
            DemoSession.Phase.CHECK_IN -> {
                timerText = label("Simulated alert in 15 seconds", 16, "#A84436", true).apply {
                    setPadding(0, dp(14), 0, 0)
                }
                sessionCard.addView(timerText)
                sessionCard.addView(button("I'm okay — cancel", true) {
                    demo.cancel()
                    triggers.cancel()
                    voice.speak(VoicePrompts.Phrase.CHECK_IN_CANCELLED)
                    handler.removeCallbacks(countdown)
                    render()
                })
                sessionCard.addView(button("Simulate SOS now", false) {
                    triggers.offer(TriggerController.Signal.MANUAL_SOS, mode == IntegrationMode.MOCK)
                    handler.removeCallbacks(countdown)
                    render()
                })
            }
            DemoSession.Phase.ALERT, DemoSession.Phase.ACKNOWLEDGED -> {
                val triggerText = when (demo.trigger) {
                    DemoSession.Trigger.MANUAL -> "Trigger: simulated SOS"
                    DemoSession.Trigger.VOICE_SOS -> "Trigger: simulated intentional voice SOS"
                    DemoSession.Trigger.FALL_CANDIDATE -> "Trigger: replayed fall candidate"
                    DemoSession.Trigger.REPLAYED_CANDIDATE -> "Trigger: replayed incident"
                    DemoSession.Trigger.HEART_RATE_ANOMALY -> "Trigger: smartwatch ${heartRateAnomalySummary ?: "heart-rate anomaly"}"
                    DemoSession.Trigger.LIVE_VISION -> "Trigger: live glasses video"
                    DemoSession.Trigger.LOUD_SOUND -> "Trigger: sustained loud sound"
                    null -> "Trigger unavailable"
                }
                sessionCard.addView(label(triggerText, 13, "#71817A").apply { setPadding(0, dp(10), 0, 0) })
                sessionCard.addView(label("Example location: Helsinki, Finland (test data)", 13, "#71817A").apply { setPadding(0, dp(5), 0, 0) })
                sessionCard.addView(label("Demo contact: ${if (demo.phase == DemoSession.Phase.ACKNOWLEDGED) "simulated acknowledgment" else "not contacted"}", 13, "#71817A").apply { setPadding(0, dp(5), 0, 0) })
                if (demo.phase == DemoSession.Phase.ALERT) {
                    sessionCard.addView(button("Simulate acknowledgment", true) { demo.acknowledge(); render() })
                }
                sessionCard.addView(button("Cancel simulated alert", false) { demo.cancel(); triggers.cancel(); render() })
                sessionCard.addView(button("Finish rehearsal", false) { demo.finish(); triggers.disarm(); render() })
                if (BuildConfig.AI_BASE_URL.isNotBlank()) {
                    sessionCard.addView(button("Review context with Nemotron", false) {
                        startActivity(Intent(this, AiActivity::class.java).putExtra(
                            "context_description",
                            "SIMULATED REHEARSAL, not a real emergency. $triggerText. " +
                                (if (demo.trigger == DemoSession.Trigger.HEART_RATE_ANOMALY) {
                                    "A smartwatch reported ${heartRateAnomalySummary ?: "an unusual heart rate"} under an unvalidated rule. " +
                                        "No camera or microphone evidence is attached to this submission. "
                                } else {
                                    "No camera, microphone, or live sensor evidence is attached to this submission. "
                                }) +
                                "No contacts have been notified. Summarize the reported context and its limitations.",
                        ))
                    })
                }
            }
            DemoSession.Phase.CANCELLED -> sessionCard.addView(button("Finish rehearsal", true) { demo.finish(); triggers.disarm(); render() })
        }
        content.addView(sessionCard)

        renderPrivacyCard()
        renderHeartRateCard()

        if (BuildConfig.AI_BASE_URL.isNotBlank()) {
            sectionHeading("05", "AI context with Nemotron", "Analyze text and an optional image when you choose.")
            val aiCard = card("#FFFFFF")
            aiCard.addView(label("Your submitted context can be sent to Nemotron for a summary. AI results do not operate the alert controls.", 14, "#5B6D67"))
            aiCard.addView(button("Open Nemotron context", true) { startActivity(Intent(this, AiActivity::class.java)) })
            content.addView(aiCard)
        }

        content.addView(label("Built for careful testing", 14, "#277B69", true).apply { setPadding(0, dp(24), 0, dp(6)) })
        content.addView(label("Camera context is opt-in and triggered only. Microphone listening, automatic fall sensing, location, background protection and real alert delivery are unavailable. Heart-rate screening is unvalidated.", 13, "#71817A"))
        // Bring check-ins/incident transitions into view without moving the page for each frame/status update.
        if (revealSession) content.doOnNextLayout {
            if (revealSession) {
                revealSession = false
                scroll.scrollTo(0, ((currentSessionCard?.top ?: 0) - topInset - dp(12)).coerceAtLeast(0))
            }
        }
    }

    private fun renderHeartRateCard() {
        sectionHeading("04", "Smartwatch heart rate", "Screen watch readings for a sustained unusual heart rate.")
        val card = card("#FFFFFF")
        val source = heartRateSource
        card.addView(label(if (source is SimulatedWatchSource) "SIMULATED WATCH" else "SMARTWATCH", 11, "#71817A", true))
        card.addView(label(source?.label ?: "No watch connected", 20, "#172B26", true).apply { setPadding(0, dp(8), 0, dp(3)) })
        heartRateValueText = label(heartRateValueLine(), 30, "#172B26", true).apply { setPadding(0, dp(6), 0, 0) }
        heartRateStateText = label(heartRateStateLine(), 14, heartRateStateColor())
        card.addView(heartRateValueText)
        card.addView(heartRateStateText)
        card.addView(label(heartRateStatus, 13, "#71817A").apply { setPadding(0, dp(8), 0, 0) })
        card.addView(label(
            "Readings are checked only while this screen is open. A heart rate above " +
                "${HeartRateAnomalyDetector.Config().highBpm} or below ${HeartRateAnomalyDetector.Config().lowBpm} bpm " +
                "for 30 seconds can start the check-in of an active rehearsal when watch triggers are enabled. This is an unvalidated rule, not a diagnosis.",
            13, "#5B6D67",
        ).apply { setPadding(0, dp(10), 0, 0) })
        if (source == null) {
            card.addView(button("Connect Bluetooth heart-rate watch", true) { requestHeartRateConnection() })
            SimulatedHeartRateTrace.Scenario.entries.forEach { scenario ->
                card.addView(button("Simulate: ${scenario.title}", false) { startHeartRateSource(SimulatedWatchSource(scenario)) })
            }
        } else {
            card.addView(button("Disconnect watch", false) { stopHeartRateSource(); render() })
        }
        content.addView(card)
    }

    private fun heartRateValueLine(): String {
        val bpm = heartRateAssessment.latestBpm ?: return "— bpm"
        return if (heartRateAssessment.state == HeartRateAnomalyDetector.State.SIGNAL_LOST) "— bpm (last $bpm)" else "$bpm bpm"
    }

    private fun heartRateStateLine(): String = when (heartRateAssessment.state) {
        HeartRateAnomalyDetector.State.NO_DATA -> "Waiting for readings"
        HeartRateAnomalyDetector.State.NORMAL -> "Within the configured range"
        HeartRateAnomalyDetector.State.OUT_OF_RANGE ->
            "Unusually ${kindWord(heartRateAssessment.kind)} for ${heartRateAssessment.outOfRangeMillis / 1000} s — watching"
        HeartRateAnomalyDetector.State.ANOMALY -> "Sustained ${kindWord(heartRateAssessment.kind)} heart rate"
        HeartRateAnomalyDetector.State.SIGNAL_LOST -> "No recent reading — coverage reduced, not treated as an emergency"
    }

    private fun heartRateStateColor() = when (heartRateAssessment.state) {
        HeartRateAnomalyDetector.State.ANOMALY, HeartRateAnomalyDetector.State.OUT_OF_RANGE -> "#A84436"
        HeartRateAnomalyDetector.State.SIGNAL_LOST -> "#9A6A12"
        else -> "#5B6D67"
    }

    private fun kindWord(kind: HeartRateAnomalyDetector.Kind?) = when (kind) {
        HeartRateAnomalyDetector.Kind.HIGH -> "high"
        HeartRateAnomalyDetector.Kind.LOW -> "low"
        null -> "unusual"
    }

    private fun onHeartRateAssessment(assessment: HeartRateAnomalyDetector.Assessment) {
        val stateChanged = assessment.state != heartRateAssessment.state || assessment.kind != heartRateAssessment.kind
        heartRateAssessment = assessment
        if (assessment.newAnomaly) {
            heartRateAnomalySummary = "a sustained ${kindWord(assessment.kind)} heart rate (${assessment.latestBpm} bpm)"
            if (demo.phase == DemoSession.Phase.ARMED) {
                triggers.offer(TriggerController.Signal.HEART_RATE, heartRateSource is SimulatedWatchSource || mode == IntegrationMode.MOCK)
            }
            render()
            return
        }
        if (stateChanged) {
            render()
        } else {
            heartRateValueText?.text = heartRateValueLine()
            heartRateStateText?.text = heartRateStateLine()
        }
    }

    private fun requestHeartRateConnection() {
        val needed = arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        if (needed.all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }) {
            startHeartRateSource(BleHeartRateSource(this))
        } else {
            heartRatePermissions.launch(needed)
        }
    }

    private fun startHeartRateSource(source: HeartRateSource) {
        stopHeartRateSource()
        heartRateSource = source
        source.start(heartRateListener)
        handler.postDelayed(heartRateTicker, 1_000L)
        render()
    }

    private fun stopHeartRateSource() {
        handler.removeCallbacks(heartRateTicker)
        heartRateSource?.stop()
        heartRateSource = null
        heartRateDetector.reset()
        heartRateAssessment = HeartRateAnomalyDetector.Assessment(HeartRateAnomalyDetector.State.NO_DATA)
        heartRateStatus = "No watch connected"
    }

    private fun renderPrivacyCard() {
        sectionHeading("03", "Triggered context & privacy", "Choose what can start a brief context window.")
        val panel = card("#FFFFFF")
        val controller = triggers.controller
        val settings = controller.settings
        panel.addView(label(if (controller.armed) "ARMED · FOREGROUND ONLY" else "DISARMED", 12, "#277B69", true))
        panel.addView(label(controller.reason, 15, "#23463D").apply { setPadding(0, dp(8), 0, dp(8)) })
        panel.addView(label("Frames in capture buffer: ${triggers.retainedFrames}. Images are temporary; no media files or audio recordings are made.", 13, "#71817A"))
        fun option(title: String, checked: Boolean, enabled: Boolean = true, action: (Boolean) -> Unit) {
            panel.addView(CheckBox(this).apply {
                text = title
                textSize = 14f
                isChecked = checked
                isEnabled = enabled
                setOnCheckedChangeListener { _, value -> action(value) }
            })
        }
        fun source(title: String, signal: TriggerController.Signal) {
            option(title, signal in settings.enabled) { enabled ->
                triggers.configure(settings.copy(enabled = if (enabled) settings.enabled + signal else settings.enabled - signal))
            }
        }
        source("Use sustained watch candidates", TriggerController.Signal.HEART_RATE)
        source("Enable replayed fall candidates (no motion sensor)", TriggerController.Signal.FALL_CANDIDATE)
        source("Enable simulated SOS phrase (no listening)", TriggerController.Signal.VOICE_SOS)
        source("Enable simulated loud-voice hint (never triggers alone)", TriggerController.Signal.LOUD_VOICE)
        option("Allow up to 8 seconds of camera context after a trigger", settings.cameraContext) { enabled ->
            triggers.configure(settings.copy(cameraContext = enabled, cloudContext = settings.cloudContext && enabled))
        }
        option("I agree to automatically send triggered images to Verda / Nemotron for advisory context", settings.cloudContext,
            settings.cameraContext && BuildConfig.AI_CLIENT_TOKEN.isNotBlank()) { enabled ->
            triggers.configure(settings.copy(cloudContext = enabled))
        }
        panel.addView(label("Camera and cloud sharing default off. Changing settings disarms the rehearsal. Sessions expire after 15 minutes; leaving this screen stops capture and cancels analysis. There is no pre-event video.", 13, "#5B6D67"))
        if (mode == IntegrationMode.REAL && registered) {
            panel.addView(label(if (cameraPermissionGranted) "Glasses camera permission granted" else "Glasses camera permission not granted", 13, "#71817A"))
            panel.addView(button("Allow glasses camera", false) {
                triggers.disarm()
                glassesCameraPermission.launch(Permission.CAMERA)
            })
        }
        if (BuildConfig.DEBUG) {
            panel.addView(label("Replay controls generate synthetic events and synthetic images. They do not access a microphone or prove detection works.", 13, "#71817A"))
            panel.addView(button("Replay SOS phrase", false) { triggers.offer(TriggerController.Signal.VOICE_SOS, true) })
            panel.addView(button("Replay loud voices", false) { triggers.offer(TriggerController.Signal.LOUD_VOICE, true) })
        }
        if (controller.armed) panel.addView(button("Stop context and disarm", false) { triggers.disarm() })
        triggers.assessment?.let { panel.addView(label(it, 14, "#23463D").apply { setPadding(0, dp(12), 0, 0) }) }
        content.addView(panel)
    }

    private fun refreshTriggerAvailability() {
        triggers.availability(TriggerController.Availability(
            connected = hasActiveDevice && registered,
            cameraPermission = mode == IntegrationMode.MOCK || cameraPermissionGranted,
            thermalSafe = mode == IntegrationMode.MOCK || thermalStatus in setOf("none", "light"),
        ))
    }

    private fun requestRealConnection() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) {
            connectRealGlasses()
        } else {
            bluetoothPermission.launch(Manifest.permission.BLUETOOTH_CONNECT)
        }
    }

    private fun connectRealGlasses() {
        if (mode != null) return
        Wearables.initialize(applicationContext).fold(
            onSuccess = {
                mode = IntegrationMode.REAL
                activeIntegrationMode = IntegrationMode.REAL
                integrationError = null
                observeWearables()
                Wearables.startRegistration(this)
                render()
            },
            onFailure = { error, _ ->
                integrationError = "Could not initialize Meta Wearables: ${error.description}"
                render()
            },
        )
    }

    private fun connectMockGlasses() {
        if (mode != null) return
        mode = IntegrationMode.MOCK
        registration = "Starting simulator…"
        integrationError = null
        render()
        lifecycleScope.launch {
            try {
                val error = MockGlassesBridge.start(applicationContext)
                if (error != null) {
                    integrationError = "Could not start the simulated device: $error. Restart the app to retry."
                } else {
                    activeIntegrationMode = IntegrationMode.MOCK
                    observeWearables()
                    android.util.Log.i("RayGuardian", "Meta MockDeviceKit simulator ready")
                }
            } catch (error: Exception) {
                integrationError = "Could not start the simulated device. Restart the app to retry."
            }
            render()
        }
    }

    private fun observeWearables() {
        lifecycleScope.launch {
            Wearables.registrationState.collect { state ->
                registered = state == RegistrationState.REGISTERED
                if (!registered) cameraPermissionGranted = false
                registration = when (state) {
                    RegistrationState.REGISTERED -> if (mode == IntegrationMode.MOCK) "Simulated registration active" else "Connected to Meta AI"
                    RegistrationState.REGISTERING -> "Connecting…"
                    RegistrationState.UNREGISTERING -> "Disconnecting…"
                    else -> "Not registered"
                }
                refreshTriggerAvailability()
                render()
            }
        }
        activeDeviceJob?.cancel()
        activeDeviceJob = lifecycleScope.launch {
            deviceSelector.activeDeviceFlow().collect { device ->
                if (activeDeviceId != device) {
                    // A different device must not inherit an open capture window.
                    triggers.availability(TriggerController.Availability())
                    cameraPermissionGranted = false
                }
                hasActiveDevice = device != null
                activeDeviceId = device
                if (device == null) {
                    metadataJob?.cancel()
                    deviceName = "No glasses connected"
                    deviceDetails = "Device status is unavailable."
                } else {
                    deviceName = "Meta glasses"
                    batteryStatus = "unknown"
                    thermalStatus = "unknown"
                    observeSelectedDevice()
                }
                refreshTriggerAvailability()
                render()
            }
        }
        lifecycleScope.launch {
            Wearables.devices.collect {
                if (activeDeviceId != null) observeSelectedDevice()
            }
        }
    }

    private fun observeSelectedDevice() {
        metadataJob?.cancel()
        val selected = activeDeviceId ?: return
        updateDeviceDetails()
        metadataJob = lifecycleScope.launch {
            Wearables.devicesMetadata[selected]?.collect { device ->
                if (activeDeviceId != selected) return@collect
                deviceName = device.name.ifBlank { "Meta glasses" }
                batteryStatus = device.batteryLevel.takeIf { it in 0..100 }?.let { "$it%" } ?: "unknown"
                thermalStatus = device.thermalLevel.name.lowercase()
                updateDeviceDetails()
                refreshTriggerAvailability()
                render()
            }
        }
    }

    private fun updateDeviceDetails() {
        val connection = if (hasActiveDevice) "Available" else "Not active"
        deviceDetails = "$connection  •  Battery $batteryStatus  •  Thermal $thermalStatus"
    }

    private fun startWearableSession() {
        if (wearableSession != null || !hasActiveDevice) return
        Wearables.createSession(deviceSelector).fold(
            onSuccess = { session ->
                wearableSession = session
                deviceSessionStatus = "Starting"
                lifecycleScope.launch {
                    session.state.collect { state ->
                        // Ignore late updates from an older, stopped session.
                        if (wearableSession !== session) return@collect
                        deviceSessionStatus = state.name.lowercase().replaceFirstChar { it.uppercase() }
                        if (state == DeviceSessionState.STOPPED) wearableSession = null
                        render()
                    }
                }
                lifecycleScope.launch {
                    session.errors.collect { error ->
                        if (wearableSession === session) {
                            integrationError = "Device session: ${error.description}"
                            render()
                        }
                    }
                }
                session.start()
                render()
            },
            onFailure = { error, _ ->
                integrationError = "Could not create a device session: ${error.description}"
                render()
            },
        )
    }

    private fun stopWearableSession() {
        val session = wearableSession ?: return
        wearableSession = null
        deviceSessionStatus = "Stopped"
        session.stop()
    }

    private fun sectionHeading(number: String, title: String, description: String) {
        content.addView(label("$number   $title", 18, "#172B26", true).apply { setPadding(0, dp(25), 0, dp(4)) })
        content.addView(label(description, 14, "#71817A").apply { setPadding(0, 0, 0, dp(12)) })
    }

    private fun card(background: String): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(20), dp(20), dp(20))
        this.background = rounded(background, 22)
        layoutParams = LinearLayout.LayoutParams(-1, -2)
    }

    private fun label(text: String, size: Int, foreground: String, bold: Boolean = false): TextView = TextView(this).apply {
        this.text = text
        textSize = size.toFloat()
        setTextColor(color(foreground))
        if (bold) setTypeface(typeface, Typeface.BOLD)
        setLineSpacing(dp(2).toFloat(), 1f)
    }

    private fun button(text: String, primary: Boolean, action: () -> Unit): Button = Button(this).apply {
        this.text = text
        isAllCaps = false
        textSize = 15f
        minHeight = dp(52)
        setTextColor(color(if (primary) "#FFFFFF" else "#277B69"))
        background = rounded(if (primary) "#277B69" else "#EDF5F0", 14)
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12) }
        setOnClickListener { action() }
    }

    private fun rounded(fill: String, radius: Int) = GradientDrawable().apply {
        setColor(color(fill))
        cornerRadius = dp(radius).toFloat()
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun color(value: String) = Color.parseColor(value)
}
