package com.rayguardian.app

import org.junit.Assert.*
import org.junit.Test

class TransientFramesTest {
    @Test fun capacityAndSizeAreBoundedAndRejectedBytesAreCleared() {
        val frames=TransientFrames(maxFrames=1,maxFrameBytes=4)
        val accepted=byteArrayOf(1,2,3)
        assertTrue(frames.add(accepted))
        val full=byteArrayOf(4,5)
        val large=ByteArray(5){7}
        assertFalse(frames.add(full))
        assertFalse(frames.add(large))
        assertTrue(full.all { it==0.toByte() })
        assertTrue(large.all { it==0.toByte() })
        frames.clear()
        assertEquals(0,frames.size)
        assertTrue(accepted.all { it==0.toByte() })
    }

    @Test fun snapshotOwnsIndependentCopies() {
        val frames=TransientFrames()
        frames.add(byteArrayOf(1,2,3))
        val copy=frames.copies().single()
        frames.clear()
        assertArrayEquals(byteArrayOf(1,2,3),copy)
        copy.fill(0)
    }
}
