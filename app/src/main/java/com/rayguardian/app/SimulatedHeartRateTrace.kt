package com.rayguardian.app

/** Scripted heart-rate traces for rehearsals. Values are synthetic, not recordings of a person. */
object SimulatedHeartRateTrace {
    enum class Scenario(val title: String) {
        RESTING("Resting"),
        SUSTAINED_HIGH("Sustained high heart rate"),
        SUSTAINED_LOW("Sustained low heart rate"),
        WATCH_REMOVED("Watch taken off"),
    }

    const val WATCH_REMOVED_AT = 8

    /** Trace value at [second], or null when the simulated watch reports nothing. */
    fun bpmAt(scenario: Scenario, second: Int): Int? {
        val wobble = listOf(0, 2, 3, 1, -1, -2, 0, 1)[second % 8]
        return when (scenario) {
            Scenario.RESTING -> 72 + wobble
            Scenario.SUSTAINED_HIGH -> if (second < 5) 82 + wobble else minOf(168, 90 + (second - 5) * 12) + wobble
            Scenario.SUSTAINED_LOW -> if (second < 5) 70 + wobble else maxOf(34, 66 - (second - 5) * 8) + wobble / 2
            Scenario.WATCH_REMOVED -> if (second < WATCH_REMOVED_AT) 74 + wobble else null
        }
    }
}
