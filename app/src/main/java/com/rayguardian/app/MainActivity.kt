package com.rayguardian.app

import android.Manifest
import android.content.pm.PackageManager
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
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.selectors.AutoDeviceSelector
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.session.DeviceSessionState
import com.meta.wearable.dat.core.types.DeviceIdentifier
import com.meta.wearable.dat.core.types.RegistrationState
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
    private var timerText: TextView? = null
    private lateinit var content: LinearLayout

    private enum class IntegrationMode { REAL, MOCK }

    companion object {
        // DAT and MockDeviceKit live for the process lifetime, including activity recreation.
        private var activeIntegrationMode: IntegrationMode? = null
    }

    private val bluetoothPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) connectRealGlasses()
            else {
                integrationError = "Bluetooth access was not granted. You can still use the local demo."
                render()
            }
        }

    private val countdown = object : Runnable {
        override fun run() {
            if (demo.phase != DemoSession.Phase.CHECK_IN) return
            val now = SystemClock.elapsedRealtime()
            demo.tick(now)
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
        window.statusBarColor = color("#F6F7F4")
        window.navigationBarColor = color("#F6F7F4")
        val scroll = ScrollView(this).apply {
            setBackgroundColor(color("#F6F7F4"))
            isFillViewport = true
        }
        content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(28), dp(22), dp(32))
        }
        scroll.setOnApplyWindowInsetsListener { _, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            content.setPadding(dp(22), dp(28) + bars.top, dp(22), dp(32) + bars.bottom)
            insets
        }
        scroll.addView(content)
        setContentView(scroll)
        mode = activeIntegrationMode
        if (mode != null) observeWearables()
        render()
    }

    override fun onPause() {
        // The rehearsal is foreground-only. It must never imply background coverage.
        if (demo.phase == DemoSession.Phase.ARMED || demo.phase == DemoSession.Phase.CHECK_IN) {
            demo.disarm()
            handler.removeCallbacks(countdown)
        }
        stopWearableSession()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        if (::content.isInitialized) render()
    }

    override fun onDestroy() {
        handler.removeCallbacks(countdown)
        super.onDestroy()
    }

    private fun render() {
        content.removeAllViews()
        timerText = null

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
        banner.addView(label("No help is contacted. No emergency detection or background monitoring is active.", 15, "#23463D").apply {
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
        if (mode != null && hasActiveDevice) {
            if (wearableSession == null) {
                deviceCard.addView(button("Start device session", false) { startWearableSession() })
            } else {
                deviceCard.addView(button("End device session", false) { stopWearableSession(); render() })
            }
        }
        content.addView(deviceCard)

        sectionHeading("02", "Rehearse an alert", "Practice the flow using only simulated events.")
        val sessionCard = card("#FFFFFF")
        val phaseTitle: String
        val phaseDescription: String
        when (demo.phase) {
            DemoSession.Phase.DISARMED -> {
                phaseTitle = "Ready to practice"
                phaseDescription = "Start a foreground-only rehearsal. It stops when you leave this screen."
            }
            DemoSession.Phase.ARMED -> {
                phaseTitle = "Rehearsal active"
                phaseDescription = "Choose a simulated SOS or replay a candidate event. No sensors are being watched."
            }
            DemoSession.Phase.CHECK_IN -> {
                phaseTitle = "Are you okay?"
                phaseDescription = "This is a replayed event. Cancel the check-in or wait to see the alert screen."
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
        when (demo.phase) {
            DemoSession.Phase.DISARMED -> sessionCard.addView(button("Start rehearsal", true) {
                demo.arm()
                render()
            })
            DemoSession.Phase.ARMED -> {
                sessionCard.addView(button("Simulate SOS", true) { demo.manualSos(); render() })
                sessionCard.addView(button("Replay a possible incident", false) {
                    demo.replayCandidate(SystemClock.elapsedRealtime())
                    render()
                    handler.removeCallbacks(countdown)
                    handler.post(countdown)
                })
                sessionCard.addView(button("Stop rehearsal", false) { demo.disarm(); render() })
            }
            DemoSession.Phase.CHECK_IN -> {
                timerText = label("Simulated alert in 15 seconds", 16, "#A84436", true).apply {
                    setPadding(0, dp(14), 0, 0)
                }
                sessionCard.addView(timerText)
                sessionCard.addView(button("I'm okay — cancel", true) {
                    demo.cancel()
                    handler.removeCallbacks(countdown)
                    render()
                })
                sessionCard.addView(button("Simulate SOS now", false) {
                    demo.manualSos()
                    handler.removeCallbacks(countdown)
                    render()
                })
            }
            DemoSession.Phase.ALERT, DemoSession.Phase.ACKNOWLEDGED -> {
                val triggerText = when (demo.trigger) {
                    DemoSession.Trigger.MANUAL -> "Trigger: simulated SOS"
                    DemoSession.Trigger.REPLAYED_CANDIDATE -> "Trigger: replayed incident"
                    null -> "Trigger unavailable"
                }
                sessionCard.addView(label(triggerText, 13, "#71817A").apply { setPadding(0, dp(10), 0, 0) })
                sessionCard.addView(label("Example location: Helsinki, Finland (test data)", 13, "#71817A").apply { setPadding(0, dp(5), 0, 0) })
                sessionCard.addView(label("Demo contact: ${if (demo.phase == DemoSession.Phase.ACKNOWLEDGED) "simulated acknowledgment" else "not contacted"}", 13, "#71817A").apply { setPadding(0, dp(5), 0, 0) })
                if (demo.phase == DemoSession.Phase.ALERT) {
                    sessionCard.addView(button("Simulate acknowledgment", true) { demo.acknowledge(); render() })
                }
                sessionCard.addView(button("Cancel simulated alert", false) { demo.cancel(); render() })
                sessionCard.addView(button("Finish rehearsal", false) { demo.finish(); render() })
            }
            DemoSession.Phase.CANCELLED -> sessionCard.addView(button("Finish rehearsal", true) { demo.finish(); render() })
        }
        content.addView(sessionCard)

        content.addView(label("Built for careful testing", 14, "#277B69", true).apply { setPadding(0, dp(24), 0, dp(6)) })
        content.addView(label("Camera, microphone, location, automatic detection and real alert delivery are not enabled in this prototype.", 13, "#71817A"))
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
                registration = when (state) {
                    RegistrationState.REGISTERED -> if (mode == IntegrationMode.MOCK) "Simulated registration active" else "Connected to Meta AI"
                    RegistrationState.REGISTERING -> "Connecting…"
                    RegistrationState.UNREGISTERING -> "Disconnecting…"
                    else -> "Not registered"
                }
                render()
            }
        }
        activeDeviceJob?.cancel()
        activeDeviceJob = lifecycleScope.launch {
            deviceSelector.activeDeviceFlow().collect { device ->
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
