package com.rayguardian.app

/**
 * Pure emergency dial validation and spoken briefing fallback builder.
 * Blocks public emergency shortcodes (112, 911, 999, etc.) in developer SDK builds
 * while allowing dedicated test or responder phone numbers.
 */
object EmergencyDialer {
    private val blockedShortcodes = setOf(
        "000", "08", "100", "101", "102", "103", "107", "108",
        "110", "111", "112", "113", "114", "115", "116", "117", "118", "119",
        "120", "122", "190", "192", "193", "911", "988", "999",
    )

    sealed class Validation {
        data object Empty : Validation()
        data object BlockedEmergencyShortcode : Validation()
        data object InvalidFormat : Validation()
        data class Valid(val normalizedNumber: String) : Validation()
    }

    sealed class CallOutcome(val summary: String) {
        data class PlacedDirectCall(val number: String) : CallOutcome("Direct phone call started ($number)")
        data class OpenedDialer(val number: String) : CallOutcome("Opened phone dialer ($number)")
        data object NoNumberConfigured : CallOutcome("Backend & ElevenLabs dispatch active (no phone number set)")
        data object BlockedShortcode : CallOutcome("Blocked public 112/911 shortcode; use a test phone number")
        data object InvalidNumber : CallOutcome("Configured phone number format is invalid")
        data class Failed(val reason: String) : CallOutcome("Phone call could not be started: $reason")
    }

    fun validateNumber(raw: String?): Validation {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return Validation.Empty
        if (!trimmed.all { it.isDigit() || it in "+-() ." }) return Validation.InvalidFormat
        val hasLeadingPlus = trimmed.startsWith("+")
        val digits = trimmed.filter { it.isDigit() }
        if (digits.isEmpty()) return Validation.InvalidFormat
        if (digits in blockedShortcodes || digits.length == 3) {
            return Validation.BlockedEmergencyShortcode
        }
        if (digits.length < 4 || digits.length > 18) return Validation.InvalidFormat
        return Validation.Valid(if (hasLeadingPlus) "+$digits" else digits)
    }

    fun buildOfflineBriefing(
        service: HelpService,
        hazardType: HazardType,
        location: String,
        context: String?,
        heartRateBpm: Int? = null,
    ): String {
        val hazardLine = when (hazardType) {
            HazardType.FIRE -> "Hazard detected: large open fire or heavy smoke."
            HazardType.MEDICAL -> if (heartRateBpm != null) {
                "Hazard detected: sustained abnormal heart rate at $heartRateBpm beats per minute with no wearer response."
            } else {
                "Hazard detected: fall or acute medical emergency."
            }
            HazardType.POLICE -> "Hazard detected: acute personal safety threat."
            HazardType.NONE -> "Immediate emergency help requested by smart glasses wearer."
        }
        val cleanLocation = location.ifBlank { "Location pending GPS confirmation" }.trimEnd('.')
        val cleanContext = context?.trim().orEmpty().take(220).trimEnd('.')
        return buildString {
            append("Automated Ray Guardian emergency call for ${service.spokenName}. ")
            append("$hazardLine ")
            append("Location: $cleanLocation. ")
            if (cleanContext.isNotEmpty()) append("Smart glasses report: $cleanContext. ")
            append("Please dispatch ${service.shortTitle} immediately.")
        }
    }
}
