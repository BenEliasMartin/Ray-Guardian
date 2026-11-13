package com.rayguardian.app

/**
 * Rule-based heart-rate screening for smartwatch readings.
 *
 * This is an unvalidated prototype heuristic, not a medical device or diagnosis. It only reports a
 * candidate when a reading stays outside the configured range for [Config.sustainMillis], so single
 * spikes and motion artefacts do not trigger. A missing signal is reported as [State.SIGNAL_LOST]
 * (reduced coverage), never as an emergency.
 */
class HeartRateAnomalyDetector(private val config: Config = Config()) {
    data class Config(
        val lowBpm: Int = 40,
        val highBpm: Int = 150,
        val sustainMillis: Long = 30_000L,
        val minSamples: Int = 3,
        val staleMillis: Long = 15_000L,
        val minPlausibleBpm: Int = 25,
        val maxPlausibleBpm: Int = 240,
    ) {
        init {
            require(minPlausibleBpm < lowBpm && lowBpm < highBpm && highBpm < maxPlausibleBpm)
            require(sustainMillis > 0 && staleMillis > 0 && minSamples > 0)
        }
    }

    enum class State { NO_DATA, NORMAL, OUT_OF_RANGE, ANOMALY, SIGNAL_LOST }
    enum class Kind { HIGH, LOW }

    data class Assessment(
        val state: State,
        val kind: Kind? = null,
        val latestBpm: Int? = null,
        /** Duration of the current out-of-range run, if any. */
        val outOfRangeMillis: Long = 0,
        /** True exactly once per anomaly episode, on the assessment that first reaches [State.ANOMALY]. */
        val newAnomaly: Boolean = false,
    )

    private var lastSampleAt: Long? = null
    private var latestBpm: Int? = null
    private var runKind: Kind? = null
    private var runStartedAt = 0L
    private var runSamples = 0
    private var anomalyReported = false

    /** Feeds one reading. [skinContact] is null when the sensor does not report contact. */
    fun onSample(bpm: Int, atMillis: Long, skinContact: Boolean? = null): Assessment {
        if (skinContact == false || bpm < config.minPlausibleBpm || bpm > config.maxPlausibleBpm) {
            // Artefact or watch not worn: ignore the value, staleness will surface a lasting gap.
            return assess(atMillis)
        }
        val previous = lastSampleAt
        if (previous != null && atMillis < previous) return assess(atMillis) // out-of-order sample
        if (previous != null && atMillis - previous > config.staleMillis) clearRun()
        lastSampleAt = atMillis
        latestBpm = bpm

        val kind = when {
            bpm > config.highBpm -> Kind.HIGH
            bpm < config.lowBpm -> Kind.LOW
            else -> null
        }
        if (kind == null) {
            clearRun()
        } else if (kind != runKind) {
            clearRun()
            runKind = kind
            runStartedAt = atMillis
            runSamples = 1
        } else {
            runSamples++
        }
        return assess(atMillis)
    }

    /** Re-evaluates without a new reading, e.g. on a timer, so a lost signal becomes visible. */
    fun assess(nowMillis: Long): Assessment {
        val last = lastSampleAt ?: return Assessment(State.NO_DATA)
        if (nowMillis - last > config.staleMillis) {
            clearRun()
            return Assessment(State.SIGNAL_LOST, latestBpm = latestBpm)
        }
        val kind = runKind ?: return Assessment(State.NORMAL, latestBpm = latestBpm)
        val duration = last - runStartedAt
        if (duration >= config.sustainMillis && runSamples >= config.minSamples) {
            val first = !anomalyReported
            anomalyReported = true
            return Assessment(State.ANOMALY, kind, latestBpm, duration, newAnomaly = first)
        }
        return Assessment(State.OUT_OF_RANGE, kind, latestBpm, duration)
    }

    fun reset() {
        lastSampleAt = null
        latestBpm = null
        clearRun()
    }

    private fun clearRun() {
        runKind = null
        runStartedAt = 0L
        runSamples = 0
        anomalyReported = false
    }
}
