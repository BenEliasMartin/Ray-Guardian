package com.rayguardian.app

/** Deterministic foreground trigger policy. It performs no capture, storage, or networking itself. */
class TriggerController(private val budget: CaptureBudget = CaptureBudget()) {
    enum class Signal { MANUAL_SOS, VOICE_SOS, FALL_CANDIDATE, HEART_RATE, LOUD_VOICE }
    enum class Phase { OFF, STANDBY, CAPTURING, ANALYZING, COOLDOWN }
    data class Settings(
        val enabled: Set<Signal> = setOf(Signal.HEART_RATE, Signal.FALL_CANDIDATE),
        val cameraContext: Boolean = false,
        val cloudContext: Boolean = false,
    )
    data class Availability(val connected: Boolean = false, val cameraPermission: Boolean = false, val thermalSafe: Boolean = false) {
        val canCapture get() = connected && cameraPermission && thermalSafe
    }
    sealed interface Effect {
        data class Incident(val signal: Signal) : Effect
        data class StartCapture(val token: Long) : Effect
        data class StopCapture(val token: Long) : Effect
        data class Analyze(val token: Long) : Effect
        data object CancelAnalysis : Effect
        data object ClearContext : Effect
    }

    var settings = Settings(); private set
    var availability = Availability(); private set
    var phase = Phase.OFF; private set
    var token: Long? = null; private set
    var reason = "Monitoring is off"; private set
    val armed get() = phase != Phase.OFF
    private var nextToken = 0L
    private var lastNow = 0L
    private var armDeadline = 0L
    private var workDeadline = 0L
    private var nextCandidateAt = 0L
    private var hasFrames = false

    fun configure(value: Settings): List<Effect> {
        if (settings == value) return emptyList()
        val effects = disarm()
        settings = value.copy(enabled = value.enabled.toSet())
        reason = "Settings changed; arm again to apply them"
        return effects
    }

    fun arm(now: Long): List<Effect> {
        if (armed || !time(now)) return emptyList()
        phase = Phase.STANDBY
        armDeadline = now + ARM_MILLIS
        reason = "Armed for 15 minutes; camera off"
        return listOf(Effect.ClearContext)
    }

    fun disarm(): List<Effect> {
        val effects = stopWork()
        phase = Phase.OFF
        reason = "Monitoring is off; temporary context cleared"
        return effects
    }

    fun setAvailability(value: Availability): List<Effect> {
        availability = value
        if (!value.canCapture && (phase == Phase.CAPTURING || phase == Phase.ANALYZING)) {
            val effects = stopWork()
            phase = Phase.COOLDOWN
            reason = "Context stopped: device, permission, or thermal state unavailable"
            return effects
        }
        return emptyList()
    }

    /** Audio loudness alone is only a hint. It never starts capture or a check-in. */
    fun offer(signal: Signal, now: Long, observedAt: Long = now): List<Effect> {
        val effects = tick(now).toMutableList()
        if (!armed || now < observedAt || now - observedAt > FRESH_MILLIS || now < lastNow) return effects
        if (signal != Signal.MANUAL_SOS && signal !in settings.enabled) return effects
        if (signal == Signal.LOUD_VOICE) {
            if (phase == Phase.STANDBY || phase == Phase.COOLDOWN) reason = "Loud-voice hint only; camera remains off"
            return effects
        }
        val intentional = signal == Signal.MANUAL_SOS || signal == Signal.VOICE_SOS
        // Intentional SOS is never blocked by capture/AI availability, cooldown, or budget.
        if (!intentional && (phase != Phase.STANDBY || now < nextCandidateAt)) return effects
        effects += Effect.Incident(signal)
        nextCandidateAt = now + COOLDOWN_MILLIS
        if (phase == Phase.CAPTURING || phase == Phase.ANALYZING) return effects
        effects += Effect.ClearContext
        phase = Phase.COOLDOWN
        reason = "Incident recorded locally; camera off"
        if (!settings.cameraContext) return effects
        if (!availability.canCapture) {
            reason = "Incident recorded; optional camera unavailable"
            return effects
        }
        if (!budget.reserve(now)) {
            reason = "Incident recorded; camera cooldown or capture budget reached"
            return effects
        }
        val id = ++nextToken
        token = id
        hasFrames = false
        workDeadline = now + CAPTURE_MILLIS
        phase = Phase.CAPTURING
        reason = "Brief context capture; stops within 8 seconds including startup"
        effects += Effect.StartCapture(id)
        return effects
    }

