package com.rayguardian.app

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.view.Gravity
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.WindowInsets
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.lifecycleScope
import com.meta.wearable.dat.camera.Camera
import com.meta.wearable.dat.camera.addCamera
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.StreamError
import com.meta.wearable.dat.camera.types.StreamState
import com.meta.wearable.dat.camera.types.VideoQuality
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.selectors.AutoDeviceSelector
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.session.DeviceSessionState
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import com.meta.wearable.dat.core.types.ThermalLevel
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull

/** Debug-only preview. Frames come from a DAT stream supplied by MockDeviceKit's video replay. */
class FeedActivity : ComponentActivity(), TextureView.SurfaceTextureListener {
    private lateinit var texture: TextureView
    private lateinit var overlay: TextView
    private lateinit var status: TextView
    private lateinit var counters: TextView
    private lateinit var sourceLabel: TextView
    private lateinit var startButton: Button
    private lateinit var stopButton: Button
    private lateinit var chooseButton: Button
    private lateinit var analyzeButton: Button
    private var selected: Uri? = null
    private var source: MockGlassesBridge.ReplaySource? = null
    private var run: Job? = null
    private var session: DeviceSession? = null
    private var camera: Camera? = null
    private var running = false
    private var autoStart = false
    private var stopReason = "Feed stopped"
    @Volatile private var received = 0
    private var presented = 0
    @Volatile private var lastReceived = 0L
    private var lastPresented = 0L
    @Volatile private var streamTimestampUs = 0L

