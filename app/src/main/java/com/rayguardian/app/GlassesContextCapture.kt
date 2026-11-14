package com.rayguardian.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import com.meta.wearable.dat.camera.Camera
import com.meta.wearable.dat.camera.addCamera
import com.meta.wearable.dat.camera.types.PhotoData
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.StreamState
import com.meta.wearable.dat.camera.types.VideoQuality
import com.meta.wearable.dat.core.Wearables
import com.meta.wearable.dat.core.selectors.AutoDeviceSelector
import com.meta.wearable.dat.core.session.DeviceSession
import com.meta.wearable.dat.core.session.DeviceSessionState
import com.meta.wearable.dat.core.types.Permission
import com.meta.wearable.dat.core.types.PermissionStatus
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** Camera capability exists only inside a requested context window. No video/audio file is made. */
class GlassesContextCapture(private val scope: CoroutineScope) {
    private var job: Job? = null
    private var session: DeviceSession? = null
    private var camera: Camera? = null
    private var generation = 0L

    fun start(simulated: Boolean, onFrame: (ByteArray) -> Unit, onFailure: () -> Unit) {
        stop()
        val run = generation
        job = scope.launch {
            try {
                withTimeout(TriggerController.CAPTURE_MILLIS) {
                    if (simulated) {
                        repeat(6) { i ->
                            delay(900)
                            val frame = withContext(Dispatchers.Default) { syntheticFrame(i) }
                            if (run == generation) onFrame(frame) else frame.fill(0)
                        }
                    } else {
                        var granted = false
                        Wearables.checkPermissionStatus(Permission.CAMERA).fold(
                            onSuccess = { granted = it == PermissionStatus.Granted }, onFailure = { _, _ -> },
                        )
                        check(granted) // No permission dialogs during an incident.
                        var created: DeviceSession? = null
                        Wearables.createSession(AutoDeviceSelector()).fold(
                            onSuccess = { created = it }, onFailure = { _, _ -> },
                        )
                        val active = checkNotNull(created)
                        session = active
                        active.start()
                        active.state.first { it == DeviceSessionState.STARTED }
                        var added: Camera? = null
                        active.addCamera(StreamConfiguration(videoQuality = VideoQuality.LOW, frameRate = 2)).fold(
                            onSuccess = { added = it }, onFailure = { _, _ -> },
                        )
                        val capture = checkNotNull(added)
                        camera = capture
                        var started = false
                        capture.stream.start().fold(onSuccess = { started = true }, onFailure = { _, _ -> })
                        check(started)
                        capture.stream.state.first { it == StreamState.STREAMING }
                        repeat(6) {
                            delay(700)
                            var photo: PhotoData? = null
                            capture.stream.capturePhoto().fold(onSuccess = { photo = it }, onFailure = { _, _ -> })
                            val picture = photo ?: return@repeat
                            val bytes = withContext(Dispatchers.Default) { encodePhoto(picture) }
                            if (run == generation) onFrame(bytes) else bytes.fill(0)
                        }
                    }
                }
            } catch (cancelled: CancellationException) {
                // Controller has an independent foreground deadline; stop/expiry never restarts capture.
                throw cancelled
            } catch (_: Exception) {
                if (run == generation) onFailure()
            } finally {
                if (run == generation) releaseCamera()
            }
        }
    }

    fun stop() {
        generation++
        job?.cancel()
        job = null
        releaseCamera()
    }

    private fun releaseCamera() {
        val oldCamera = camera
        val oldSession = session
        camera = null
        session = null
        // Always attempt both teardown paths, even if one SDK call fails.
        runCatching { oldCamera?.stop() }
        runCatching { oldSession?.stop() }
    }

    companion object {
        private fun encodePhoto(photo: PhotoData): ByteArray {
            val bitmap = when (photo) {
                is PhotoData.Bitmap -> photo.bitmap
                is PhotoData.HEIC -> {
                    val source = photo.data.duplicate()
                    check(source.remaining() <= 5 * 1024 * 1024)
                    val bytes = ByteArray(source.remaining())
                    source.get(bytes)
                    try { checkNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size)) }
                    finally { bytes.fill(0) }
                }
            }
            try { return encode(bitmap) } finally { bitmap.recycle() }
        }

        private fun encode(bitmap: Bitmap): ByteArray {
            val scale = minOf(1.0, 384.0 / maxOf(bitmap.width, bitmap.height))
            val resized = Bitmap.createScaledBitmap(bitmap, maxOf(1, (bitmap.width * scale).toInt()), maxOf(1, (bitmap.height * scale).toInt()), true)
            return try {
                ByteArrayOutputStream().use { output ->
                    check(resized.compress(Bitmap.CompressFormat.JPEG, 70, output))
                    check(output.size() <= 128 * 1024)
                    output.toByteArray()
                }
            } finally { if (resized !== bitmap) resized.recycle() }
        }

        private fun syntheticFrame(index: Int): ByteArray {
            val bitmap = Bitmap.createBitmap(320, 180, Bitmap.Config.ARGB_8888)
            Canvas(bitmap).apply {
                drawColor(Color.rgb(220, 235, 225))
                drawText("SIMULATION ${index + 1}", 24f, 90f, Paint().apply { color = Color.DKGRAY; textSize = 24f })
            }
            return try { encode(bitmap) } finally { bitmap.recycle() }
        }

        /** Caller owns and clears the copies, and must not send a montage without separate consent. */
        fun montage(frames: List<ByteArray>): ByteArray {
            check(frames.isNotEmpty() && frames.size <= 6)
            val bitmap = Bitmap.createBitmap(768, 464, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.BLACK)
            try {
                frames.forEachIndexed { i, bytes ->
                    val frame = checkNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
                    val x = (i % 3) * 256f
                    val y = (i / 3) * 232f
                    val scale = minOf(256f / frame.width, 208f / frame.height)
                    val w = frame.width * scale
                    val h = frame.height * scale
                    canvas.drawBitmap(frame, null, android.graphics.RectF(x + (256-w)/2, y + (208-h)/2, x + (256+w)/2, y + (208+h)/2), null)
                    canvas.drawText("Frame ${i+1}", x+8, y+225, Paint().apply { color = Color.WHITE; textSize = 14f })
                    frame.recycle()
                }
                return ByteArrayOutputStream().use { output ->
                    check(bitmap.compress(Bitmap.CompressFormat.JPEG, 75, output))
                    check(output.size() <= 768 * 1024)
                    output.toByteArray()
                }
            } finally { bitmap.recycle() }
        }
    }
}
