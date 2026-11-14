package com.rayguardian.app

/** One-shot in-memory handoff. A frame is never put in an Intent, log, or shared file. */
object AiImageHandoff {
    data class Image(val jpeg: ByteArray, val label: String)
    private var pending: Pair<Long, Image>? = null

    @Synchronized fun put(jpeg: ByteArray, label: String) {
        require(jpeg.size <= 768 * 1024)
        pending = System.nanoTime() to Image(jpeg, label)
    }

    @Synchronized fun take(): Image? {
        val image = pending
        pending = null
        return image?.takeIf { System.nanoTime() - it.first < 60_000_000_000L }?.second
    }
}
