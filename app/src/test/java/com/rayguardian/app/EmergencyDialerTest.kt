package com.rayguardian.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EmergencyDialerTest {
    @Test fun blocksPublicEmergencyShortcodesAcrossCountries() {
        for (shortcode in listOf("112", "911", "999", "000", "110", "119", "+112", "(911)", "123")) {
            assertEquals(
                "Expected $shortcode to be blocked",
                EmergencyDialer.Validation.BlockedEmergencyShortcode,
                EmergencyDialer.validateNumber(shortcode),
            )
        }
    }

    @Test fun allowsValidInternationalAndLocalTestPhoneNumbers() {
        val finnish = EmergencyDialer.validateNumber("+358 40 123 4567")
        assertTrue(finnish is EmergencyDialer.Validation.Valid)
        assertEquals("+358401234567", (finnish as EmergencyDialer.Validation.Valid).normalizedNumber)

        val local = EmergencyDialer.validateNumber("040-987-6543")
        assertTrue(local is EmergencyDialer.Validation.Valid)
        assertEquals("0409876543", (local as EmergencyDialer.Validation.Valid).normalizedNumber)
    }

    @Test fun handlesEmptyAndMalformedNumbers() {
        assertEquals(EmergencyDialer.Validation.Empty, EmergencyDialer.validateNumber(""))
        assertEquals(EmergencyDialer.Validation.Empty, EmergencyDialer.validateNumber("   "))
        assertEquals(EmergencyDialer.Validation.InvalidFormat, EmergencyDialer.validateNumber("abc-1234"))
        assertEquals(EmergencyDialer.Validation.InvalidFormat, EmergencyDialer.validateNumber("12"))
    }

    @Test fun buildsServiceSpecificOfflineBriefings() {
        val fireScript = EmergencyDialer.buildOfflineBriefing(
            service = HelpService.FIRE_DEPARTMENT,
            hazardType = HazardType.FIRE,
            location = "Helsinki Lab · 60.1699, 24.9384",
            context = "Large open flames spreading across floor",
        )
        assertTrue(fireScript.contains("Fire and Rescue Services"))
        assertTrue(fireScript.contains("large open fire"))
        assertTrue(fireScript.contains("Helsinki Lab"))

        val medicalScript = EmergencyDialer.buildOfflineBriefing(
            service = HelpService.AMBULANCE,
            hazardType = HazardType.MEDICAL,
            location = "Espoo Care Home",
            context = "Elderly person fallen beside walking frame",
        )
        assertTrue(medicalScript.contains("Ambulance and Emergency Medical Services"))
        assertTrue(medicalScript.contains("Espoo Care Home"))
    }
}
