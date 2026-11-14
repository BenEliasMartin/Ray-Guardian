package com.rayguardian.app

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.log10
import kotlin.math.sqrt

/** A relative PCM level in dBFS, not a calibrated sound pressure reading or sound classifier. */
internal class LoudSoundDetector {
    data class Reading(val dbfs: Int, val sustained: Boolean)

    private var loudUs = 0L
    private var previousEndUs: Long? = null

    fun accept(buffer: ByteBuffer, timestampUs: Long): Reading? {
        val pcm = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val count = pcm.remaining()
        if (count == 0) return null
        var squares = 0.0
        while (pcm.hasRemaining()) {
            val sample = pcm.get().toDouble() / 32768
            squares += sample * sample
        }
        val rms = sqrt(squares / count)
        val dbfs = if (rms == 0.0) -96 else (20 * log10(rms)).toInt().coerceIn(-96, 0)
        val durationUs = count * 1_000_000L / 16_000
        val contiguous = previousEndUs?.let { kotlin.math.abs(timestampUs - it) < 150_000 } == true
        previousEndUs = timestampUs + durationUs
        loudUs = if (dbfs < -18) 0 else (if (contiguous) loudUs else 0) + durationUs
        return Reading(dbfs, loudUs >= 1_000_000)
    }
}
