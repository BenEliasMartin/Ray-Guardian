package com.rayguardian.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HeartRateMeasurementTest {
    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    @Test fun parsesEightBitValueWithoutContactSupport() {
        assertEquals(HeartRateMeasurement(72, null), HeartRateMeasurement.parse(bytes(0x00, 72)))
    }

    @Test fun parsesSixteenBitLittleEndianValue() {
        assertEquals(300, HeartRateMeasurement.parse(bytes(0x01, 0x2C, 0x01))!!.bpm)
    }

    @Test fun readsUnsignedEightBitValues() {
        assertEquals(200, HeartRateMeasurement.parse(bytes(0x00, 200))!!.bpm)
    }

    @Test fun reportsSkinContactWhenSupported() {
        assertEquals(true, HeartRateMeasurement.parse(bytes(0x06, 80))!!.skinContact)
        assertEquals(false, HeartRateMeasurement.parse(bytes(0x04, 80))!!.skinContact)
    }

    @Test fun ignoresTrailingEnergyAndRrFields() {
        assertEquals(HeartRateMeasurement(64, true), HeartRateMeasurement.parse(bytes(0x1E, 64, 0x10, 0x00, 0x00, 0x04)))
    }

    @Test fun rejectsTruncatedPayloads() {
        assertNull(HeartRateMeasurement.parse(bytes()))
        assertNull(HeartRateMeasurement.parse(bytes(0x00)))
        assertNull(HeartRateMeasurement.parse(bytes(0x01, 0x2C)))
    }
}