    fun frameReceived(id: Long, now: Long): Boolean =
        phase == Phase.CAPTURING && token == id && now >= lastNow && now < workDeadline && now < armDeadline
            && settings.cameraContext && availability.canCapture && run { hasFrames = true; true }

    fun captureFailed(id: Long): List<Effect> {
        if (phase != Phase.CAPTURING || token != id) return emptyList()
        val effects = stopWork()
        phase = Phase.COOLDOWN
        reason = "Optional capture failed; incident flow continues without media"
        return effects
    }

    fun analysisFinished(id: Long): List<Effect> {
        if (phase != Phase.ANALYZING || token != id) return emptyList()
        val effects = stopWork()
        phase = Phase.COOLDOWN
        reason = "Assessment finished; camera off and temporary images cleared"
        return effects
    }

    fun cancelContext(): List<Effect> {
        val effects = stopWork()
        if (armed) phase = Phase.COOLDOWN
        reason = "Context cancelled; temporary images cleared"
        return effects
    }

    fun tick(now: Long): List<Effect> {
        if (!time(now) || !armed) return emptyList()
        if (now >= armDeadline) return disarm().also { reason = "15-minute session expired; arm again to resume" }
        if (phase == Phase.CAPTURING && now >= workDeadline) {
            val id = token!!
            val effects = mutableListOf<Effect>(Effect.StopCapture(id))
            if (hasFrames && settings.cameraContext && settings.cloudContext && availability.canCapture) {
                phase = Phase.ANALYZING
                workDeadline = now + ANALYSIS_MILLIS
                reason = "Camera off; submitting optional context with prior cloud consent"
                effects += Effect.Analyze(id)
            } else {
                val receivedFrames = hasFrames
                phase = Phase.COOLDOWN
                effects += stopWork()
                reason = if (receivedFrames) "Camera off; frames discarded locally, no cloud submission" else "Camera off; no usable frames received"
            }
            return effects
        }
        if (phase == Phase.ANALYZING && now >= workDeadline) {
            val effects = stopWork()
            phase = Phase.COOLDOWN
            reason = "Analysis timed out; request cancelled and temporary images cleared"
            return effects
        }
        if (phase == Phase.COOLDOWN && now >= nextCandidateAt) {
            phase = Phase.STANDBY
            reason = "Armed; camera off"
        }
        return emptyList()
    }

    private fun time(now: Long): Boolean {
        if (now < lastNow) return false
        lastNow = now
        return true
    }

    private fun stopWork(): List<Effect> {
        val effects = mutableListOf<Effect>()
        if (phase == Phase.CAPTURING) token?.let { effects += Effect.StopCapture(it) }
        if (phase == Phase.ANALYZING) effects += Effect.CancelAnalysis
        effects += Effect.ClearContext
        token = null
        hasFrames = false
        workDeadline = 0
        return effects
    }

    /** Reserve full bursts, including failed startups. Re-arming does not reset this budget. */
    class CaptureBudget {
        private val starts = ArrayDeque<Long>()
        fun ready(now: Long): Boolean {
            while (starts.isNotEmpty() && now - starts.first() >= WINDOW_MILLIS) starts.removeFirst()
            return starts.isEmpty() || (now - starts.last() >= COOLDOWN_MILLIS && (starts.size + 1) * CAPTURE_MILLIS <= WINDOW_CAPTURE_MILLIS)
        }
        fun reserve(now: Long): Boolean {
            if (!ready(now)) return false
            starts.addLast(now)
            return true
        }
    }

    companion object {
        const val ARM_MILLIS = 15 * 60_000L
        const val CAPTURE_MILLIS = 8_000L
        const val ANALYSIS_MILLIS = 45_000L
        const val COOLDOWN_MILLIS = 60_000L
        const val WINDOW_MILLIS = 10 * 60_000L
        const val WINDOW_CAPTURE_MILLIS = 30_000L
        const val FRESH_MILLIS = 5_000L
    }
}
