package com.rayguardian.app

import java.util.UUID

/** One reading from the standard Bluetooth Heart Rate Measurement characteristic (0x2A37). */
data class HeartRateMeasurement(val bpm: Int, val skinContact: Boolean?) {
    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        val MEASUREMENT_UUID: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        val CLIENT_CONFIG_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Parses a characteristic value, returning null for a malformed payload. */
        fun parse(value: ByteArray): HeartRateMeasurement? {
            if (value.isEmpty()) return null
            val flags = value[0].toInt() and 0xFF
            val sixteenBit = flags and 0x01 != 0
            val bpm = if (sixteenBit) {
                if (value.size < 3) return null
                (value[1].toInt() and 0xFF) or ((value[2].toInt() and 0xFF) shl 8)
            } else {
                if (value.size < 2) return null
                value[1].toInt() and 0xFF
            }
            val contactSupported = flags and 0x04 != 0
            val contactDetected = flags and 0x02 != 0
            return HeartRateMeasurement(bpm, if (contactSupported) contactDetected else null)
        }
    }
}
