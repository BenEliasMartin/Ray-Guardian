package com.rayguardian.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AiImageHandoffTest {
    @Test fun imageCanOnlyBeConsumedOnce() {
        AiImageHandoff.put(byteArrayOf(1, 2, 3), "Frozen test frame")
        assertEquals("Frozen test frame", AiImageHandoff.take()?.label)
        assertNull(AiImageHandoff.take())
    }

    @Test(expected = IllegalArgumentException::class)
    fun oversizeImageCannotBeHandedToAi() {
        AiImageHandoff.put(ByteArray(768 * 1024 + 1), "too big")
    }
}
