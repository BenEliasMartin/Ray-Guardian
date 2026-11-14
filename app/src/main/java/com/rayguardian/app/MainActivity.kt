package com.rayguardian.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.view.View
import android.view.WindowInsets
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
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
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.core.types.RegistrationState
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val demo = DemoSession()
    private val liveSession = DemoSession()
    private val aiClient = AiClient()
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
    private var sessionStarted = false
    private val deviceSelector by lazy { AutoDeviceSelector() }
    private var deviceSessionStatus = "Not started"
    private var batteryStatus = "unknown"
    private var thermalStatus = "unknown"
    private var cameraPermissionGranted = false
    private var registered = false

    private val triggers: TriggerRuntime by lazy {
        TriggerRuntime(
            lifecycleScope,
            captureBudget,
            onIncident = { signal ->
                when (signal) {
                    TriggerController.Signal.MANUAL_SOS -> demo.manualSos()
                    TriggerController.Signal.VOICE_SOS -> demo.manualSos(DemoSession.Trigger.VOICE_SOS)
                    TriggerController.Signal.FALL_CANDIDATE -> demo.replayCandidate(SystemClock.elapsedRealtime(), DemoSession.Trigger.FALL_CANDIDATE)
                    TriggerController.Signal.HEART_RATE -> demo.replayCandidate(SystemClock.elapsedRealtime(), DemoSession.Trigger.HEART_RATE_ANOMALY)
                    TriggerController.Signal.LOUD_VOICE -> Unit
                }
                if (::voice.isInitialized) {
                    if (demo.phase == DemoSession.Phase.CHECK_IN) {
                        voice.speak(
                            if (signal == TriggerController.Signal.HEART_RATE) {
                                VoicePrompts.Phrase.CHECK_IN_HEART_RATE
                            } else {
                                VoicePrompts.Phrase.CHECK_IN
                            },
                        )
                    } else if (demo.phase == DemoSession.Phase.ALERT) {
                        voice.speak(VoicePrompts.Phrase.ALERT_CREATED)
                    }
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

    private lateinit var cameraMonitor: GlassesCameraMonitor
    private var cameraStatus = "Camera idle (standby)"
    private var autoScanCamera = false

    private var liveIncidentId: String = UUID.randomUUID().toString()
    private var liveStatusNote = "Ready to detect falls, open fires, and safety hazards."
    private var liveAnalyzing = false
    private var liveAnalysisJob: Job? = null
    private var latestAssessment: HazardAssessment? = null
    private var latestReceipt: DispatchReceipt? = null
    private var latestCallOutcome: String? = null
    private var showPhoneSettings = false
    private var launchingPhoneCall = false
    private var currentLocationLabel = DEFAULT_LOCATION

    private var timerText: TextView? = null
    private var liveTimerText: TextView? = null
    private lateinit var voice: VoicePrompts
    private lateinit var phoneStore: ServicePhoneStore

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
        private const val DEFAULT_LOCATION = "Helsinki demo point · 60.1699, 24.9384"
        private const val AUTO_SCAN_INTERVAL_MILLIS = 12_000L
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

    private val metaCameraPermission =
        registerForActivityResult(Wearables.RequestPermissionContract()) { result ->
            result.fold(
                onSuccess = { status ->
                    cameraPermissionGranted = status is PermissionStatus.Granted
                    refreshTriggerAvailability()
                    if (cameraPermissionGranted) {
                        wearableSession?.let { cameraMonitor.start(it) }
                    } else {
                        cameraStatus = "Meta glasses camera permission was not granted."
                        render()
                    }
                },
                onFailure = { error, _ ->
                    cameraPermissionGranted = false
                    refreshTriggerAvailability()
                    cameraStatus = "Camera permission check failed: ${error.description}"
                    render()
                },
            )
        }

    private val callPhonePermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            liveStatusNote = if (granted) {
                "Direct emergency dialing enabled (CALL_PHONE granted)."
            } else {
                "CALL_PHONE denied — dispatch will open the phone dialer with the number ready."
            }
            render()
        }

    private val locationPermissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
            if (results.values.any { it }) refreshPhoneLocation()
            else {
                liveStatusNote = "Location permission not granted; using fallback coordinates."
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

    private val heartRateTicker = object : Runnable {
        override fun run() {
            if (heartRateSource == null) return
            onHeartRateAssessment(heartRateDetector.assess(SystemClock.elapsedRealtime()))
            handler.postDelayed(this, 1_000L)
        }
    }

    private val autoCameraScanner = object : Runnable {
        override fun run() {
            if (!autoScanCamera || !cameraMonitor.isStreaming) return
            if (!liveAnalyzing && liveSession.phase in setOf(DemoSession.Phase.DISARMED, DemoSession.Phase.ARMED)) {
                scanLiveGlassesFeed()
            }
            handler.postDelayed(this, AUTO_SCAN_INTERVAL_MILLIS)
        }
    }

    private val liveCountdown = object : Runnable {
        override fun run() {
            if (liveSession.phase != DemoSession.Phase.CHECK_IN) return
            val now = SystemClock.elapsedRealtime()
            liveSession.tick(now)
            if (liveSession.phase == DemoSession.Phase.ALERT) {
                executeLiveHelpCall()
            } else if (liveSession.phase == DemoSession.Phase.CHECK_IN) {
                val seconds = ((liveSession.deadlineMillis!! - now + 999) / 1000).coerceAtLeast(0)
                liveTimerText?.text = "Calling ${liveSession.targetService.shortTitle} in $seconds s…"
                handler.postDelayed(this, 200)
            }
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
        phoneStore = ServicePhoneStore(this)
        cameraMonitor = GlassesCameraMonitor(lifecycleScope) { status ->
            cameraStatus = status
            render()
        }
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
        if (mode == IntegrationMode.REAL) {
            runCatching { Wearables.handleIntent(intent) {} }
        }
        if (mode != null) observeWearables()
        voice.prefetch()
        render()
        if (BuildConfig.DEBUG && intent.getBooleanExtra("ray_guardian_simulator", false) && mode == null) {
            connectMockGlasses()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (mode == IntegrationMode.REAL) {
            runCatching { Wearables.handleIntent(intent) {} }
        }
    }

    override fun onPause() {
        triggers.pause()
        // The rehearsal is foreground-only. It must never imply background coverage.
        if (demo.phase == DemoSession.Phase.ARMED || demo.phase == DemoSession.Phase.CHECK_IN) {
            demo.disarm()
            handler.removeCallbacks(countdown)
        }
        if (!launchingPhoneCall) {
            if (liveSession.phase == DemoSession.Phase.ARMED || liveSession.phase == DemoSession.Phase.CHECK_IN) {
                liveSession.disarm()
                handler.removeCallbacks(liveCountdown)
            }
            autoScanCamera = false
            handler.removeCallbacks(autoCameraScanner)
            voice.stop()
            stopWearableSession()
            stopHeartRateSource()
        }
        launchingPhoneCall = false
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        triggers.resume()
        refreshTriggerAvailability()
        if (mode == IntegrationMode.REAL) {
            lifecycleScope.launch {
                cameraPermissionGranted = false
                Wearables.checkPermissionStatus(Permission.CAMERA).fold(
                    onSuccess = { cameraPermissionGranted = it == PermissionStatus.Granted },
                    onFailure = { _, _ -> },
                )
                refreshTriggerAvailability()
                render()
            }
        }
        if (::content.isInitialized) render()
    }

    override fun onDestroy() {
        triggers.pause()
        handler.removeCallbacks(countdown)
        handler.removeCallbacks(liveCountdown)
        handler.removeCallbacks(autoCameraScanner)
        liveAnalysisJob?.cancel()
        aiClient.cancel()
        cameraMonitor.stop()
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
        liveTimerText = null
        heartRateValueText = null
        heartRateStateText = null

        content.addView(label("RAY GUARDIAN  /  META GLASSES SAFETY", 12, "#277B69", true).apply {
            letterSpacing = 0.12f
        })
        content.addView(label("A little more\npeace of mind.", 34, "#172B26", true).apply {
            setLineSpacing(dp(1).toFloat(), 1f)
            setPadding(0, dp(8), 0, 0)
        })
        content.addView(label("Detect falls, open fires, and health hazards from Meta glasses — speak via ElevenLabs and call the matching help service.", 15, "#5B6D67").apply {
            setPadding(0, dp(10), 0, dp(18))
        })

        val banner = card("#E5F1EB")
        banner.addView(label("DEMO ONLY  •  PUBLIC 112/911 BLOCKED", 12, "#1C6857", true))
        banner.addView(label("Routes hazards to Ambulance, Fire & Rescue, or Police using your configured test phone numbers and ElevenLabs voice.", 14, "#23463D").apply {
            setPadding(0, dp(6), 0, 0)
        })
        content.addView(banner)

        renderGlassesCard()
        renderHazardPipelineCard()
        renderRehearsalCard()
        renderPrivacyCard()
        renderHeartRateCard()

        if (BuildConfig.AI_BASE_URL.isNotBlank()) {
            sectionHeading("06", "AI context with Nemotron", "Inspect custom text and an image manually.")
            val aiCard = card("#FFFFFF")
            aiCard.addView(label("Submit a custom description or photo directly to Nemotron for structured observations and uncertainties.", 14, "#5B6D67"))
            aiCard.addView(button("Open Nemotron context", true) { startActivity(Intent(this, AiActivity::class.java)) })
            content.addView(aiCard)
        }

        content.addView(label("Built for careful testing", 14, "#277B69", true).apply { setPadding(0, dp(24), 0, dp(6)) })
        content.addView(label("Camera context is opt-in and foreground-bounded. Public 112/911 shortcodes are blocked; heart-rate screening is unvalidated.", 13, "#71817A"))

        if (revealSession) {
            content.doOnNextLayout {
                if (revealSession) {
                    revealSession = false
                    scroll.scrollTo(0, ((currentSessionCard?.top ?: 0) - topInset - dp(12)).coerceAtLeast(0))
                }
            }
        }
    }

    private fun renderGlassesCard() {
        sectionHeading("01", "Glasses connection & POV camera", "Connect Meta glasses or MockDeviceKit and attach the DAT camera stream.")
        val deviceCard = card("#FFFFFF")
        deviceCard.addView(label(if (mode == IntegrationMode.MOCK) "SIMULATED DEVICE" else "DEVICE STATUS", 11, "#71817A", true))
        deviceCard.addView(label(deviceName, 20, "#172B26", true).apply { setPadding(0, dp(8), 0, dp(3)) })
        deviceCard.addView(label(deviceDetails, 14, "#5B6D67"))
        deviceCard.addView(label("Registration: $registration", 13, "#5B6D67").apply { setPadding(0, dp(8), 0, 0) })
        if (mode != null) {
            deviceCard.addView(label("Device session: $deviceSessionStatus", 13, "#5B6D67").apply { setPadding(0, dp(4), 0, 0) })
            deviceCard.addView(label("Glasses camera: $cameraStatus", 13, "#5B6D67").apply { setPadding(0, dp(4), 0, 0) })
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
                if (sessionStarted) {
                    if (!cameraMonitor.isStreaming) {
                        deviceCard.addView(button("Start glasses POV camera stream", true) { startGlassesCamera() })
                    } else {
                        val autoToggleLabel = if (autoScanCamera) "Stop auto-scanning live POV" else "Auto-scan live POV every 12s"
                        deviceCard.addView(button(autoToggleLabel, false) { toggleAutoScanCamera() })
                        deviceCard.addView(button("Stop glasses camera stream", false) {
                            autoScanCamera = false
                            handler.removeCallbacks(autoCameraScanner)
                            cameraMonitor.stop()
                            cameraStatus = "Camera stopped"
                            render()
                        })
                    }
                }
                deviceCard.addView(button("End device session", false) { stopWearableSession(); render() })
            }
        }
        content.addView(deviceCard)
    }

    private fun renderHazardPipelineCard() {
        sectionHeading("02", "Hazard detection & help calls", "Detect falls or fires, warn via ElevenLabs, and call the matching help service.")
        val cardBg = when {
            liveSession.phase == DemoSession.Phase.CHECK_IN && liveSession.hazardType == HazardType.FIRE -> "#FFF1EC"
            liveSession.phase == DemoSession.Phase.CHECK_IN -> "#FFF8EA"
            liveSession.phase == DemoSession.Phase.ALERT -> "#EDF7F2"
            else -> "#FFFFFF"
        }
        val pipelineCard = card(cardBg)
        val badgeText = when (liveSession.phase) {
            DemoSession.Phase.CHECK_IN -> "${liveSession.hazardType.label.uppercase()}  •  CHECK-IN"
            DemoSession.Phase.ALERT, DemoSession.Phase.ACKNOWLEDGED -> "${liveSession.targetService.shortTitle.uppercase()}  •  DISPATCHED"
            DemoSession.Phase.CANCELLED -> "EMERGENCY CALL CANCELLED"
            else -> if (liveAnalyzing) "NEMOTRON ANALYZING POV…" else "ACTIVE HAZARD PIPELINE"
        }
        pipelineCard.addView(label(badgeText, 11, "#1C6857", true))

        when (liveSession.phase) {
            DemoSession.Phase.DISARMED, DemoSession.Phase.ARMED -> {
                pipelineCard.addView(label(
                    if (liveAnalyzing) "Inspecting smart-glasses frames…" else "Ready for live hazard detection",
                    21,
                    "#172B26",
                    true,
                ).apply { setPadding(0, dp(8), 0, dp(4)) })
                pipelineCard.addView(label(liveStatusNote, 14, "#5B6D67"))
                pipelineCard.addView(label("Active location: $currentLocationLabel", 13, "#71817A").apply {
                    setPadding(0, dp(6), 0, 0)
                })
                latestAssessment?.let { assessment ->
                    pipelineCard.addView(label(
                        "Last Nemotron result (${assessment.hazardType.label}): ${assessment.summary}",
                        13,
                        "#23463D",
                    ).apply { setPadding(0, dp(8), 0, 0) })
                }

                if (cameraMonitor.isStreaming) {
                    pipelineCard.addView(button("Scan live glasses camera now", true) { scanLiveGlassesFeed() }.apply {
                        isEnabled = !liveAnalyzing
                    })
                }
                pipelineCard.addView(button("Detect POV: Elderly person falling (→ Ambulance)", true) {
                    runSyntheticPovHazardScan(SyntheticPovFrames.Scene.ELDERLY_FALL)
                }.apply { isEnabled = !liveAnalyzing })
                pipelineCard.addView(button("Detect POV: Large open fire (→ Fire & Rescue)", true) {
                    runSyntheticPovHazardScan(SyntheticPovFrames.Scene.OPEN_FIRE)
                }.apply { isEnabled = !liveAnalyzing })

                pipelineCard.addView(label("Direct help service SOS:", 12, "#71817A", true).apply {
                    setPadding(0, dp(14), 0, 0)
                })
                pipelineCard.addView(button("Call Ambulance Services now", false) {
                    triggerImmediateServiceCall(HelpService.AMBULANCE, HazardType.MEDICAL)
                })
                pipelineCard.addView(button("Call Fire & Rescue now", false) {
                    triggerImmediateServiceCall(HelpService.FIRE_DEPARTMENT, HazardType.FIRE)
                })
                pipelineCard.addView(button("Call Police Dispatch now", false) {
                    triggerImmediateServiceCall(HelpService.POLICE, HazardType.POLICE)
                })
                pipelineCard.addView(button(
                    if (showPhoneSettings) "Hide service phone & GPS settings" else "Configure service phone numbers & GPS",
                    false,
                ) {
                    showPhoneSettings = !showPhoneSettings
                    render()
                })
                if (showPhoneSettings) renderPhoneSettingsSection(pipelineCard)
            }

            DemoSession.Phase.CHECK_IN -> {
                val title = when (liveSession.hazardType) {
                    HazardType.FIRE -> "Large fire detected — Evacuate!"
                    HazardType.POLICE -> "Safety threat detected!"
                    else -> "Medical / fall hazard — Are you OK?"
                }
                pipelineCard.addView(label(title, 22, "#172B26", true).apply { setPadding(0, dp(8), 0, dp(4)) })
                pipelineCard.addView(label(
                    latestAssessment?.summary
                        ?: "Automatic help call to ${liveSession.targetService.title} will start unless cancelled.",
                    15,
                    "#23463D",
                ))
                liveTimerText = label("Calling ${liveSession.targetService.shortTitle} shortly…", 17, "#A84436", true).apply {
                    setPadding(0, dp(12), 0, 0)
                }
                pipelineCard.addView(liveTimerText)
                pipelineCard.addView(button("I'm OK — Cancel help call", true) {
                    liveSession.cancel()
                    handler.removeCallbacks(liveCountdown)
                    voice.speak(VoicePrompts.Phrase.EMERGENCY_CANCELLED)
                    liveStatusNote = "Check-in cancelled by wearer. Standing by."
                    render()
                })
                pipelineCard.addView(button("Call ${liveSession.targetService.shortTitle} immediately", false) {
                    handler.removeCallbacks(liveCountdown)
                    liveSession.escalateImmediately(liveSession.targetService)
                    executeLiveHelpCall()
                })
            }

            DemoSession.Phase.ALERT, DemoSession.Phase.ACKNOWLEDGED -> {
                val receipt = latestReceipt
                pipelineCard.addView(label(
                    "${(receipt?.shortServiceLabel ?: liveSession.targetService.shortTitle)} contacted",
                    22,
                    "#172B26",
                    true,
                ).apply { setPadding(0, dp(8), 0, dp(4)) })
                pipelineCard.addView(label("Call ID: ${receipt?.callId ?: "Pending…"}", 14, "#23463D", true))
                pipelineCard.addView(label("Service: ${receipt?.serviceLabel ?: liveSession.targetService.title}", 13, "#5B6D67").apply {
                    setPadding(0, dp(4), 0, 0)
                })
                pipelineCard.addView(label("Location: ${receipt?.location ?: currentLocationLabel}", 13, "#5B6D67").apply {
                    setPadding(0, dp(4), 0, 0)
                })
                latestCallOutcome?.let { callStatus ->
                    pipelineCard.addView(label("Phone call: $callStatus", 13, "#1C6857", true).apply {
                        setPadding(0, dp(6), 0, 0)
                    })
                }
                latestAssessment?.summary?.let { aiSummary ->
                    pipelineCard.addView(label("Nemotron report: $aiSummary", 13, "#5B6D67").apply {
                        setPadding(0, dp(6), 0, 0)
                    })
                }
                receipt?.briefingScript?.let { script ->
                    pipelineCard.addView(label("ElevenLabs call script:\n\"$script\"", 13, "#23463D").apply {
                        setPadding(0, dp(10), 0, 0)
                    })
                }
                if (receipt != null) {
                    pipelineCard.addView(button("Replay ElevenLabs voice briefing", true) {
                        voice.speakBriefing(receipt, latestAssessment?.summary, heartRateAssessment.latestBpm)
                    })
                }
                val servicePhone = phoneStore.getNumber(liveSession.targetService)
                if (servicePhone.isNotBlank()) {
                    pipelineCard.addView(button("Dial ${liveSession.targetService.shortTitle} ($servicePhone)", false) {
                        launchingPhoneCall = true
                        val outcome = AndroidEmergencyCaller.placeCall(this, servicePhone)
                        latestCallOutcome = outcome.summary
                        if (outcome !is EmergencyDialer.CallOutcome.PlacedDirectCall &&
                            outcome !is EmergencyDialer.CallOutcome.OpenedDialer
                        ) {
                            launchingPhoneCall = false
                        }
                        render()
                    })
                }
                pipelineCard.addView(button("End incident & reset", false) {
                    liveSession.finish()
                    latestReceipt = null
                    latestCallOutcome = null
                    voice.stop()
                    liveStatusNote = "Ready to detect falls, open fires, and safety hazards."
                    render()
                })
            }

            DemoSession.Phase.CANCELLED -> {
                pipelineCard.addView(label("Help call cancelled", 20, "#172B26", true).apply { setPadding(0, dp(8), 0, dp(4)) })
                pipelineCard.addView(label("The incident was cancelled cleanly.", 14, "#5B6D67"))
                pipelineCard.addView(button("Return to monitoring", true) {
                    liveSession.finish()
                    render()
                })
            }
        }

        content.addView(pipelineCard)
    }

    private fun renderPhoneSettingsSection(parent: LinearLayout) {
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(14), dp(14), dp(14))
            background = rounded("#F3F7F5", 14)
            layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(12) }
        }
        box.addView(label("HELP SERVICE TEST NUMBERS", 11, "#1C6857", true))
        box.addView(label(
            "Enter dedicated test phone numbers for each service. Public shortcodes (112, 911, 999) are blocked for safety.",
            12,
            "#5B6D67",
        ).apply { setPadding(0, dp(4), 0, dp(8)) })

        val inputs = mutableMapOf<HelpService, EditText>()
        HelpService.entries.forEach { service ->
            box.addView(label(service.shortTitle, 13, "#172B26", true).apply { setPadding(0, dp(6), 0, dp(2)) })
            val input = EditText(this).apply {
                hint = "e.g. +358401234567 (leave empty for voice-only)"
                inputType = InputType.TYPE_CLASS_PHONE
                setText(phoneStore.getNumber(service))
                textSize = 14f
            }
            inputs[service] = input
            box.addView(input)
        }

        val autoDialCheck = CheckBox(this).apply {
            text = "Automatically dial the matching service phone number when an alert dispatches"
            isChecked = phoneStore.autoDialEnabled
            textSize = 13f
            setPadding(0, dp(8), 0, dp(4))
        }
        box.addView(autoDialCheck)

        box.addView(button("Save service phone settings", true) {
            var blockedService: HelpService? = null
            inputs.forEach { (service, field) ->
                val raw = field.text.toString().trim()
                if (EmergencyDialer.validateNumber(raw) is EmergencyDialer.Validation.BlockedEmergencyShortcode) {
                    blockedService = service
                } else {
                    phoneStore.setNumber(service, raw)
                }
            }
            phoneStore.autoDialEnabled = autoDialCheck.isChecked
            liveStatusNote = if (blockedService != null) {
                "Blocked 112/911 shortcode for ${blockedService!!.shortTitle}. Enter a regular test phone number."
            } else {
                "Saved help service numbers and auto-dial preference."
            }
            render()
        })

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED) {
            box.addView(button("Grant direct CALL_PHONE permission", false) {
                callPhonePermission.launch(Manifest.permission.CALL_PHONE)
            })
        }
        box.addView(button("Update location from phone GPS", false) { requestPhoneLocation() })
        parent.addView(box)
    }

    private fun renderRehearsalCard() {
        sectionHeading("03", "Rehearse an alert", "Practice the flow using only simulated events.")
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
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
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
                sessionCard.addView(button("Simulate SOS", true) {
                    triggers.offer(TriggerController.Signal.MANUAL_SOS, mode == IntegrationMode.MOCK)
                })
                sessionCard.addView(button("Replay a possible incident", false) {
                    triggers.offer(TriggerController.Signal.FALL_CANDIDATE, true)
                })
                sessionCard.addView(button("Stop rehearsal", false) {
                    demo.disarm()
                    triggers.disarm()
                    render()
                })
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
                    DemoSession.Trigger.ELDERLY_FALL -> "Trigger: elderly fall"
                    DemoSession.Trigger.OPEN_FIRE -> "Trigger: open fire"
                    DemoSession.Trigger.SAFETY_THREAT -> "Trigger: safety threat"
                    DemoSession.Trigger.TREMBLING -> "Trigger: severe trembling"
                    DemoSession.Trigger.CRASH -> "Trigger: high-impact crash"
                    DemoSession.Trigger.GLASSES_AI_HAZARD -> "Trigger: glasses AI hazard"
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
            DemoSession.Phase.CANCELLED -> sessionCard.addView(button("Finish rehearsal", true) {
                demo.finish()
                triggers.disarm()
                render()
            })
        }
        content.addView(sessionCard)
    }

    private fun renderPrivacyCard() {
        sectionHeading("04", "Triggered context & privacy", "Choose what can start a brief context window.")
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
        option(
            "I agree to automatically send triggered images to Verda / Nemotron for advisory context",
            settings.cloudContext,
            settings.cameraContext && BuildConfig.AI_CLIENT_TOKEN.isNotBlank(),
        ) { enabled ->
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

    private fun renderHeartRateCard() {
        sectionHeading("05", "Smartwatch heart rate", "Screen watch readings and escalate sustained anomalies to Ambulance check-in.")
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
            "A sustained heart rate above ${HeartRateAnomalyDetector.Config().highBpm} or below " +
                "${HeartRateAnomalyDetector.Config().lowBpm} bpm for 30 seconds opens an Ambulance check-in.",
            13,
            "#5B6D67",
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

    private fun refreshTriggerAvailability() {
        triggers.availability(TriggerController.Availability(
            connected = hasActiveDevice && registered,
            cameraPermission = mode == IntegrationMode.MOCK || cameraPermissionGranted,
            thermalSafe = mode == IntegrationMode.MOCK || thermalStatus in setOf("none", "light"),
        ))
    }

    private fun scanLiveGlassesFeed() {
        if (liveAnalyzing) return
        liveAnalyzing = true
        liveStatusNote = "Capturing ordered frames from Meta glasses camera stream…"
        render()
        liveAnalysisJob?.cancel()
        liveAnalysisJob = lifecycleScope.launch {
            try {
                val frames = cameraMonitor.captureOrGetFrames()
                if (frames.isEmpty()) {
                    liveStatusNote = "Waiting for glasses camera frames. Keep the stream active for a moment and retry."
                    return@launch
                }
                runHazardAnalysis(
                    description = "Live Meta smart-glasses first-person POV frames (${frames.size} ordered snapshot(s)). Classify any fall/medical collapse, large open fire, or acute safety threat.",
                    frames = frames,
                    fallbackHazard = null,
                    sourceTrigger = DemoSession.Trigger.GLASSES_AI_HAZARD,
                )
            } finally {
                liveAnalyzing = false
                render()
            }
        }
    }

    private fun runSyntheticPovHazardScan(scene: SyntheticPovFrames.Scene) {
        if (liveAnalyzing) return
        liveAnalyzing = true
        liveStatusNote = "Rendering ${scene.title} smart-glasses POV frames for Nemotron…"
        render()
        liveAnalysisJob?.cancel()
        liveAnalysisJob = lifecycleScope.launch {
            try {
                val frames = withContext(Dispatchers.Default) {
                    SyntheticPovFrames.generateOrderedFrames(scene)
                }
                val fallback = when (scene) {
                    SyntheticPovFrames.Scene.ELDERLY_FALL -> HazardType.MEDICAL
                    SyntheticPovFrames.Scene.OPEN_FIRE -> HazardType.FIRE
                }
                val trigger = when (scene) {
                    SyntheticPovFrames.Scene.ELDERLY_FALL -> DemoSession.Trigger.ELDERLY_FALL
                    SyntheticPovFrames.Scene.OPEN_FIRE -> DemoSession.Trigger.OPEN_FIRE
                }
                runHazardAnalysis(
                    description = "${scene.description} Classify any person falling/collapsed on the floor, large open fire, or safety hazard.",
                    frames = frames,
                    fallbackHazard = fallback,
                    sourceTrigger = trigger,
                )
            } finally {
                liveAnalyzing = false
                render()
            }
        }
    }

    private suspend fun runHazardAnalysis(
        description: String,
        frames: List<String>,
        fallbackHazard: HazardType?,
        sourceTrigger: DemoSession.Trigger,
    ) {
        try {
            val assessment = aiClient.analyzeHazards(description, frames)
            latestAssessment = assessment
            if (assessment.hazardDetected && assessment.hazardType != HazardType.NONE) {
                startLiveHazardCheckIn(
                    hazardType = assessment.hazardType,
                    service = assessment.recommendedService ?: assessment.hazardType.defaultService(),
                    sourceTrigger = sourceTrigger,
                    urgentImmediate = assessment.urgentImmediate,
                )
            } else {
                liveStatusNote = "Nemotron found no active emergency hazard in the scanned POV."
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            if (fallbackHazard != null) {
                latestAssessment = HazardAssessment(
                    summary = "${fallbackHazard.label} triggered via offline fail-safe (${error.message ?: "AI offline"}).",
                    observations = emptyList(),
                    uncertainties = listOf("Cloud AI was unreachable; used local hazard fail-safe."),
                    hazardDetected = true,
                    hazardType = fallbackHazard,
                    severity = "critical",
                    recommendedService = fallbackHazard.defaultService(),
                    urgentImmediate = fallbackHazard == HazardType.FIRE,
                )
                startLiveHazardCheckIn(
                    hazardType = fallbackHazard,
                    service = fallbackHazard.defaultService(),
                    sourceTrigger = sourceTrigger,
                    urgentImmediate = fallbackHazard == HazardType.FIRE,
                )
            } else {
                liveStatusNote = error.message ?: "Could not reach Nemotron backend."
            }
        }
    }

    private fun startLiveHazardCheckIn(
        hazardType: HazardType,
        service: HelpService,
        sourceTrigger: DemoSession.Trigger,
        urgentImmediate: Boolean,
    ) {
        liveIncidentId = UUID.randomUUID().toString()
        latestReceipt = null
        latestCallOutcome = null
        liveSession.triggerDetectedHazard(
            nowMillis = SystemClock.elapsedRealtime(),
            detectedHazard = hazardType,
            source = sourceTrigger,
            recommendedService = service,
            urgentImmediate = urgentImmediate,
        )
        voice.speak(VoicePrompts.Phrase.forHazardCheckIn(hazardType, sourceTrigger))
        handler.removeCallbacks(liveCountdown)
        handler.post(liveCountdown)
        render()
    }

    private fun triggerImmediateServiceCall(service: HelpService, hazardType: HazardType) {
        handler.removeCallbacks(liveCountdown)
        liveIncidentId = UUID.randomUUID().toString()
        latestReceipt = null
        latestCallOutcome = null
        liveSession.triggerDetectedHazard(
            nowMillis = SystemClock.elapsedRealtime(),
            detectedHazard = hazardType,
            source = when (hazardType) {
                HazardType.FIRE -> DemoSession.Trigger.OPEN_FIRE
                HazardType.POLICE -> DemoSession.Trigger.SAFETY_THREAT
                else -> DemoSession.Trigger.ELDERLY_FALL
            },
            recommendedService = service,
            urgentImmediate = true,
        )
        liveSession.escalateImmediately(service)
        executeLiveHelpCall()
    }

    private fun executeLiveHelpCall() {
        val service = liveSession.targetService
        val hazard = liveSession.hazardType.takeIf { it != HazardType.NONE } ?: HazardType.fromService(service)
        val triggerWire = liveSession.trigger?.wireName ?: "manual-sos"
        val incidentId = liveIncidentId
        val configuredNumber = phoneStore.getNumber(service)
        val contextSummary = latestAssessment?.summary ?: heartRateAnomalySummary
        val latestBpm = heartRateAssessment.latestBpm

        render()
        lifecycleScope.launch {
            val receipt = aiClient.dispatchIncident(
                id = incidentId,
                trigger = triggerWire,
                hazardType = hazard,
                service = service,
                location = currentLocationLabel,
                contextSummary = contextSummary,
                heartRateBpm = if (liveSession.trigger == DemoSession.Trigger.HEART_RATE_ANOMALY) latestBpm else null,
                dialNumber = configuredNumber.ifBlank { null },
            )
            latestReceipt = receipt
            voice.speakBriefing(receipt, contextSummary, latestBpm)

            if (phoneStore.autoDialEnabled && configuredNumber.isNotBlank()) {
                launchingPhoneCall = true
                val outcome = AndroidEmergencyCaller.placeCall(this@MainActivity, configuredNumber)
                latestCallOutcome = outcome.summary
                if (outcome !is EmergencyDialer.CallOutcome.PlacedDirectCall &&
                    outcome !is EmergencyDialer.CallOutcome.OpenedDialer
                ) {
                    launchingPhoneCall = false
                }
            } else {
                latestCallOutcome = EmergencyDialer.CallOutcome.NoNumberConfigured.summary
            }
            render()
        }
    }

    private fun requestPhoneLocation() {
        val perms = arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (perms.any { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }) {
            refreshPhoneLocation()
        } else {
            locationPermissions.launch(perms)
        }
    }

    @SuppressLint("MissingPermission")
    private fun refreshPhoneLocation() {
        val manager = getSystemService(LocationManager::class.java)
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)
        val best = providers.mapNotNull { provider ->
            runCatching { manager?.getLastKnownLocation(provider) }.getOrNull()
        }.maxByOrNull { it.time }

        if (best != null) {
            val coords = String.format(Locale.US, "%.5f, %.5f (±%.0fm)", best.latitude, best.longitude, best.accuracy)
            currentLocationLabel = "Phone GPS · $coords"
            liveStatusNote = "Updated emergency dispatch coordinates from phone GPS."
        } else {
            liveStatusNote = "No recent GPS fix on this device; keeping $DEFAULT_LOCATION."
        }
        render()
    }

    private fun startGlassesCamera() {
        val session = wearableSession ?: return
        if (!sessionStarted) return
        if (mode == IntegrationMode.MOCK) {
            cameraMonitor.start(session)
            return
        }
        lifecycleScope.launch {
            Wearables.checkPermissionStatus(Permission.CAMERA).fold(
                onSuccess = { status ->
                    cameraPermissionGranted = status is PermissionStatus.Granted
                    refreshTriggerAvailability()
                    if (cameraPermissionGranted) {
                        cameraMonitor.start(session)
                    } else {
                        metaCameraPermission.launch(Permission.CAMERA)
                    }
                },
                onFailure = { _, _ ->
                    metaCameraPermission.launch(Permission.CAMERA)
                },
            )
        }
    }

    private fun toggleAutoScanCamera() {
        autoScanCamera = !autoScanCamera
        handler.removeCallbacks(autoCameraScanner)
        if (autoScanCamera && cameraMonitor.isStreaming) {
            handler.postDelayed(autoCameraScanner, 1_500L)
        }
        render()
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
                if (triggers.controller.armed) {
                    triggers.offer(
                        TriggerController.Signal.HEART_RATE,
                        heartRateSource is SimulatedWatchSource || mode == IntegrationMode.MOCK,
                    )
                } else {
                    demo.replayCandidate(SystemClock.elapsedRealtime(), DemoSession.Trigger.HEART_RATE_ANOMALY)
                    voice.speak(VoicePrompts.Phrase.CHECK_IN_HEART_RATE)
                    handler.removeCallbacks(countdown)
                    handler.post(countdown)
                }
            } else if (liveSession.phase in setOf(DemoSession.Phase.DISARMED, DemoSession.Phase.ARMED)) {
                latestAssessment = HazardAssessment(
                    summary = "Smartwatch reported $heartRateAnomalySummary.",
                    observations = listOf("Sustained abnormal heart rate over 30 seconds."),
                    uncertainties = listOf("Optical/BLE heart-rate rule is not a clinical diagnosis."),
                    hazardDetected = true,
                    hazardType = HazardType.MEDICAL,
                    severity = "warning",
                    recommendedService = HelpService.AMBULANCE,
                    urgentImmediate = false,
                )
                startLiveHazardCheckIn(
                    hazardType = HazardType.MEDICAL,
                    service = HelpService.AMBULANCE,
                    sourceTrigger = DemoSession.Trigger.HEART_RATE_ANOMALY,
                    urgentImmediate = false,
                )
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
            } catch (_: Exception) {
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
                sessionStarted = false
                deviceSessionStatus = "Starting"
                lifecycleScope.launch {
                    session.state.collect { state ->
                        if (wearableSession !== session) return@collect
                        sessionStarted = state == DeviceSessionState.STARTED
                        deviceSessionStatus = state.name.lowercase().replaceFirstChar { it.uppercase() }
                        if (state == DeviceSessionState.STOPPED) {
                            cameraMonitor.stop()
                            sessionStarted = false
                            wearableSession = null
                        }
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
        autoScanCamera = false
        handler.removeCallbacks(autoCameraScanner)
        cameraMonitor.stop()
        cameraStatus = "Camera idle (standby)"
        val session = wearableSession ?: return
        wearableSession = null
        sessionStarted = false
        deviceSessionStatus = "Stopped"
        session.stop()
    }

    private fun sectionHeading(number: String, title: String, description: String) {
        content.addView(label("$number   $title", 18, "#172B26", true).apply { setPadding(0, dp(24), 0, dp(4)) })
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
        minHeight = dp(50)
        setTextColor(color(if (primary) "#FFFFFF" else "#277B69"))
        background = rounded(if (primary) "#277B69" else "#EDF5F0", 14)
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) }
        setOnClickListener { action() }
    }

    private fun rounded(fill: String, radius: Int) = GradientDrawable().apply {
        setColor(color(fill))
        cornerRadius = dp(radius).toFloat()
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun color(value: String) = Color.parseColor(value)
}
