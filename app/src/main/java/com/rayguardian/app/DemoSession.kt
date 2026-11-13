package com.rayguardian.app

/** A local-only rehearsal. No transition in this class sends an alert or accesses a sensor. */
class DemoSession {
    enum class Phase { DISARMED, ARMED, CHECK_IN, ALERT, ACKNOWLEDGED, CANCELLED }
    enum class Trigger { MANUAL, REPLAYED_CANDIDATE }

    var phase: Phase = Phase.DISARMED
        private set
    var trigger: Trigger? = null
        private set
    var deadlineMillis: Long? = null
        private set

    fun arm() {
        if (phase != Phase.DISARMED && phase != Phase.CANCELLED) return
        trigger = null
        deadlineMillis = null
        phase = Phase.ARMED
    }

    fun disarm() {
        if (phase != Phase.ARMED && phase != Phase.CHECK_IN) return
        deadlineMillis = null
        trigger = null
        phase = Phase.DISARMED
    }

    fun manualSos() {
        if (phase != Phase.ARMED && phase != Phase.CHECK_IN) return
        deadlineMillis = null
        trigger = Trigger.MANUAL
        phase = Phase.ALERT
    }

    fun replayCandidate(nowMillis: Long) {
        if (phase != Phase.ARMED) return
        trigger = Trigger.REPLAYED_CANDIDATE
        deadlineMillis = nowMillis + CHECK_IN_MILLIS
        phase = Phase.CHECK_IN
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
        phase = Phase.DISARMED
    }

    companion object {
        const val CHECK_IN_MILLIS = 15_000L
    }
}