    private val picker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            selected = uri
            lifecycleScope.launch { run?.join(); startFeed() }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        autoStart = intent.getBooleanExtra("autoplay", false)
        if (intent.getBooleanExtra("local_replay", false)) {
            val localFile = File(filesDir, "local-pov.mp4")
            if (localFile.isFile) selected = Uri.fromFile(localFile)
        }
        val scroll = ScrollView(this).apply { setBackgroundColor(Color.parseColor("#F6F7F4")) }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(18), dp(18), dp(24))
        }
        scroll.addView(layout)
        scroll.setOnApplyWindowInsetsListener { _, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            layout.setPadding(dp(18), dp(18) + bars.top, dp(18), dp(24) + bars.bottom)
            insets
        }
        setContentView(scroll)
        layout.addView(text("GLASSES POV  /  SIMULATOR", 20))
        layout.addView(text("Video replay through Meta MockDeviceKit. This is not a live camera or automatic emergency detector.", 14))
        val frame = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            layoutParams = LinearLayout.LayoutParams(-1, dp(310))
        }
        texture = TextureView(this).apply { surfaceTextureListener = this@FeedActivity }
        frame.addView(texture, FrameLayout.LayoutParams(-1, -1))
        frame.addView(text("SIMULATED • VIDEO REPLAY", 11).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(0xAA000000.toInt())
        }, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START))
        overlay = text("Press Start replay", 18).apply {
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setBackgroundColor(0x66000000)
        }
        frame.addView(overlay, FrameLayout.LayoutParams(-1, -1))
        layout.addView(frame)
        sourceLabel = text("Synthetic walking POV · test replay", 14)
        layout.addView(sourceLabel)
        counters = text("Frames received: 0 · presented: 0", 13)
        layout.addView(counters)
        status = text("Stopped. Playback stays on this device; no video is uploaded.", 14)
        layout.addView(status)
        startButton = button("Start replay") { startFeed() }
        stopButton = button("Stop feed") { stopFeed("Feed stopped by you") }
        layout.addView(startButton)
        layout.addView(stopButton)
        analyzeButton = button("Analyze current frame with Nemotron") { freezeFrame() }
        layout.addView(analyzeButton)
        chooseButton = button("Load POV video") {
            stopFeed("Feed stopped to choose a video")
            picker.launch(arrayOf("video/mp4", "video/quicktime"))
        }
        layout.addView(chooseButton)
        layout.addView(button("Use synthetic test clip") {
            selected = null
            stopFeed("Switching to synthetic replay")
            lifecycleScope.launch { run?.join(); startFeed() }
        })
        layout.addView(button("Simulate hot glasses") { MockGlassesBridge.setThermalLevel(ThermalLevel.SEVERE) })
        layout.addView(button("Reset simulated heat") {
            MockGlassesBridge.setThermalLevel(ThermalLevel.NONE)
            status.text = "Thermal state reset. Press Start replay to resume."
        })
        layout.addView(text("HEVC/H.265 MP4 or MOV, up to 20 MiB and 1920 pixels per side. Audio is not played. Replay stops when you leave or after two minutes. A selected frame is sent to AI only after separate consent.", 12))
        layout.addView(button("Back to Ray Guardian") { finish() })
        updateControls()
    }

    override fun onResume() {
        super.onResume()
        if (autoStart && texture.isAvailable) { autoStart = false; startFeed() }
    }

    override fun onPause() {
        stopFeed("Feed stopped because this screen was left")
        super.onPause()
    }

    private fun startFeed() {
        if (run != null || !texture.isAvailable) return
        running = true
        stopReason = "Replay ended"
        received = 0
        presented = 0
        lastReceived = SystemClock.elapsedRealtime()
        lastPresented = 0
        overlay.text = "Connecting to simulated feed…"
        overlay.visibility = View.VISIBLE
        status.text = "Preparing replay and DAT camera session…"
        updateControls()
        run = lifecycleScope.launch {
            var output: Surface? = null
            var ownedSession: DeviceSession? = null
            try {
                check(MockGlassesBridge.start(applicationContext) == null) { "Could not initialize simulated glasses." }
                val clip = MockGlassesBridge.prepareFeed(applicationContext, selected)
                source = clip
                sourceLabel.text = clip.label
                fitPreview()
                var granted = false
                Wearables.checkPermissionStatus(Permission.CAMERA).onSuccess { granted = it == PermissionStatus.Granted }
                check(granted) { "The simulated camera permission is not granted." }
                val selector = AutoDeviceSelector()
                withTimeout(5000) { selector.activeDeviceFlow().first { it != null } }
                var failure: String? = null
                Wearables.createSession(selector).fold(
                    onSuccess = { ownedSession = it },
                    onFailure = { error, _ -> failure = error.description },
                )
                val current = checkNotNull(ownedSession) { failure ?: "No simulated device session is available." }
                session = current
                current.start()
                withTimeout(10_000) { current.state.first { it == DeviceSessionState.STARTED || it == DeviceSessionState.STOPPED } }
                check(current.state.value == DeviceSessionState.STARTED) { "The simulated session ended before streaming." }
                check(current.deviceInfo.value.thermalLevel in setOf(ThermalLevel.NONE, ThermalLevel.LIGHT)) {
                    "Glasses heat is elevated or unknown. Reset simulated heat before replaying."
                }
                current.addCamera(StreamConfiguration(videoQuality = VideoQuality.LOW, frameRate = 7, compressVideo = true)).fold(
                    onSuccess = { camera = it },
                    onFailure = { error, _ -> failure = error.description },
                )
                val capability = checkNotNull(camera) { failure ?: "Could not attach the simulated camera." }
                val stream = capability.stream
                output = Surface(checkNotNull(texture.surfaceTexture))
                coroutineScope {
                    launch(Dispatchers.Default) {
                        ReplayDecoder(clip.width, clip.height, output!!).use { decoder ->
                            stream.videoStream.collect { video ->
                                decoder.accept(video)
                                if (!video.isCodecConfig) {
                                    received++
                                    streamTimestampUs = video.presentationTimeUs
                                    lastReceived = SystemClock.elapsedRealtime()
                                }
                            }
                        }
                    }
                    launch {
                        stream.errorStream.collect { error ->
                            if (error != StreamError.STREAM_ERROR) stopFeed("Camera stopped: ${error.description}")
                        }
                    }
                    launch {
                        var active = false
                        stream.state.collect { state ->
                            if (state != StreamState.STOPPED && state != StreamState.CLOSED) active = true
                            if (active && state in setOf(StreamState.CLOSED, StreamState.STOPPED)) stopFeed("Replay ended. Press Start replay to repeat.")
                            if (state == StreamState.PAUSED) {
                                overlay.text = "Feed paused"
                                overlay.visibility = View.VISIBLE
                            }
                        }
                    }
                    launch {
                        current.deviceInfo.collect { device ->
                            if (device.thermalLevel !in setOf(ThermalLevel.NONE, ThermalLevel.LIGHT)) {
                                stopFeed("Feed stopped for heat. Reset simulated heat, then replay.")
                            }
                        }
                    }
                    launch { current.errors.collect { stopFeed("Device session stopped: ${it.description}") } }
                    launch {
                        val started = SystemClock.elapsedRealtime()
                        while (running) {
                            delay(500)
                            val now = SystemClock.elapsedRealtime()
                            counters.text = "Frames received: $received · presented: $presented · ${streamTimestampUs / 1_000_000}s"
                            analyzeButton.isEnabled = freshFrame()
                            if (now - started > 120_000) stopFeed("Two-minute replay limit reached. Press Start replay to continue.")
                            else if (now - lastReceived > if (received == 0) 10_000 else 3500) {
                                stopFeed("No fresh frames. Replay ended or paused; press Start replay to retry.")
                            }
                        }
                    }
                    stream.start().onFailure { error, _ -> failure = error.description }
                    check(failure == null) { failure ?: "Could not start the stream." }
                    awaitCancellation()
                }
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                stopReason = error.message ?: "The simulated feed could not be started."
            } finally {
                closeCamera(camera)
                camera = null
                ownedSession?.stop()
                withContext(NonCancellable) {
                    withTimeoutOrNull(2500) { ownedSession?.state?.first { it == DeviceSessionState.STOPPED } }
                }
                session = null
                output?.release()
                running = false
                run = null
                if (!isDestroyed) {
                    status.text = stopReason
                    overlay.text = "Feed stopped"
                    overlay.visibility = View.VISIBLE
                    updateControls()
                }
                android.util.Log.i("RayGuardianFeed", "Feed stopped; camera and device session released")
            }
        }
    }

    private fun stopFeed(reason: String) {
        stopReason = reason
        running = false
        session?.stop()
        run?.cancel()
        if (::status.isInitialized) {
            status.text = reason
            overlay.text = "Feed stopped"
            overlay.visibility = View.VISIBLE
            updateControls()
        }
    }

    private fun closeCamera(capability: Closeable?) { capability?.close() }

    private fun freshFrame() = running && presented > 0 && SystemClock.elapsedRealtime() - lastPresented < 2000

    private fun freezeFrame() {
        if (!freshFrame()) return
        val snapshot = texture.bitmap ?: return
        stopFeed("Feed paused for frame review")
        lifecycleScope.launch {
            val bytes = withContext(Dispatchers.Default) {
                val scale = minOf(1.0, 768.0 / maxOf(snapshot.width, snapshot.height))
                val reduced = Bitmap.createScaledBitmap(snapshot,
                    maxOf(1, (snapshot.width * scale).toInt()), maxOf(1, (snapshot.height * scale).toInt()), true)
                try {
                    ByteArrayOutputStream().use { output ->
                        check(reduced.compress(Bitmap.CompressFormat.JPEG, 78, output))
                        output.toByteArray()
                    }
                } finally {
                    if (reduced !== snapshot) reduced.recycle()
                    snapshot.recycle()
                }
            }
            AiImageHandoff.put(bytes, "Frozen simulator frame")
            startActivity(Intent(this@FeedActivity, AiActivity::class.java)
                .putExtra("feed_frame", true)
                .putExtra("context_description", "SIMULATOR VIDEO REPLAY, not a live camera. Describe only visible observations in this frozen frame and state uncertainty. Do not diagnose a condition or assume an emergency."))
        }
    }

    private fun updateControls() {
        startButton.isEnabled = run == null && !running
        stopButton.isEnabled = running
        chooseButton.isEnabled = !running
        analyzeButton.isEnabled = freshFrame()
    }

    private fun fitPreview() {
        val clip = source ?: return
        if (texture.width == 0 || texture.height == 0) return
        val viewRatio = texture.width.toFloat() / texture.height
        val videoRatio = clip.width.toFloat() / clip.height
        val sx = if (viewRatio > videoRatio) videoRatio / viewRatio else 1f
        val sy = if (viewRatio < videoRatio) viewRatio / videoRatio else 1f
        texture.setTransform(Matrix().apply { setScale(sx, sy, texture.width / 2f, texture.height / 2f) })
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        fitPreview()
        if (autoStart) { autoStart = false; startFeed() }
    }
    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = fitPreview()
    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        stopFeed("Preview surface closed")
        return true
    }
    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {
        if (!running) return
        presented++
        lastPresented = SystemClock.elapsedRealtime()
        overlay.visibility = View.GONE
        status.text = "Playing local replay · no upload · auto-stop after 2 minutes"
        analyzeButton.isEnabled = true
        if (presented == 1 || presented % 30 == 0) android.util.Log.i("RayGuardianFeed", "Replay presented frames=$presented received=$received")
    }

    private fun text(value: String, size: Int) = TextView(this).apply {
        text = value
        textSize = size.toFloat()
        setTextColor(Color.parseColor("#23463D"))
        setPadding(dp(6), dp(6), dp(6), dp(6))
    }
    private fun button(value: String, action: () -> Unit) = Button(this).apply {
        text = value
        isAllCaps = false
        minHeight = dp(46)
        setOnClickListener { action() }
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
