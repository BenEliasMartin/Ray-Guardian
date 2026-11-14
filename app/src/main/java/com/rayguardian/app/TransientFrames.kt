package com.rayguardian.app

/** Owned JPEG bytes in bounded memory only. Never writes files or logs image data. */
class TransientFrames(private val maxFrames: Int = 6, private val maxFrameBytes: Int = 128 * 1024) {
    private val frames = mutableListOf<ByteArray>()
    val size get() = frames.size

    /** Ownership transfers even on rejection, so rejected buffers are cleared as well. */
    fun add(bytes: ByteArray): Boolean {
        if (bytes.isEmpty() || bytes.size > maxFrameBytes || frames.size >= maxFrames) {
            bytes.fill(0)
            return false
        }
        frames.add(bytes)
        return true
    }

    fun copies(): List<ByteArray> = frames.map { it.copyOf() }

    fun clear() {
        frames.forEach { it.fill(0) }
        frames.clear()
    }
}
