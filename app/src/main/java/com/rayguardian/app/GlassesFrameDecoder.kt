package com.rayguardian.app

import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import com.meta.wearable.dat.camera.types.VideoFrame
import java.io.Closeable
import kotlin.math.max

/** Decodes Meta's HEVC stream and samples its luma plane regardless of codec row or pixel stride. */
internal class GlassesFrameDecoder(width: Int, height: Int) : Closeable {
    private val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
    private val info = MediaCodec.BufferInfo()
    private var lastSampleUs: Long? = null

    init {
        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height)
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1024 * 1024)
            codec.configure(format, null, null, 0)
            codec.start()
        } catch (error: Exception) {
            codec.release()
            throw error
        }
    }

    fun accept(frame: VideoFrame, onSample: (Bitmap) -> Unit) {
        check(frame.isCompressed) { "Glasses returned an unexpected video format." }
        drain(onSample)
        val index = codec.dequeueInputBuffer(40_000)
        check(index >= 0) { "The phone video decoder could not keep up." }
        val input = checkNotNull(codec.getInputBuffer(index))
        val source = frame.buffer.duplicate()
        input.clear()
        check(source.remaining() <= input.remaining()) { "Glasses video frame exceeded the decoder buffer." }
        val size = source.remaining()
        input.put(source)
        codec.queueInputBuffer(index, 0, size, frame.presentationTimeUs,
            if (frame.isCodecConfig) MediaCodec.BUFFER_FLAG_CODEC_CONFIG else 0)
        drain(onSample)
    }

    private fun drain(onSample: (Bitmap) -> Unit) {
        while (true) {
            val index = codec.dequeueOutputBuffer(info, 0)
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) continue
            if (index < 0) return
            try {
                val previous = lastSampleUs
                if (info.size > 0 && (previous == null || info.presentationTimeUs < previous ||
                        info.presentationTimeUs - previous >= 1_000_000)) {
                    val image = checkNotNull(codec.getOutputImage(index)) { "This phone cannot read decoded HEVC images." }
                    val bitmap = image.use { sample(it) }
                    lastSampleUs = info.presentationTimeUs
                    onSample(bitmap)
                }
            } finally {
                codec.releaseOutputBuffer(index, false)
            }
        }
    }

    private fun sample(image: Image): Bitmap {
        check(image.format == ImageFormat.YUV_420_888) { "Unsupported video decoder image format." }
        val crop = image.cropRect
        val divisor = max(1, (max(crop.width(), crop.height()) + 479) / 480)
        val width = crop.width() / divisor
        val height = crop.height() / divisor
        val luma = image.planes[0]
        val buffer = luma.buffer
        val base = buffer.position()
        val pixels = IntArray(width * height)
        for (y in 0 until height) {
            val row = base + (crop.top + y * divisor) * luma.rowStride
            for (x in 0 until width) {
                val level = buffer.get(row + (crop.left + x * divisor) * luma.pixelStride).toInt() and 0xff
                pixels[y * width + x] = 0xff000000.toInt() or (level * 0x010101)
            }
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
    }

    override fun close() {
        try { codec.stop() } finally { codec.release() }
    }
}
