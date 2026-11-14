package com.rayguardian.app

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import com.meta.wearable.dat.mockdevice.MockDeviceKit
import com.meta.wearable.dat.mockdevice.api.GlassesModel
import com.meta.wearable.dat.mockdevice.api.MockGlasses
import com.meta.wearable.dat.core.types.ThermalLevel
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Available only in debug builds; never substitute these states for a real device. */
object MockGlassesBridge {
    val available = true
    private var glasses: MockGlasses? = null
    val isReady: Boolean get() = glasses != null
    fun liveCaptureSealingAllowed(context: Context): Boolean = !MockDeviceKit.getInstance(context.applicationContext).isEnabled

    suspend fun start(context: Context): String? {
        val kit = MockDeviceKit.getInstance(context.applicationContext)
        if (kit.isEnabled && glasses != null) return null
        kit.enable()
        var failure: String? = null
        kit.pairGlasses(GlassesModel.RAYBAN_META).fold(
            onSuccess = { device ->
                device.powerOn()
                device.unfold()
                device.don()
                glasses = device
            },
            onFailure = { error, _ -> failure = error.description },
        )
        return failure
    }

    data class ReplaySource(val uri: Uri, val width: Int, val height: Int, val label: String)

    suspend fun prepareFeed(context: Context, selected: Uri?): ReplaySource = withContext(Dispatchers.IO) {
        val device = checkNotNull(glasses) { "Start simulated glasses first." }
        val file = File(context.cacheDir, "mock-glasses-replay.mp4")
        val source = if (selected == null) runCatching { context.assets.open("simulator_path.mp4") }.getOrElse {
            error("Generate the bundled synthetic clip before building, or choose a local HEVC video. See the Android mock setup in README.")
        }
            else context.contentResolver.openInputStream(selected) ?: error("Could not open the selected video.")
        try {
            source.use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(8192)
                    var size = 0
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        size += count
                        check(size <= 20 * 1024 * 1024) { "Choose an HEVC video smaller than 20 MiB." }
                        output.write(buffer, 0, count)
                    }
                }
            }
            val extractor = MediaExtractor()
            val dimensions = try {
                extractor.setDataSource(file.absolutePath)
                val video = (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
                    .firstOrNull { it.getString(MediaFormat.KEY_MIME) == MediaFormat.MIMETYPE_VIDEO_HEVC }
                    ?: error("MockDeviceKit needs an HEVC / H.265 MP4 video.")
                val width = video.getInteger(MediaFormat.KEY_WIDTH)
                val height = video.getInteger(MediaFormat.KEY_HEIGHT)
                check(width in 32..1920 && height in 32..1920) { "Choose a video no larger than 1920 pixels per side." }
                width to height
            } finally { extractor.release() }
            val uri = Uri.fromFile(file)
            device.services.camera.setCameraFeed(uri)
            ReplaySource(uri, dimensions.first, dimensions.second,
                if (selected == null) "Synthetic walking POV · test replay" else "Selected video · test replay")
        } catch (error: Exception) {
            file.delete()
            throw error
        }
    }

    fun setThermalLevel(level: ThermalLevel) {
        glasses?.setThermalLevel(level)
    }
}
