package com.rayguardian.app

import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import org.junit.Assert.*
import org.junit.Test

class CaptureReceiptTest {
    private val incident="123e4567-e89b-42d3-a456-426614174000"
    private val installation="123e4567-e89b-42d3-b456-426614174001"
    @Test fun exactReceiptBytesVerifyAndAnyEditFails() {
        val bytes=CaptureReceipt.serialize(incident,installation,"p256_"+"a".repeat(64),"b".repeat(43),"c".repeat(64))
        val expected="{\"version\":1,\"incidentId\":\"$incident\",\"keyId\":\"p256_${"a".repeat(64)}\",\"installationId\":\"$installation\",\"nonce\":\"${"b".repeat(43)}\",\"videoSha256\":\"${"c".repeat(64)}\"}"
        assertArrayEquals(expected.toByteArray(Charsets.UTF_8),bytes)
        val generator=KeyPairGenerator.getInstance("EC");generator.initialize(ECGenParameterSpec("secp256r1"));val pair=generator.generateKeyPair()
        val signature=Signature.getInstance("SHA256withECDSA").run { initSign(pair.private);update(bytes);sign() }
        assertTrue(Signature.getInstance("SHA256withECDSA").run { initVerify(pair.public);update(bytes);verify(signature) })
        assertFalse(Signature.getInstance("SHA256withECDSA").run { initVerify(pair.public);update(bytes+32.toByte());verify(signature) })
    }
    @Test fun arbitraryFieldsCannotInjectIntoReceipt() {
        assertThrows(IllegalArgumentException::class.java) { CaptureReceipt.serialize("$incident\"",installation,"p256_"+"a".repeat(64),"b".repeat(43),"c".repeat(64)) }
    }
    @Test fun onlyServerMatchStatusGetsTheSealLabel() {
        assertEquals("Signed by the capture app",CaptureSealStatus.fromWire("matches").seal)
        for(status in listOf("file_differs","untrusted","locally_signed","unknown",""))assertNull(CaptureSealStatus.fromWire(status).seal)
    }
}
