package com.rayguardian.app

enum class HazardType(val wireName: String, val label: String) {
    NONE("none", "No Hazard"),
    MEDICAL("medical", "Medical / Fall Hazard"),
    FIRE("fire", "Large Open Fire Hazard"),
    POLICE("police", "Personal Safety Threat");

    fun defaultService(): HelpService = when (this) {
        MEDICAL -> HelpService.AMBULANCE
        FIRE -> HelpService.FIRE_DEPARTMENT
        POLICE -> HelpService.POLICE
        NONE -> HelpService.AMBULANCE
    }

    companion object {
        fun fromWire(value: String?): HazardType =
            entries.firstOrNull { it.wireName.equals(value, ignoreCase = true) } ?: NONE

        fun fromService(service: HelpService): HazardType = when (service) {
            HelpService.AMBULANCE -> MEDICAL
            HelpService.FIRE_DEPARTMENT -> FIRE
            HelpService.POLICE -> POLICE
        }
    }
}

enum class HelpService(
    val wireName: String,
    val title: String,
    val shortTitle: String,
    val spokenName: String,
) {
    AMBULANCE(
        "ambulance",
        "Ambulance / Emergency Medical Services",
        "Ambulance Services",
        "Ambulance and Emergency Medical Services",
    ),
    FIRE_DEPARTMENT(
        "fire_department",
        "Fire & Rescue Services",
        "Fire & Rescue",
        "Fire and Rescue Services",
    ),
    POLICE(
        "police",
        "Police Emergency Dispatch",
        "Police Dispatch",
        "Police Emergency Services",
    );

    companion object {
        fun fromWire(value: String?): HelpService? =
            entries.firstOrNull { it.wireName.equals(value, ignoreCase = true) }
    }
}

data class HazardAssessment(
    val summary: String,
    val observations: List<String>,
    val uncertainties: List<String>,
    val hazardDetected: Boolean,
    val hazardType: HazardType,
    val severity: String,
    val recommendedService: HelpService?,
    val urgentImmediate: Boolean,
)

data class DispatchReceipt(
    val id: String,
    val callId: String,
    val status: String,
    val service: HelpService,
    val serviceLabel: String,
    val shortServiceLabel: String,
    val hazardType: HazardType,
    val trigger: String,
    val location: String,
    val contextIncluded: Boolean,
    val briefingScript: String,
    val offlineFallback: Boolean = false,
)
