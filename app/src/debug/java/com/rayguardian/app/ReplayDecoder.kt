package com.rayguardian.app

import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import com.meta.wearable.dat.camera.types.VideoFrame
import java.io.Closeable

/** Surface decoder for the complete HEVC access units delivered by DAT. Owned by one worker. */
class ReplayDecoder(width: Int, height: Int, surface: Surface) : Closeable {
    private val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
    private val outputInfo = MediaCodec.BufferInfo()

    init {
        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height)
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 2 * 1024 * 1024)
            codec.configure(format, surface, null, 0)
            codec.start()
        } catch (error: Exception) {
            codec.release()
            throw error
        }
    }

    fun accept(frame: VideoFrame) {
        check(frame.isCompressed) { "The simulator returned an unexpected frame format." }
        drain()
        val index = codec.dequeueInputBuffer(20_000)
        check(index >= 0) { "The video decoder is not keeping up. Stop and replay the feed." }
        val destination = checkNotNull(codec.getInputBuffer(index))
        val data = frame.buffer.duplicate()
        check(data.remaining() <= destination.capacity()) { "The video frame is too large." }
        destination.clear()
        val size = data.remaining()
        destination.put(data)
        codec.queueInputBuffer(index, 0, size, frame.presentationTimeUs,
            if (frame.isCodecConfig) MediaCodec.BUFFER_FLAG_CODEC_CONFIG else 0)
        drain()
    }

    private fun drain() {
        while (true) {
            val index = codec.dequeueOutputBuffer(outputInfo, 0)
            if (index >= 0) codec.releaseOutputBuffer(index, outputInfo.size > 0)
            else if (index != MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) return
        }
    }

    override fun close() {
        try { codec.stop() } finally { codec.release() }
    }
}
