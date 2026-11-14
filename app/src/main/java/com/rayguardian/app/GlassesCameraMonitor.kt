package com.rayguardian.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.SystemClock
import android.util.Base64
import com.meta.wearable.dat.camera.Camera
import com.meta.wearable.dat.camera.addCamera
import com.meta.wearable.dat.camera.removeCamera
import com.meta.wearable.dat.camera.types.PhotoData
import com.meta.wearable.dat.camera.types.StreamConfiguration
import com.meta.wearable.dat.camera.types.StreamState
import com.meta.wearable.dat.camera.types.VideoFrame
import com.meta.wearable.dat.camera.types.VideoQuality
import com.meta.wearable.dat.core.session.DeviceSession
import java.io.ByteArrayOutputStream
import java.util.ArrayDeque
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Attaches the Meta Wearables DAT Camera capability (`mwdat-camera`) to an active [DeviceSession],
 * samples uncompressed I420 frames at a low duty-cycle (~1 frame per 1.5s), and maintains up to
 * three ordered JPEG snapshots (`<= 512px`) ready for Nemotron multi-hazard analysis.
 */
class GlassesCameraMonitor(
    private val scope: CoroutineScope,
    private val onStateChanged: (String) -> Unit,
) {
    private val recentFrames = ArrayDeque<String>(MAX_BUFFERED_FRAMES)
    private var camera: Camera? = null
    private var attachedSession: DeviceSession? = null
    private var streamJobs: List<Job> = emptyList()
    private var lastSampledAtMillis = 0L

    val isStreaming: Boolean
        get() = camera != null

    val bufferedFrameCount: Int
        @Synchronized get() = recentFrames.size

    @Synchronized
    fun snapshotFrames(): List<String> = recentFrames.toList()

    fun start(session: DeviceSession) {
        stop()
        val config = StreamConfiguration(
            videoQuality = VideoQuality.LOW,
            frameRate = 15,
            compressVideo = false,
        )
        session.addCamera(config).fold(
            onSuccess = { attachedCamera ->
                camera = attachedCamera
                attachedSession = session
                onStateChanged("Camera attached — starting POV stream…")
                val stateJob = scope.launch {
                    attachedCamera.stream.state.collect { state ->
                        if (camera !== attachedCamera) return@collect
                        val label = when (state) {
                            StreamState.STREAMING -> "Streaming POV (${bufferedFrameCount}/$MAX_BUFFERED_FRAMES frames buffered)"
                            StreamState.STARTED, StreamState.STARTING -> "Starting glasses camera…"
                            StreamState.PAUSED -> "Glasses camera paused"
                            StreamState.STOPPED, StreamState.CLOSED -> "Glasses camera stopped"
                            StreamState.STOPPING -> "Stopping glasses camera…"
                        }
                        onStateChanged(label)
                    }
                }
                val errorJob = scope.launch {
                    attachedCamera.stream.errorStream.collect { streamError ->
                        if (camera === attachedCamera) {
                            onStateChanged("Camera stream issue: ${streamError.name.lowercase()}")
                        }
                    }
                }
                val frameJob = scope.launch(Dispatchers.Default) {
                    attachedCamera.stream.videoStream.collect { frame ->
                        if (camera !== attachedCamera || frame.isCompressed || frame.isCodecConfig) return@collect
                        val now = SystemClock.elapsedRealtime()
                        if (now - lastSampledAtMillis < SAMPLE_INTERVAL_MILLIS) return@collect
                        val encoded = runCatching { encodeI420FrameToDataUrl(frame) }.getOrNull() ?: return@collect
                        lastSampledAtMillis = now
                        recordFrame(encoded)
                        scope.launch {
                            if (camera === attachedCamera) {
                                onStateChanged("Streaming POV (${bufferedFrameCount}/$MAX_BUFFERED_FRAMES frames buffered)")
                            }
                        }
                    }
                }
                streamJobs = listOf(stateJob, errorJob, frameJob)
                attachedCamera.stream.start().fold(
                    onSuccess = {},
                    onFailure = { error, _ ->
                        onStateChanged("Could not start glasses stream: ${error.name.lowercase()}")
                        stop()
                    },
                )
            },
            onFailure = { error, _ ->
                onStateChanged("Could not attach glasses camera: ${error.description}")
            },
        )
    }

    suspend fun captureOrGetFrames(): List<String> {
        val existing = snapshotFrames()
        if (existing.isNotEmpty()) return existing
        val activeCamera = camera ?: return emptyList()
        var capturedUrl: String? = null
        activeCamera.stream.capturePhoto().fold(
            onSuccess = { photo ->
                if (photo is PhotoData.Bitmap) {
                    capturedUrl = runCatching { encodeBitmapToDataUrl(photo.bitmap) }.getOrNull()
                }
            },
            onFailure = { _, _ -> },
        )
        return capturedUrl?.also { recordFrame(it) }?.let(::listOf) ?: emptyList()
    }

    fun stop() {
        streamJobs.forEach { it.cancel() }
        streamJobs = emptyList()
        camera?.let { active ->
            camera = null
            runCatching { active.stream.stop() }
            runCatching { active.stop() }
            runCatching { active.close() }
        }
        attachedSession?.let { session ->
            attachedSession = null
            runCatching { session.removeCamera() }
        }
        synchronized(this) {
            recentFrames.clear()
        }
        lastSampledAtMillis = 0L
    }

    @Synchronized
    private fun recordFrame(dataUrl: String) {
        if (recentFrames.size >= MAX_BUFFERED_FRAMES) recentFrames.removeFirst()
        recentFrames.addLast(dataUrl)
    }

    private fun encodeI420FrameToDataUrl(frame: VideoFrame): String? {
        val width = frame.width
        val height = frame.height
        if (width <= 0 || height <= 0) return null
        val ySize = width * height
        val uvPlaneSize = (width / 2) * (height / 2)
        val expectedBytes = ySize + uvPlaneSize * 2
        val source = frame.buffer.duplicate()
        if (source.remaining() < expectedBytes) return null

        val i420 = ByteArray(expectedBytes)
        source.get(i420, 0, expectedBytes)

        // Convert I420 (YYYY... UU... VV...) -> NV21 (YYYY... VUVU...)
        val nv21 = ByteArray(expectedBytes)
        System.arraycopy(i420, 0, nv21, 0, ySize)
        var dst = ySize
        val uOffset = ySize
        val vOffset = ySize + uvPlaneSize
        for (i in 0 until uvPlaneSize) {
            nv21[dst++] = i420[vOffset + i]
            nv21[dst++] = i420[uOffset + i]
        }

        val rawJpeg = ByteArrayOutputStream().use { out ->
            val yuv = YuvImage(nv21, ImageFormat.NV21, width, height, null)
            if (!yuv.compressToJpeg(Rect(0, 0, width, height), 80, out)) return null
            out.toByteArray()
        }
        val decoded = BitmapFactory.decodeByteArray(rawJpeg, 0, rawJpeg.size) ?: return null
        try {
            return encodeBitmapToDataUrl(decoded)
        } finally {
            decoded.recycle()
        }
    }

    private fun encodeBitmapToDataUrl(bitmap: Bitmap): String {
        val maxSide = maxOf(bitmap.width, bitmap.height)
        val scale = minOf(1.0f, MAX_SIDE_PX.toFloat() / maxSide.toFloat())
        val targetW = maxOf(1, (bitmap.width * scale).toInt())
        val targetH = maxOf(1, (bitmap.height * scale).toInt())
        val scaled = if (targetW == bitmap.width && targetH == bitmap.height) {
            bitmap
        } else {
            Bitmap.createScaledBitmap(bitmap, targetW, targetH, true)
        }
        try {
            val bytes = ByteArrayOutputStream().use { out ->
                check(scaled.compress(Bitmap.CompressFormat.JPEG, 76, out))
                out.toByteArray()
            }
            return "data:image/jpeg;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)
        } finally {
            if (scaled !== bitmap) scaled.recycle()
        }
    }

    companion object {
        private const val MAX_BUFFERED_FRAMES = 3
        private const val SAMPLE_INTERVAL_MILLIS = 1_500L
        private const val MAX_SIDE_PX = 512
    }
}
