package com.rayguardian.app

import com.rayguardian.app.HeartRateAnomalyDetector.Kind
import com.rayguardian.app.HeartRateAnomalyDetector.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HeartRateAnomalyDetectorTest {
    private fun feed(detector: HeartRateAnomalyDetector, bpm: Int, fromSecond: Int, toSecond: Int) =
        (fromSecond..toSecond).map { detector.onSample(bpm, it * 1000L) }

    @Test fun noReadingsMeansNoData() {
        assertEquals(State.NO_DATA, HeartRateAnomalyDetector().assess(5_000).state)
    }

    @Test fun normalReadingsStayNormal() {
        val results = feed(HeartRateAnomalyDetector(), 72, 0, 120)
        assertTrue(results.all { it.state == State.NORMAL && !it.newAnomaly })
    }

    @Test fun sustainedHighRateBecomesAnomalyExactlyOnce() {
        val detector = HeartRateAnomalyDetector()
        val early = feed(detector, 170, 0, 29)
        assertTrue(early.all { it.state == State.OUT_OF_RANGE && it.kind == Kind.HIGH })
        val reached = detector.onSample(170, 30_000)
        assertEquals(State.ANOMALY, reached.state)
        assertEquals(Kind.HIGH, reached.kind)
        assertTrue(reached.newAnomaly)
        assertFalse(detector.onSample(171, 31_000).newAnomaly)
        assertFalse(detector.assess(31_500).newAnomaly)
    }

    @Test fun sustainedLowRateIsDetected() {
        val detector = HeartRateAnomalyDetector()
        feed(detector, 35, 0, 29)
        val result = detector.onSample(35, 30_000)
        assertEquals(State.ANOMALY, result.state)
        assertEquals(Kind.LOW, result.kind)
    }

    @Test fun briefSpikeOrSingleNormalReadingResetsTheRun() {
        val detector = HeartRateAnomalyDetector()
        feed(detector, 170, 0, 20)
        assertEquals(State.NORMAL, detector.onSample(90, 21_000).state)
        feed(detector, 170, 22, 50)
        assertEquals(State.OUT_OF_RANGE, detector.assess(50_000).state)
        assertTrue(detector.onSample(170, 52_000).newAnomaly)
    }

    @Test fun switchingFromHighToLowStartsANewRun() {
        val detector = HeartRateAnomalyDetector()
        feed(detector, 170, 0, 20)
        val low = detector.onSample(35, 21_000)
        assertEquals(Kind.LOW, low.kind)
        assertEquals(0, low.outOfRangeMillis)
    }

    @Test fun sparseReadingsNeedTheMinimumSampleCount() {
        val detector = HeartRateAnomalyDetector(HeartRateAnomalyDetector.Config(minSamples = 5))
        listOf(0L, 10_000L, 20_000L).forEach { detector.onSample(170, it) }
        assertEquals(State.OUT_OF_RANGE, detector.onSample(170, 30_000).state)
        assertEquals(State.ANOMALY, detector.onSample(170, 31_000).state)
    }

    @Test fun implausibleAndNoContactReadingsAreIgnored() {
        val detector = HeartRateAnomalyDetector()
        detector.onSample(72, 0)
        assertEquals(State.NORMAL, detector.onSample(0, 1_000).state)
        assertEquals(State.NORMAL, detector.onSample(255, 2_000).state)
        assertEquals(State.NORMAL, detector.onSample(180, 3_000, skinContact = false).state)
        assertEquals(72, detector.assess(3_000).latestBpm)
    }

    @Test fun missingReadingsReportSignalLostNotAnomaly() {
        val detector = HeartRateAnomalyDetector()
        feed(detector, 170, 0, 20)
        val lost = detector.assess(36_000)
        assertEquals(State.SIGNAL_LOST, lost.state)
        assertNull(lost.kind)
        assertFalse(lost.newAnomaly)
    }

    @Test fun gapInsideARunRestartsTheSustainWindow() {
        val detector = HeartRateAnomalyDetector()
        feed(detector, 170, 0, 20)
        val afterGap = detector.onSample(170, 40_000)
        assertEquals(State.OUT_OF_RANGE, afterGap.state)
        assertEquals(0, afterGap.outOfRangeMillis)
    }

    @Test fun anomalyCanReoccurAfterRecovery() {
        val detector = HeartRateAnomalyDetector()
        assertTrue(feed(detector, 170, 0, 30).last().newAnomaly)
        detector.onSample(80, 31_000)
        assertTrue(feed(detector, 170, 32, 62).last().newAnomaly)
    }

    @Test fun resetClearsEverything() {
        val detector = HeartRateAnomalyDetector()
        feed(detector, 170, 0, 30)
        detector.reset()
        assertEquals(State.NO_DATA, detector.assess(31_000).state)
    }

    @Test fun simulatedScenariosProduceTheExpectedOutcome() {
        fun run(scenario: SimulatedHeartRateTrace.Scenario): State {
            val detector = HeartRateAnomalyDetector()
            var sawAnomaly = false
            for (second in 0..90) {
                val bpm = SimulatedHeartRateTrace.bpmAt(scenario, second)
                val result = if (bpm != null) detector.onSample(bpm, second * 1000L) else detector.assess(second * 1000L)
                if (result.state == State.ANOMALY) sawAnomaly = true
            }
            return if (sawAnomaly) State.ANOMALY else detector.assess(90_000).state
        }
        assertEquals(State.NORMAL, run(SimulatedHeartRateTrace.Scenario.RESTING))
        assertEquals(State.ANOMALY, run(SimulatedHeartRateTrace.Scenario.SUSTAINED_HIGH))
        assertEquals(State.ANOMALY, run(SimulatedHeartRateTrace.Scenario.SUSTAINED_LOW))
        assertEquals(State.SIGNAL_LOST, run(SimulatedHeartRateTrace.Scenario.WATCH_REMOVED))
    }
}
