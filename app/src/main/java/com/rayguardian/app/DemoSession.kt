package com.rayguardian.app

/**
 * Deterministic incident & hazard escalation state machine.
 * Supports both local rehearsal drills and service-routed hazard dispatch
 * (Medical -> Ambulance, Fire -> Fire & Rescue, Safety Threat -> Police).
 */
class DemoSession {
    enum class Phase { DISARMED, ARMED, CHECK_IN, ALERT, ACKNOWLEDGED, CANCELLED }
    enum class Trigger(val wireName: String) {
        MANUAL("manual-sos"),
        VOICE_SOS("manual-sos"),
        REPLAYED_CANDIDATE("staged-collapse"),
        FALL_CANDIDATE("staged-collapse"),
        HEART_RATE_ANOMALY("heart-rate-anomaly"),
        LIVE_VISION("live-vision"),
        LOUD_SOUND("loud-sound"),
        ELDERLY_FALL("elderly-fall"),
        OPEN_FIRE("fire-hazard"),
        SAFETY_THREAT("safety-threat"),
        TREMBLING("trembling"),
        CRASH("crash"),
        GLASSES_AI_HAZARD("ai-hazard"),
    }

    var phase: Phase = Phase.DISARMED
        private set
    var trigger: Trigger? = null
        private set
    var deadlineMillis: Long? = null
        private set
    var hazardType: HazardType = HazardType.NONE
        private set
    var targetService: HelpService = HelpService.AMBULANCE
        private set

    fun arm() {
        if (phase != Phase.DISARMED && phase != Phase.CANCELLED) return
        trigger = null
        deadlineMillis = null
        hazardType = HazardType.NONE
        targetService = HelpService.AMBULANCE
        phase = Phase.ARMED
    }

    fun disarm() {
        if (phase != Phase.ARMED && phase != Phase.CHECK_IN) return
        deadlineMillis = null
        trigger = null
        hazardType = HazardType.NONE
        phase = Phase.DISARMED
    }

    fun manualSos(source: Trigger = Trigger.MANUAL, service: HelpService = targetService) {
        if (phase != Phase.ARMED && phase != Phase.CHECK_IN) return
        if (source != Trigger.MANUAL && source != Trigger.VOICE_SOS) return
        deadlineMillis = null
        trigger = source
        targetService = service
        if (hazardType == HazardType.NONE) hazardType = HazardType.fromService(service)
        phase = Phase.ALERT
    }

    fun manualSos(service: HelpService) = manualSos(Trigger.MANUAL, service)

    /** A candidate event always starts a check-in first; it never creates an alert directly. */
    fun replayCandidate(nowMillis: Long, source: Trigger = Trigger.REPLAYED_CANDIDATE) {
        if (phase != Phase.ARMED || source == Trigger.MANUAL || source == Trigger.VOICE_SOS) return
        val inferredHazard = when (source) {
            Trigger.OPEN_FIRE -> HazardType.FIRE
            Trigger.SAFETY_THREAT -> HazardType.POLICE
            else -> HazardType.MEDICAL
        }
        val windowMillis = if (inferredHazard == HazardType.FIRE) FIRE_CHECK_IN_MILLIS else CHECK_IN_MILLIS
        trigger = source
        hazardType = inferredHazard
        targetService = inferredHazard.defaultService()
        deadlineMillis = nowMillis + windowMillis
        phase = Phase.CHECK_IN
    }

    fun triggerDetectedHazard(
        nowMillis: Long,
        detectedHazard: HazardType,
        source: Trigger = Trigger.GLASSES_AI_HAZARD,
        recommendedService: HelpService? = null,
        urgentImmediate: Boolean = false,
    ) {
        if (detectedHazard == HazardType.NONE || source == Trigger.MANUAL || source == Trigger.VOICE_SOS) return
        if (phase == Phase.DISARMED || phase == Phase.CANCELLED) arm()
        if (phase != Phase.ARMED) return
        val windowMillis = when {
            detectedHazard == HazardType.FIRE || urgentImmediate -> FIRE_CHECK_IN_MILLIS
            else -> CHECK_IN_MILLIS
        }
        trigger = source
        hazardType = detectedHazard
        targetService = recommendedService ?: detectedHazard.defaultService()
        deadlineMillis = nowMillis + windowMillis
        phase = Phase.CHECK_IN
    }

    fun escalateImmediately(service: HelpService = targetService) {
        if (phase == Phase.DISARMED || phase == Phase.CANCELLED) arm()
        if (phase != Phase.ARMED && phase != Phase.CHECK_IN) return
        deadlineMillis = null
        if (trigger == null) trigger = Trigger.MANUAL
        targetService = service
        if (hazardType == HazardType.NONE) hazardType = HazardType.fromService(service)
        phase = Phase.ALERT
    }

    fun tick(nowMillis: Long) {
        val deadline = deadlineMillis ?: return
        if (phase == Phase.CHECK_IN && nowMillis >= deadline) {
            deadlineMillis = null
            phase = Phase.ALERT
        }
    }

    fun cancel() {
        when (phase) {
            Phase.CHECK_IN -> {
                deadlineMillis = null
                trigger = null
                hazardType = HazardType.NONE
                phase = Phase.ARMED
            }
            Phase.ALERT, Phase.ACKNOWLEDGED -> phase = Phase.CANCELLED
            else -> Unit
        }
    }

    fun acknowledge() {
        if (phase == Phase.ALERT) phase = Phase.ACKNOWLEDGED
    }

    fun finish() {
        if (phase != Phase.ALERT && phase != Phase.ACKNOWLEDGED && phase != Phase.CANCELLED) return
        trigger = null
        deadlineMillis = null
        hazardType = HazardType.NONE
        phase = Phase.DISARMED
    }

    companion object {
        const val CHECK_IN_MILLIS = 15_000L
        const val FIRE_CHECK_IN_MILLIS = 8_000L
    }
}
